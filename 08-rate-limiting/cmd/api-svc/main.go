// Command api-svc — yönetim yolu: oluşturma, silme, listeleme, istatistik.
//
// EN: Low traffic, writes, and queries that are allowed to take 100 ms. Because it is a separate
//
//	deployment it can have a bigger connection pool per pod (it needs the database) and a much
//	smaller replica count (it does not need the throughput) — the exact opposite knobs from
//	redirect-svc. One binary could never have both settings at once.
//
// TR: Düşük trafik, yazma ve 100 ms sürmesine izin verilen sorgular. Ayrı bir deployment olduğu
//
//	için pod başına DAHA BÜYÜK bir bağlantı havuzu (veritabanına ihtiyacı var) ve çok DAHA AZ
//	replika (aktarım hızına ihtiyacı yok) alabiliyor — redirect-svc'nin tam tersi düğmeler.
//	Tek bir binary bu iki ayarı aynı anda taşıyamazdı.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/config"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/store"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/stream"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
)

var version = "dev"

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	cfg := config.Load()
	met := metrics.New(cfg.TrapMetricLabelCode)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	dbMet := store.NewDBMetrics(met.Registry())
	// Okuma servisi DAHA KÜÇÜK bir havuzla yaşar: çoğu istek önbellekten dönüyor ve replika
	// sayısı yüksek olacak (HPA). Havuz × replika, Postgres'in max_connections'ını aşmamalı (P02-02).
	db, err := store.Open(ctx, cfg.DatabaseURL, cfg.DBMaxConns, dbMet)
	if err != nil {
		log.Error("veritabanına bağlanılamadı", "err", err)
		os.Exit(1)
	}
	defer db.Close()
	met.BindPoolStats(db.PoolStats)

	rdb := redis.NewClient(&redis.Options{
		Addr: cfg.RedisAddr, DialTimeout: cfg.RedisTimeout,
		ReadTimeout: cfg.RedisTimeout, WriteTimeout: cfg.RedisTimeout, PoolSize: 20,
	})
	defer rdb.Close()
	l2 := cache.NewRedis[store.Link](rdb, cache.Config{
		TTL: cfg.CacheTTL, NegativeTTL: cfg.CacheNegativeTTL, Layer: "l2",
		NoSingleflight: cfg.TrapNoSingleflight, NoNegative: cfg.TrapNoNegative, NoJitter: cfg.TrapNoJitter,
	}, cache.NewMetrics(met.Registry(), "l2"), "linkly:link:")
	cached := store.NewCached(db, l2)

	// TRAP_UNBOUNDED_QUEUE: tampon SINIRINI kaldır. 05'te kuyruk süreç içiydi ve tuzak onu sınırsız
	// bir dilime çeviriyordu; 06'dan itibaren kuyruk Kafka üreticisi, yani tuzak üreticinin sınırını
	// kaldırmalı — yalnızca log'a basılan bir bayrak, açılıp hiçbir şey değiştirmeyen bir deney olur.
	// Sınır burada: tampon dolunca üretici kaydı DÜŞÜRÜR (ve sayar). Sınırsızda düşürme yerine
	// bellek büyür ve pod OOM olur: yani "veri kaybetme" kararını almayı reddettiğinde, karar senin
	// yerine kernel tarafından ve en kötü anda alınır (P05-02).
	// EN: from 06 on the queue is the Kafka producer, so the trap must lift the producer's limit — a
	// flag that is only PRINTED is an experiment that changes nothing. Bounded → the producer drops
	// and counts; unbounded → memory grows and the pod is OOM-killed, i.e. refusing to decide
	// "lose data" hands the decision to the kernel.
	maxBuf := cfg.ProducerMaxBuffered
	if cfg.TrapUnboundedQueue {
		maxBuf = 1 << 30
	}
	clicks, err := stream.NewProducer(strings.Split(cfg.KafkaBrokers, ","), cfg.KafkaTopic,
		maxBuf, stream.NewProducerMetrics(met.Registry()), log)
	if err != nil {
		log.Error("kafka producer kurulamadı", "err", err)
		os.Exit(1)
	}
	defer clicks.Close()

	// Paylaşılan limiter: limit artık pod başına değil, SİSTEM genelinde geçerli.
	dist := ratelimit.NewDistributed(ctx, rdb, ratelimit.DistConfig{
		Window:      cfg.RateLimitWindow,
		PerIP:       cfg.RateLimitPerIP,
		PerTenant:   cfg.RateLimitPerTenant,
		FailOpen:    cfg.RateLimitFailOpen,
		FixedWindow: cfg.TrapFixedWindow,
	}, ratelimit.NewMetrics(met.Registry()))

	api := httpapi.New(cfg, log, met, cached, version)
	// SetRedis OLMADAN a.rdb NIL KALIR ve ona bağlı tuzaklar SESSİZCE ÖLÜR.
	// EN: 04-06 wire this in their single main; from 07 on every per-service main must wire it too.
	//     Without it `TRAP_READY_CHECKS_REDIS` (P10-02) reads its flag, finds `a.rdb == nil` and does
	//     nothing — the experiment runs, measures no difference and reports "readiness is fine",
	//     which is the OPPOSITE of the lesson. A feature flag guarded by a nil dependency is not
	//     disabled, it is INVISIBLE: nothing fails, nothing logs.
	// TR: 04-06 bunu tek main'lerinde bağlar; 07'den itibaren servis başına her main de bağlamalı.
	//     Bağlamazsa `TRAP_READY_CHECKS_REDIS` (P10-02) bayrağını okur, `a.rdb == nil` görür ve
	//     hiçbir şey yapmaz — deney koşar, fark bulamaz ve "readiness sorunsuz" der; dersin TAM
	//     TERSİ. Nil bir bağımlılığın arkasındaki bayrak kapalı değil GÖRÜNMEZdir: hiçbir şey
	//     patlamaz, hiçbir şey loglanmaz.
	api.SetRedis(rdb)
	api.SetDistributedLimiter(dist)
	api.SetClicks(clicks)
	srv := api.Server(api.APIHandler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst)))

	errCh := make(chan error, 1)
	go func() {
		log.Info("api-svc dinleniyor", "addr", cfg.Addr, "version", version)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()
	api.SetReady(true)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	select {
	case err := <-errCh:
		log.Error("sunucu hatası", "err", err)
		os.Exit(1)
	case <-stop:
	}
	api.SetReady(false)
	time.Sleep(cfg.ShutdownGrace / 4)
	shutCtx, sc := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer sc()
	_ = srv.Shutdown(shutCtx)
	flushCtx, fc := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	_ = clicks.Flush(flushCtx)
	fc()
	log.Info("temiz kapandı")
}
