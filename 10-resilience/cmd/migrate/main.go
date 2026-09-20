// Command migrate — şemayı hedef sürüme getirir ve çıkar. Tek seferlik Job olarak koşar.
//
// EN: A separate binary, not a flag on the server: the migration image must be runnable without the
//
//	server's config, its readiness semantics or its port. Sharing the module (and therefore the
//	embedded migrations) guarantees the schema and the code that expects it ship together.
//
// TR: Sunucuya bayrak değil, AYRI bir binary: migration imajı, sunucunun ayarlarına, hazır olma
//
//	semantiğine ya da portuna ihtiyaç duymadan koşabilmeli. Modülü (dolayısıyla gömülü
//	migration'ları) paylaşmak, şemanın ve onu bekleyen kodun birlikte dağıtılmasını garantiler.
package main

import (
	"database/sql"
	"log/slog"
	"os"
	"time"

	"github.com/bulutaysarac/linkly-ladder/10-resilience/internal/config"
	"github.com/bulutaysarac/linkly-ladder/10-resilience/internal/store"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

var version = "dev"

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	cfg := config.Load()

	db, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		log.Error("dsn hatalı", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	// Postgres henüz ayakta olmayabilir: Job, StatefulSet ile yarışır. Beklemek Job'ın işi —
	// initContainer'a gerek yok, çünkü zaten "hazır olana kadar dene" semantiği istiyoruz.
	var lastErr error
	for i := 0; i < 60; i++ {
		if lastErr = db.Ping(); lastErr == nil {
			break
		}
		log.Info("veritabanı bekleniyor", "deneme", i+1, "err", lastErr)
		time.Sleep(2 * time.Second)
	}
	if lastErr != nil {
		log.Error("veritabanına ulaşılamadı", "err", lastErr)
		os.Exit(1)
	}

	goose.SetBaseFS(store.Migrations)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("postgres"); err != nil {
		log.Error("dialect", "err", err)
		os.Exit(1)
	}
	before, _ := goose.GetDBVersion(db)
	if err := goose.UpTo(db, "migrations", cfg.MigrateTarget); err != nil {
		log.Error("migration başarısız", "err", err, "target", cfg.MigrateTarget)
		os.Exit(1)
	}
	after, _ := goose.GetDBVersion(db)
	log.Info("migration tamam", "version", version, "from", before, "to", after, "target", cfg.MigrateTarget)
}
