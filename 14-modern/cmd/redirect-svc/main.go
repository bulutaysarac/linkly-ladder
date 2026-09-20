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

	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/auth"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/config"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/resilience"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/store"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/stream"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/tracing"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
)

var version = "dev"

// hostname — pod adı, pub/sub'da kendi yayınını ayırt etmek için.
func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return h
}

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
	met := metrics.New(cfg.TrapMetricLabelCode)

	// Tracing: metrikten trace'e, log'dan trace'e köprüler burada kuruluyor.
	shutdownTracing, terr := tracing.Setup(context.Background(), tracing.Config{
		Endpoint: cfg.OTLPEndpoint, ServiceName: "linkly-redirect",
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

	// Okuma/yazma ayrımı: DATABASE_URL_RO verilmişse okumalar replikalara gider.
	// Sticky pencere, yazma sonrası okumaları primary'ye yapıştırarak read-your-writes'ı korur.
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
			db = store.NewReadWrite(primary, replica, sticky, store.NewRWMetrics(met.Registry()))
			log.Info("okuma/yazma ayrımı açık", "sticky_window", sticky)
		}
	}

	rdb := redis.NewClient(&redis.Options{
		Addr: cfg.RedisAddr, DialTimeout: cfg.RedisTimeout,
		ReadTimeout: cfg.RedisTimeout, WriteTimeout: cfg.RedisTimeout, PoolSize: 20,
	})
	defer rdb.Close()
	l2 := cache.NewRedis[store.Link](rdb, cache.Config{
		TTL: cfg.CacheTTL, NegativeTTL: cfg.CacheNegativeTTL, Layer: "l2",
		NoNegative: cfg.TrapNoNegative, NoJitter: cfg.TrapNoJitter,
	}, cache.NewMetrics(met.Registry(), "l2"), "linkly:link:")
	// L1+L2: en sıcak anahtarlar pod belleğinde, gerisi Redis'te, geçersiz kılma pub/sub ile yayınlanıyor.
	var cached *store.Cached
	if cfg.L1Enabled {
		l1 := cache.New[store.Link](cache.Config{
			Capacity: cfg.L1Capacity, TTL: cfg.L1TTL, NegativeTTL: cfg.L1TTL / 2, Layer: "l1",
		}, cache.NewMetrics(met.Registry(), "l1"))
		tm := cache.NewTieredMetrics(met.Registry())
		ch := cfg.InvalidationChan
		if cfg.TrapNoInvalidationPubSub {
			// TRAP: L1 var ama yayın kanalı yok → 03'teki tutarsızlık, L1 TTL'i boyunca geri gelir.
			ch = "linkly:invalidate:disabled"
		}
		tiered := cache.NewTiered[store.Link](l1, l2, rdb, ch, hostname(), cache.NewMetrics(met.Registry(), "tiered"), tm)
		cached = store.NewCachedTiered(db, tiered, tm)
		log.Info("L1+L2 önbellek", "l1_capacity", cfg.L1Capacity, "l1_ttl", cfg.L1TTL,
			"kanal", ch, "pubsub", !cfg.TrapNoInvalidationPubSub)
	} else {
		cached = store.NewCached(db, l2)
		log.Info("yalnızca L2 önbellek")
	}

	clicks, err := stream.NewProducer(strings.Split(cfg.KafkaBrokers, ","), cfg.KafkaTopic,
		cfg.ProducerMaxBuffered, stream.NewProducerMetrics(met.Registry()), log)
	if err != nil {
		log.Error("kafka producer kurulamadı", "err", err)
		os.Exit(1)
	}
	clicks.SetNoPropagation(cfg.TrapNoTracePropagation)
	defer clicks.Close()

	// Paylaşılan limiter: limit artık pod başına değil, SİSTEM genelinde geçerli.
	dist := ratelimit.NewDistributed(ctx, rdb, ratelimit.DistConfig{
		Window:    cfg.RateLimitWindow,
		PerIP:     cfg.RateLimitPerIP,
		PerTenant: cfg.RateLimitPerTenant,
		FailOpen:  cfg.RateLimitFailOpen,
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
	api.SetDistributedLimiter(dist)

	// Kimlik: API anahtarları hash'lenmiş saklanıyor, karşılaştırma sabit zamanlı.
	keys := auth.NewStore(auth.NewMetrics(met.Registry()))
	if n := keys.LoadFromSpec(cfg.APIKeys); n > 0 {
		api.SetAuth(keys)
		log.Info("kimlik doğrulama açık", "anahtar_sayısı", n, "zorunlu", cfg.AuthRequired)
	} else {
		// Anahtar yoksa kimlik doğrulama KURULMAZ. Bu bilinçli: yanlışlıkla boş bir anahtar
		// listesiyle "herkesi reddet" moduna düşmek, bir yapılandırma hatasını kesintiye çevirir.
		log.Warn("API anahtarı tanımlı değil — kimlik doğrulama devre dışı")
	}
	api.SetClicks(clicks)
	srv := api.Server(shedder.Middleware(api.RedirectHandler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst))))

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
