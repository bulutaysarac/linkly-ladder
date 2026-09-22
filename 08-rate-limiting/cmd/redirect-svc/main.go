// Command redirect-svc — yalnızca okuma yolu. Trafiğin ~%99'u buradan geçer.
//
// EN: This binary does one thing: turn a short code into a 302. It does not know how to create a
//
//	link, it has no write path to the database beyond the click producer, and its readiness has
//	nothing to do with whether the API is healthy. The narrower the service, the smaller the
//	blast radius of every change you will ever make to it.
//
// TR: Bu binary tek iş yapar: kısa kodu 302'ye çevirir. Link oluşturmayı bilmez, tıklama
//
//	üreticisi dışında veritabanına yazma yolu yoktur ve hazır olması API'nin sağlığıyla
//	ilgisizdir. Servis ne kadar darsa, ona yapacağın her değişikliğin patlama yarıçapı o kadar küçüktür.
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

	// TRAP_UNBOUNDED_QUEUE: tampon SINIRINI kaldır. 05'te bu bir slice'tı ve tuzak kodda
	// okunuyordu; 06'da kuyruk Kafka üreticisine taşınınca tuzak MAIN'DE YALNIZCA BASTIRILAN bir
	// bayrağa dönüştü — deney açıyor, hiçbir şey değişmiyordu. Sınır burada: tampon dolunca
	// üretici kaydı DÜŞÜRÜR (ve sayar). Sınırsızda düşürme yerine bellek büyür ve pod OOM olur:
	// yani "veri kaybetme" kararını almayı reddettiğinde, karar senin yerine kernel tarafından
	// ve en kötü anda alınır (P05-02).
	// EN: when the queue moved from a slice to the Kafka producer the trap became a flag that is
	// only PRINTED. Bounded → the producer drops and counts; unbounded → memory grows and the pod
	// is OOM-killed, i.e. refusing to decide "lose data" hands the decision to the kernel.
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
	api.SetDistributedLimiter(dist)
	api.SetClicks(clicks)
	srv := api.Server(api.RedirectHandler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst)))

	errCh := make(chan error, 1)
	go func() {
		log.Info("redirect-svc dinleniyor", "addr", cfg.Addr, "version", version)
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
