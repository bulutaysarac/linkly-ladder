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

	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/auth"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/config"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/resilience"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/store"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/stream"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/tracing"
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

	redisOpts := &redis.Options{
		Addr: cfg.RedisAddr, DialTimeout: cfg.RedisTimeout,
		ReadTimeout: cfg.RedisTimeout, WriteTimeout: cfg.RedisTimeout, PoolSize: 20,
	}
	if cfg.TrapNoDepTimeout {
		// TRAP (P10-05): "bağımlılık timeout'u yok", İSTEMCİNİN kendi süre sınırlarını da kapsar.
		// EN: a timeout lives wherever the deadline is ENFORCED. Removing only the guard's 2 s
		//     timeout would leave the Redis client's own 500 ms dial/read/write deadlines in place:
		//     under `redis-delay-3s` every call would still fail after 0.5 s and P10-05 would
		//     measure a system that still has a timeout. go-redis ignores context deadlines on
		//     reads unless ContextTimeoutEnabled is set, so the deadline that counts is here, in
		//     the client's socket options.
		// TR: Timeout, süre sınırının UYGULANDIĞI yerdedir. Yalnızca guard'ın 2 sn'lik timeout'unu
		//     kaldırmak, Redis istemcisinin kendi 500 ms'lik bağlanma/okuma/yazma sınırlarını yerinde
		//     bırakırdı: `redis-delay-3s` altında her çağrı yine 0,5 sn'de düşer ve P10-05 hâlâ
		//     timeout'u olan bir sistemi ölçerdi. go-redis, ContextTimeoutEnabled açılmadıkça
		//     okumada bağlamın süresine bakmaz; geçerli süre sınırı burada, istemcinin soket
		//     ayarlarındadır.
		redisOpts.DialTimeout = time.Hour
		redisOpts.ReadTimeout, redisOpts.WriteTimeout = -1, -1 // go-redis: -1 = süresiz bekle
	}
	rdb := redis.NewClient(redisOpts)
	defer rdb.Close()

	// Dayanıklılık katmanı: devre kesici + bulkhead + timeout + bütçeli retry — HER BAĞIMLILIĞA AYRI.
	resMet := resilience.NewMetrics(met.Registry())
	depTimeout, redisTimeout := cfg.DepTimeout, cfg.RedisTimeout
	if cfg.TrapNoDepTimeout {
		// TRAP: timeout yok → yavaş bir bağımlılık goroutine'leri ve belleği şişirir (P10-05).
		depTimeout, redisTimeout = time.Hour, time.Hour
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
	degrade := func(mode string, active bool) {
		v := 0.0
		if active {
			v = 1
		}
		resMet.Degraded.WithLabelValues(mode).Set(v)
	}
	pgGuard := resilience.NewGuard(resilience.Config{
		Name: "postgres", FailureThreshold: threshold, OpenDuration: cfg.BreakerOpen,
		MaxConcurrent: cfg.DepMaxConcurrent, Timeout: depTimeout,
		MaxRetries: retries, RetryBudget: budget,
	}, resMet)
	// Redis'in KENDİ guard'ı: kendi devre kesicisi, bulkhead'i, timeout'u ve `dep="redis"` etiketi.
	// EN: one guard per dependency, so each is measured and tripped under its own name: a slow
	//     Redis shows up as dep="redis" ("App → Redis latency"), never inside the postgres
	//     histogram, and a Redis outage opens the Redis breaker and marks `no_cache` (P10-02)
	//     without touching the database's breaker or bulkhead. No retries for a cache: its
	//     fallback is the database, not another attempt. Its timeout matches the client's own
	//     socket deadline — the place where it is actually enforced.
	// TR: bağımlılık başına bir guard; her biri kendi adıyla ölçülür ve açılır: yavaş bir Redis
	//     dep="redis" altında görünür ("Uygulama → Redis gecikmesi"), asla postgres histogramının
	//     içinde değil; Redis kesintisi Redis devresini açar ve `no_cache`'i işaretler (P10-02),
	//     veritabanının devre kesicisine ve bulkhead'ine dokunmadan. Önbelleğe retry yok:
	//     önbelleğin yedeği bir deneme daha değil, veritabanıdır. Timeout'u istemcinin kendi
	//     soket süre sınırıyla aynı — gerçekten uygulandığı yer.
	redisGuard := resilience.NewGuard(resilience.Config{
		Name: "redis", FailureThreshold: threshold, OpenDuration: cfg.BreakerOpen,
		MaxConcurrent: cfg.DepMaxConcurrent, Timeout: redisTimeout,
	}, resMet)

	// Katman sırası: Cached(Redis, guard=redis) → ReadWrite → Guarded(postgres) → Postgres.
	// EN: the postgres guard sits UNDER the cache and wraps only database calls. Cache hits never
	//     reach it, so `cache_only` degrade is real (breaker open → hits still served, only misses
	//     fail), and ReadWrite's sticky-marker lookup — a Redis call — stays out of the postgres
	//     timing.
	// TR: postgres guard'ı önbelleğin ALTINDA ve yalnızca veritabanı çağrılarını sarıyor. Önbellek
	//     isabetleri ona hiç uğramaz: `cache_only` degrade GERÇEK olur (devre açık → isabetler yine
	//     cevaplanır, yalnızca ıskalar düşer) ve ReadWrite'ın yapışkan işaret sorgusu — bir Redis
	//     çağrısı — postgres ölçümünün dışında kalır.
	guardedPrimary := store.NewGuarded(primary, pgGuard, degrade)
	var db store.Store = guardedPrimary

	// Okuma/yazma ayrımı: DATABASE_URL_RO verilmişse okumalar replikalara gider.
	// Sticky pencere, yazma sonrası okumaları primary'ye yapıştırarak read-your-writes'ı korur.
	// İşaret PAYLAŞILAN (Redis): oluşturma api-svc'de, yönlendirme redirect-svc'de olduğu için
	// süreç içi bir işaret iki servis arasında hiçbir zaman görünmezdi (bkz. store/recent.go).
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
			// Primary ve replika AYNI guard'ı paylaşır: devre kesici bağımlılık başınadır ("postgres").
			db = store.NewReadWrite(guardedPrimary, store.NewGuarded(replica, pgGuard, degrade),
				sticky, store.NewRWMetrics(met.Registry()), recent)
			log.Info("okuma/yazma ayrımı açık", "sticky_window", sticky, "isaret", "redis")
		}
	}
	l2 := cache.NewRedis[store.Link](rdb, cache.Config{
		TTL: cfg.CacheTTL, NegativeTTL: cfg.CacheNegativeTTL, Layer: "l2",
		NoSingleflight: cfg.TrapNoSingleflight, NoNegative: cfg.TrapNoNegative, NoJitter: cfg.TrapNoJitter,
		Guard: store.GuardCall(redisGuard, "no_cache", degrade),
	}, cache.NewMetrics(met.Registry(), "l2"), "linkly:link:")
	cached := store.NewCached(db, l2)

	// TRAP_UNBOUNDED_QUEUE: tampon SINIRINI kaldır. 05'te kuyruk bir slice'tı; 06'dan beri sınırı
	// Kafka üreticisinin tamponu taşıyor, bu yüzden tuzak burada, üreticiye verilen sınıra
	// uygulanır. Tampon dolunca üretici kaydı DÜŞÜRÜR (ve sayar). Sınırsızda düşürme yerine bellek
	// büyür ve pod OOM olur: yani "veri kaybetme" kararını almayı reddettiğinde, karar senin
	// yerine kernel tarafından ve en kötü anda alınır (P05-02).
	// EN: since 06 the bound is the Kafka producer's buffer, so the trap is applied to the limit
	// handed to the producer. Bounded → the producer drops and counts; unbounded → memory grows
	// and the pod is OOM-killed, i.e. refusing to decide "lose data" hands the decision to the kernel.
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

	shedder := resilience.NewShedder(cfg.ShedMaxInFlight, cfg.ShedEnabled, resMet)

	api := httpapi.New(cfg, log, met, cached, version)
	// SetRedis OLMADAN a.rdb NIL KALIR ve ona bağlı tuzaklar SESSİZCE ÖLÜR.
	// EN: every binary that has Redis wires it here. `TRAP_READY_CHECKS_REDIS` (P10-02) reads its
	//     flag and then needs `a.rdb`; with a nil client it would do nothing, the experiment would
	//     measure no difference and report "readiness is fine" — the OPPOSITE of the lesson. A
	//     feature flag guarded by a nil dependency is not disabled, it is INVISIBLE: nothing fails,
	//     nothing logs.
	// TR: Redis'i olan her binary onu burada bağlar. `TRAP_READY_CHECKS_REDIS` (P10-02) bayrağını
	//     okuduktan sonra `a.rdb`'ye ihtiyaç duyar; nil bir client'la hiçbir şey yapmaz, deney fark
	//     bulamaz ve "readiness sorunsuz" der — dersin TAM TERSİ. Nil bir bağımlılığın arkasındaki
	//     bayrak kapalı değil GÖRÜNMEZdir: hiçbir şey patlamaz, hiçbir şey loglanmaz.
	api.SetRedis(rdb)
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
	srv := api.Server(shedder.Middleware(api.APIHandler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst))))

	// Profil uçları AYRI bir iç portta (P11-08). WriteTimeout BİLEREK yok: 30 sn'lik bir CPU
	// profili, servis portunun 15 sn'lik yazma sınırına takılırdı.
	if cfg.PprofAddr != "" {
		go func() {
			ps := &http.Server{Addr: cfg.PprofAddr, Handler: httpapi.PprofHandler(), ReadHeaderTimeout: 3 * time.Second}
			if err := ps.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Warn("pprof ucu açılamadı, profilsiz devam", "addr", cfg.PprofAddr, "err", err)
			}
		}()
	}

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
