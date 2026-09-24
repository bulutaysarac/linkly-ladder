// Command linkly — seviye 05, "yazmayı okuma yolundan çıkar".
//
// EN: Every redirect drops a click event into a bounded in-process queue and returns; a separate goroutine
//
//	batches the events into clicks_daily. The hot-row lock of P02-08 disappears; the price is an
//	at-most-once guarantee — a full queue drops clicks, a hard kill loses the buffer (P05-01 … P05-06).
//
// TR: Her redirect sınırlı bir süreç içi kuyruğa bir tıklama olayı bırakıp döner; ayrı bir goroutine
//
//	olayları toplu olarak clicks_daily'ye yazar. P02-08'in sıcak satır kilidi kalkar; bedeli en fazla
//	bir kez teslimattır — dolu kuyruk tıklama düşürür, sert ölüm tamponu kaybeder (P05-01 … P05-06).
package main

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/bulutaysarac/linkly-ladder/05-async-analytics/internal/analytics"
	"github.com/bulutaysarac/linkly-ladder/05-async-analytics/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/05-async-analytics/internal/config"
	"github.com/bulutaysarac/linkly-ladder/05-async-analytics/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/05-async-analytics/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/05-async-analytics/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/05-async-analytics/internal/store"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/redis/go-redis/v9"
)

var version = "dev"

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	cfg := config.Load()
	met := metrics.New(cfg.TrapMetricLabelCode)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// TRAP_MIGRATE_IN_MAIN: migration'ı her pod kendi açılışında koşarsa N replika aynı anda
	// şemayı değiştirmeye çalışır. Doğrusu tek seferlik bir Job'dır (deploy/migrate-job.yaml) ve
	// uygulama yalnızca şemanın HAZIR olmasını bekler. P02-07 farkı ölçüyor.
	if cfg.TrapMigrateInMain {
		log.Warn("TRAP_MIGRATE_IN_MAIN açık: migration main içinde koşacak (README §7)")
		if err := runMigrations(cfg, log); err != nil {
			log.Error("migration başarısız", "err", err)
			os.Exit(1)
		}
	}

	dbMet := store.NewDBMetrics(met.Registry())
	db, err := store.Open(ctx, cfg.DatabaseURL, cfg.DBMaxConns, dbMet)
	if err != nil {
		log.Error("veritabanına bağlanılamadı", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	// EN: Do not start serving until the schema the code expects actually exists. Crashing here is
	//     correct: a pod that serves 500s is worse than a pod that never joins the Endpoints list.
	// TR: Kodun beklediği şema gerçekten var olana kadar hizmete başlama. Burada çökmek DOĞRU:
	//     500 döndüren bir pod, Endpoints listesine hiç girmeyen bir pod'dan daha kötüdür.
	if err := waitForSchema(ctx, db, log); err != nil {
		log.Error("şema hazır değil", "err", err)
		os.Exit(1)
	}
	met.BindPoolStats(db.PoolStats)

	// L2: PAYLAŞILAN önbellek. 03'teki L1 kaldırıldı — tek kopya, tek geçersiz kılma.
	// Timeout'lar kısa ve bilinçli: önbellek YAVAŞSA onu beklemek, DB'ye gitmekten kötüdür.
	rdb := redis.NewClient(&redis.Options{
		Addr:         cfg.RedisAddr,
		DialTimeout:  cfg.RedisTimeout,
		ReadTimeout:  cfg.RedisTimeout,
		WriteTimeout: cfg.RedisTimeout,
		PoolSize:     20,
	})
	defer rdb.Close()
	if err := rdb.Ping(ctx).Err(); err != nil {
		// ÖLÜMCÜL DEĞİL: Redis yoksa DB'ye düşerek çalışmaya devam ederiz (fail-open).
		// Önbelleğe bağımlı olmak, onu veritabanına dönüştürmek demektir — P04-01 bedelini ölçüyor.
		log.Warn("redis'e ulaşılamadı, DB'ye düşerek devam", "err", err, "addr", cfg.RedisAddr)
	}
	l2 := cache.NewRedis[store.Link](rdb, cache.Config{
		TTL:            cfg.CacheTTL,
		NegativeTTL:    cfg.CacheNegativeTTL,
		Layer:          "l2",
		NoSingleflight: cfg.TrapNoSingleflight,
		NoNegative:     cfg.TrapNoNegative,
		NoJitter:       cfg.TrapNoJitter,
	}, cache.NewMetrics(met.Registry(), "l2"), "linkly:link:")
	met.BindRedisStats(func() (hits, misses uint32) {
		st := rdb.PoolStats()
		return st.Hits, st.Misses
	})
	cached := store.NewCached(db, l2)

	// Analitik: tıklamaları istek yolundan çıkaran sınırlı kuyruk + toplu yazıcı.
	clicks := analytics.New(analytics.Config{
		QueueSize:     cfg.QueueSize,
		BatchSize:     cfg.BatchSize,
		FlushInterval: cfg.FlushInterval,
		WriteTimeout:  cfg.ClickWriteTimeout,
		Unbounded:     cfg.TrapUnboundedQueue,
	}, db, analytics.NewMetrics(met.Registry()), log)
	clicks.Start()

	rl := ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst)
	api := httpapi.New(cfg, log, met, cached, version)
	api.SetRedis(rdb)
	api.SetClicks(clicks)
	srv := api.Server(api.Handler(rl))

	if cfg.TrapMetricLabelCode {
		log.Warn("TRAP_METRIC_LABEL_CODE açık: kardinalite patlayacak (README §7)")
	}
	if cfg.TrapLivenessStrict {
		log.Warn("TRAP_LIVENESS_STRICT açık: sağlık uçları iş zincirinde (README §7)")
	}
	if cfg.TrapReadyzChecksDB {
		log.Warn("TRAP_READYZ_CHECKS_DB açık: DB kesintisi TÜM pod'ları trafikten düşürecek (README §7)")
	}
	for name, on := range map[string]bool{
		"TRAP_NO_NEGATIVE_CACHE": cfg.TrapNoNegative,
		"TRAP_NO_TTL_JITTER":     cfg.TrapNoJitter,
		"TRAP_DEBUG_KEYS":        cfg.TrapDebugKeys,
		"TRAP_UPDATE_DELAY":      cfg.TrapUpdateDelayMs > 0,
		"TRAP_UNBOUNDED_QUEUE":   cfg.TrapUnboundedQueue,
		"TRAP_REDIRECT_301":      cfg.TrapRedirect301,
	} {
		if on {
			log.Warn("önbellek tuzağı açık", "flag", name, "bkz", "README §7")
		}
	}
	log.Info("L2 önbellek (redis)", "addr", cfg.RedisAddr, "ttl", cfg.CacheTTL,
		"negative_ttl", cfg.CacheNegativeTTL, "timeout", cfg.RedisTimeout)
	log.Info("analitik kuyruğu", "size", cfg.QueueSize, "batch", cfg.BatchSize,
		"flush", cfg.FlushInterval, "unbounded", cfg.TrapUnboundedQueue)

	errCh := make(chan error, 1)
	go func() {
		log.Info("dinleniyor", "addr", cfg.Addr, "version", version, "db_max_conns", cfg.DBMaxConns)
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
	case sig := <-stop:
		log.Info("kapatma sinyali", "signal", sig.String())
	}

	// Kapatma sırası 01'deki ile aynı ve aynı nedenle: önce readiness düş, Endpoints yayılımını
	// bekle, sonra Shutdown. Durum artık dışarıda olduğu için kaybedecek veri yok — ama
	// işlenmekte olan istekler hâlâ var.
	api.SetReady(false)
	log.Info("readiness düşürüldü, endpoint yayılımı bekleniyor", "wait", cfg.ShutdownGrace/4)
	time.Sleep(cfg.ShutdownGrace / 4)

	shutCtx, shutCancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer shutCancel()
	if err := srv.Shutdown(shutCtx); err != nil {
		log.Error("graceful shutdown tamamlanamadı", "err", err)
		os.Exit(1)
	}
	// EN: Drain AFTER the server is down, never before. Draining first would write a batch and then
	//     keep accepting new clicks that nobody drains. The order here is the difference between
	//     "we lose a second of clicks on every deploy" and "we don't" — and it only works because
	//     terminationGracePeriodSeconds gives the process time to finish.
	// TR: Kuyruğu sunucu kapandıktan SONRA boşalt, asla önce. Önce boşaltmak, bir parti yazıp sonra
	//     kimsenin boşaltmadığı yeni tıklamalar kabul etmeye devam etmek demektir. Buradaki sıra,
	//     "her dağıtımda bir saniyelik tıklama kaybediyoruz" ile "kaybetmiyoruz" arasındaki farktır
	//     — ve yalnızca terminationGracePeriodSeconds sürece zaman verdiği için işe yarar.
	log.Info("analitik kuyruğu boşaltılıyor", "kalan", clicks.Depth())
	clicks.Stop()
	log.Info("temiz kapandı")
}

func runMigrations(cfg config.Config, log *slog.Logger) error {
	sqlDB, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer sqlDB.Close()
	goose.SetBaseFS(store.Migrations)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	// ÖNCE/SONRA SÜRÜMÜNÜ YAZ. "migration koşuluyor" satırını yapacak işi olmayan (şema zaten
	// hedefte) bir pod da basar; bu satırları saymak "iş N kez yapıldı" der, oysa o pod'lar yalnızca
	// bir no-op koşmuştur. from=1 to=2 diyen pod işi GERÇEKTEN yapmıştır; birden fazla pod bunu
	// diyorsa aynı tek seferlik iş birden fazla kez koşmuştur.
	// EN: the "migration running" line is also printed by pods that have nothing to do, so counting
	// it overstates the race. from/to shows who actually applied something.
	log.Info("migration koşuluyor", "target", cfg.MigrateTarget)
	from, _ := goose.GetDBVersion(sqlDB)
	start := time.Now()
	if err := goose.UpTo(sqlDB, "migrations", cfg.MigrateTarget); err != nil {
		return err
	}
	to, _ := goose.GetDBVersion(sqlDB)
	log.Info("migration bitti", "from", from, "to", to, "target", cfg.MigrateTarget, "sure_ms", time.Since(start).Milliseconds())
	return nil
}

// waitForSchema — şema gelene kadar bekle (migration Job'ı henüz bitmemiş olabilir).
func waitForSchema(ctx context.Context, db *store.Postgres, log *slog.Logger) error {
	var lastErr error
	for i := 0; i < 30; i++ {
		if err := db.Ping(ctx); err != nil {
			lastErr = err
		} else if _, err := db.Count(ctx); err == nil {
			return nil
		} else {
			lastErr = err
		}
		log.Info("şema bekleniyor", "deneme", i+1, "err", lastErr)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	return lastErr
}
