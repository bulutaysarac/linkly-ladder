// Command linkly — seviye 02, "kalıcılık ve yatay ölçek".
//
// EN: The application is now STATELESS. That single word is what buys N replicas, clean rollouts,
//
//	node drains and horizontal scaling — none of which were available at level 01, not because of
//	missing Kubernetes features but because the data lived inside the process. The cost is that
//	every request now crosses a network to a database that this level treats as always-up and
//	infinitely fast. It is neither (P02-01 … P02-08).
//
// TR: Uygulama artık DURUMSUZ. N replika, temiz rollout, node drain ve yatay ölçeklenme bu tek
//
//	kelimenin karşılığı — hiçbiri 01'de yoktu, Kubernetes özelliği eksik olduğu için değil, veri
//	sürecin içinde yaşadığı için. Bedeli: artık her istek, bu seviyenin hep ayakta ve sonsuz hızlı
//	varsaydığı bir veritabanına ağ üzerinden gidiyor. İkisi de doğru değil (P02-01 … P02-08).
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

	"github.com/bulutaysarac/linkly-ladder/02-postgres/internal/config"
	"github.com/bulutaysarac/linkly-ladder/02-postgres/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/02-postgres/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/02-postgres/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/02-postgres/internal/store"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
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

	rl := ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst)
	api := httpapi.New(cfg, log, met, db, version)
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
	// ÖNCE/SONRA SÜRÜMÜNÜ YAZ. "migration koşuluyor" satırı, yapacak işi olmayan (şema zaten
	// hedefte) bir pod'da da basılır; bu satırları sayan bir ölçü, her pod bir no-op koşmuşken
	// "iş N kez yapıldı" der. from=1 to=2 diyen pod işi GERÇEKTEN yaptığını sanıyor;
	// birden fazla pod bunu diyorsa aynı tek seferlik iş birden fazla kez koşmuştur (P02-07).
	// EN: the "migration running" line is printed by pods that have nothing to do, so counting those
	// lines proves no race. from/to shows who actually applied something.
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
