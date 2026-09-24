// Command linkly — seviye 06, "olay akışı, ayrı tüketici".
//
// EN: Click events go to a durable log (Redpanda, Kafka API) instead of process memory; a separate
//
//	deployment (analytics-consumer) writes them to Postgres. Hard kills no longer lose clicks (P05-01)
//	and the writer no longer shares this process (P05-03); delivery becomes at-least-once, absorbed by
//	idempotency (P06-01 … P06-07).
//
// TR: Tıklama olayları süreç belleği yerine dayanıklı bir loga (Redpanda, Kafka API) yazılır; ayrı bir
//
//	deployment (analytics-consumer) onları Postgres'e işler. Sert ölüm tıklama kaybettirmez (P05-01),
//	yazıcı bu süreci paylaşmaz (P05-03); teslimat en-az-bir-kez olur ve idempotency ile emilir
//	(P06-01 … P06-07).
package main

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/bulutaysarac/linkly-ladder/06-event-stream/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/06-event-stream/internal/config"
	"github.com/bulutaysarac/linkly-ladder/06-event-stream/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/06-event-stream/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/06-event-stream/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/06-event-stream/internal/store"
	"github.com/bulutaysarac/linkly-ladder/06-event-stream/internal/stream"
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

	// Tıklamalar artık süreç içi bir kuyruğa değil, DAYANIKLI bir loga gidiyor.
	// Producer bloklamaz; broker düşerse tampon sınırına kadar biriktirir, sonra düşürür.
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
	log.Info("tıklama akışı (kafka)", "brokers", cfg.KafkaBrokers, "topic", cfg.KafkaTopic,
		"max_buffered", cfg.ProducerMaxBuffered)

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
	// Flush: tamponda bekleyen kayıtları broker'a gönder. 05'teki drain'in karşılığı — ama artık
	// hedef dayanıklı bir log olduğu için, flush başarılı olursa olay GERÇEKTEN kaybolmaz.
	log.Info("producer tamponu boşaltılıyor", "bekleyen", clicks.Buffered())
	flushCtx, fc := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	if err := clicks.Flush(flushCtx); err != nil {
		log.Warn("flush tamamlanamadı, bazı olaylar kayboldu", "err", err, "bekleyen", clicks.Buffered())
	}
	fc()
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
	log.Info("migration koşuluyor", "target", cfg.MigrateTarget)
	return goose.UpTo(sqlDB, "migrations", cfg.MigrateTarget)
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
