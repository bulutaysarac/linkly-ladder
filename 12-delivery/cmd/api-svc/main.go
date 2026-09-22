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

	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/config"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/resilience"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/store"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/stream"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/tracing"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
)

var version = "dev"

// logLevel — LOG_LEVEL env'inden. debug seviyesi yüksek trafikte Loki'yi limitler (P11-05):
// gözlemlenebilirliğin de bir kapasitesi vardır ve onu aşmak, gözlemi tamamen kaybettirir.
func logLevel() slog.Level {
	switch os.Getenv("LOG_LEVEL") {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel()}))
	cfg := config.Load()
	met := metrics.New(cfg.TrapMetricLabelCode, cfg.TrapTenantLabel)

	// Tracing: metrikten trace'e, log'dan trace'e köprüler burada kuruluyor.
	shutdownTracing, terr := tracing.Setup(context.Background(), tracing.Config{
		Endpoint: cfg.OTLPEndpoint, ServiceName: "linkly-api",
		Version: version, SampleRatio: cfg.TraceSampleRatio, Enabled: cfg.TracingEnabled,
	})
	if terr != nil {
		// Trace kurulamazsa UYGULAMA DURMAZ: gözlemlenebilirlik, gözlemlenen şeyi düşürmemeli.
		log.Warn("tracing kurulamadı, izleme olmadan devam", "err", terr)
		shutdownTracing = func(context.Context) error { return nil }
	}
	defer func() {
		sctx, sc := context.WithTimeout(context.Background(), 5*time.Second)
		_ = shutdownTracing(sctx)
		sc()
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	dbMet := store.NewDBMetrics(met.Registry())
	// Okuma servisi DAHA KÜÇÜK bir havuzla yaşar: çoğu istek önbellekten dönüyor ve replika
	// sayısı yüksek olacak (HPA). Havuz × replika, Postgres'in max_connections'ını aşmamalı (P02-02).
	primary, err := store.OpenWithMode(ctx, cfg.DatabaseURL, cfg.DBMaxConns, dbMet, cfg.TrapPreparedStatements)
	if err != nil {
		log.Error("primary'ye bağlanılamadı", "err", err)
		os.Exit(1)
	}
	defer primary.Close()
	met.BindPoolStats(primary.PoolStats)

	rdb := redis.NewClient(&redis.Options{
		Addr: cfg.RedisAddr, DialTimeout: cfg.RedisTimeout,
		ReadTimeout: cfg.RedisTimeout, WriteTimeout: cfg.RedisTimeout, PoolSize: 20,
	})
	defer rdb.Close()

	// Okuma/yazma ayrımı: DATABASE_URL_RO verilmişse okumalar replikalara gider.
	// Sticky pencere, yazma sonrası okumaları primary'ye yapıştırarak read-your-writes'ı korur.
	// İşaret PAYLAŞILAN (Redis): oluşturma api-svc'de, yönlendirme redirect-svc'de olduğu için
	// süreç içi bir işaret iki servis arasında hiçbir zaman görünmezdi (bkz. store/recent.go).
	var db store.Store = primary
	if cfg.DatabaseURLRO != "" {
		replica, rerr := store.OpenWithMode(ctx, cfg.DatabaseURLRO, cfg.DBMaxConns, dbMet, cfg.TrapPreparedStatements)
		if rerr != nil {
			// Replika yoksa PRIMARY'ye düş: okuma ölçeklenmesini kaybederiz, hizmeti değil.
			log.Warn("replikaya bağlanılamadı, okumalar primary'den yapılacak", "err", rerr)
		} else {
			defer replica.Close()
			sticky := cfg.StickyWindow
			if cfg.TrapNoSticky {
				sticky = 0
			}
			recent := store.NewSharedRecent(rdb, "linkly:ryw:", 2*time.Minute)
			db = store.NewReadWrite(primary, replica, sticky, store.NewRWMetrics(met.Registry()), recent)
			log.Info("okuma/yazma ayrımı açık", "sticky_window", sticky, "isaret", "redis")
		}
	}
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
	clicks.SetNoPropagation(cfg.TrapNoTracePropagation)
	defer clicks.Close()

	// Paylaşılan limiter: limit artık pod başına değil, SİSTEM genelinde geçerli.
	dist := ratelimit.NewDistributed(ctx, rdb, ratelimit.DistConfig{
		Window:      cfg.RateLimitWindow,
		PerIP:       cfg.RateLimitPerIP,
		PerTenant:   cfg.RateLimitPerTenant,
		FailOpen:    cfg.RateLimitFailOpen,
		FixedWindow: cfg.TrapFixedWindow,
	}, ratelimit.NewMetrics(met.Registry()))

	// Dayanıklılık katmanı: devre kesici + bulkhead + timeout + bütçeli retry.
	resMet := resilience.NewMetrics(met.Registry())
	depTimeout := cfg.DepTimeout
	if cfg.TrapNoDepTimeout {
		// TRAP: timeout yok → yavaş bir bağımlılık goroutine'leri ve belleği şişirir (P10-05).
		depTimeout = time.Hour
	}
	retries := cfg.DepMaxRetries
	budget := cfg.RetryBudget
	if cfg.TrapNaiveRetry {
		// TRAP: bütçesiz ve agresif retry → hata anında yükü katlar (P10-01).
		retries, budget = 3, 1.0
	}
	threshold := cfg.BreakerThreshold
	if cfg.TrapNoBreaker {
		threshold = 1 << 30 // pratikte hiç açılmaz
	}
	pgGuard := resilience.NewGuard(resilience.Config{
		Name: "postgres", FailureThreshold: threshold, OpenDuration: cfg.BreakerOpen,
		MaxConcurrent: cfg.DepMaxConcurrent, Timeout: depTimeout,
		MaxRetries: retries, RetryBudget: budget,
	}, resMet)
	guarded := store.NewGuarded(cached, pgGuard, func(mode string, active bool) {
		v := 0.0
		if active {
			v = 1
		}
		resMet.Degraded.WithLabelValues(mode).Set(v)
	})
	shedder := resilience.NewShedder(cfg.ShedMaxInFlight, cfg.ShedEnabled, resMet)

	api := httpapi.New(cfg, log, met, guarded, version)
	// SetRedis OLMADAN a.rdb NIL KALIR ve ona bağlı tuzaklar SESSİZCE ÖLÜR.
	// EN: 04-06 wired this and 07+ did not, so `TRAP_READY_CHECKS_REDIS` (P10-02) read its flag,
	//     found `a.rdb == nil` and did nothing — the experiment ran, measured no difference and
	//     reported "readiness is fine", which is the OPPOSITE of the lesson. A feature flag guarded
	//     by a nil dependency is not disabled, it is INVISIBLE: nothing fails, nothing logs.
	// TR: 04-06 bunu bağlıyordu, 07+ bağlamıyordu; `TRAP_READY_CHECKS_REDIS` (P10-02) bayrağını
	//     okuyup `a.rdb == nil` görüyor ve hiçbir şey yapmıyordu — deney koşuyor, fark bulamıyor ve
	//     "readiness sorunsuz" diyordu; dersin TAM TERSİ. Nil bir bağımlılığın arkasındaki bayrak
	//     kapalı değil GÖRÜNMEZdir: hiçbir şey patlamaz, hiçbir şey loglanmaz.
	api.SetRedis(rdb)
	api.SetDistributedLimiter(dist)
	api.SetClicks(clicks)
	srv := api.Server(shedder.Middleware(api.APIHandler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst))))

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
