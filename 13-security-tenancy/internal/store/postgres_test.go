package store

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/prometheus/client_golang/prometheus"
)

// Entegrasyon testi: gerçek Postgres gerektirir, yoksa ATLANIR.
//
//	docker run --rm -d -p 55432:5432 -e POSTGRES_PASSWORD=linkly -e POSTGRES_USER=linkly -e POSTGRES_DB=linkly postgres:17-alpine
//	DATABASE_URL='postgres://linkly:linkly@127.0.0.1:55432/linkly?sslmode=disable' go test ./internal/store/
//
// EN: Skipping is not hiding: the skip message says exactly how to run it. A test that silently
//
//	does nothing is worse than no test, so the message is part of the test.
//
// TR: Atlamak saklamak değil: atlama mesajı nasıl koşulacağını birebir söylüyor. Sessizce hiçbir
//
//	şey yapmayan bir test, test olmamasından kötüdür; bu yüzden mesaj testin parçası.
func openTestDB(t *testing.T) *Postgres {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL yok — entegrasyon testi atlandı. Çalıştırmak için dosyanın başındaki komuta bak.")
	}
	sqlDB, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()
	goose.SetBaseFS(Migrations)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(sqlDB, "migrations", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := sqlDB.Exec("TRUNCATE links"); err != nil {
		t.Fatal(err)
	}
	db, err := Open(context.Background(), dsn, 5, NewDBMetrics(prometheus.NewRegistry()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	return db
}

// 00'daki sessiz üzerine yazmanın SQL'deki karşılığı doğru mu?
func TestCreateUniqueIsConditional(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	first := &Link{Code: "abc1234", URL: "https://first", Tenant: "t1", CreatedAt: time.Now().UTC()}
	if err := db.CreateUnique(ctx, first); err != nil {
		t.Fatal(err)
	}
	err := db.CreateUnique(ctx, &Link{Code: "abc1234", URL: "https://second", Tenant: "t2", CreatedAt: time.Now().UTC()})
	if !errors.Is(err, ErrExists) {
		t.Fatalf("ErrExists bekleniyordu, %v geldi", err)
	}
	got, err := db.Get(ctx, "abc1234")
	if err != nil {
		t.Fatal(err)
	}
	if got.URL != "https://first" {
		t.Fatalf("ilk kayıt ezilmiş: %s", got.URL)
	}
}

// Kiracı sınırı: A, B'nin linkini silememeli.
func TestDeleteRespectsTenant(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	if err := db.CreateUnique(ctx, &Link{Code: "tnt0001", URL: "https://a", Tenant: "tenant-a", CreatedAt: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	if err := db.Delete(ctx, "tenant-b", "tnt0001"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("yabancı kiracı silebildi ya da yanlış hata: %v", err)
	}
	if _, err := db.Get(ctx, "tnt0001"); err != nil {
		t.Fatalf("link silinmiş olmamalıydı: %v", err)
	}
	if err := db.Delete(ctx, "tenant-a", "tnt0001"); err != nil {
		t.Fatalf("sahibi silemedi: %v", err)
	}
}

func TestIncrementClicksAccumulates(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	if err := db.CreateUnique(ctx, &Link{Code: "clk0001", URL: "https://c", Tenant: "t1", CreatedAt: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 25; i++ {
		if err := db.IncrementClicks(ctx, "clk0001"); err != nil {
			t.Fatal(err)
		}
	}
	l, err := db.Get(ctx, "clk0001")
	if err != nil {
		t.Fatal(err)
	}
	if l.Clicks != 25 {
		t.Fatalf("25 tıklama bekleniyordu, %d", l.Clicks)
	}
}

func TestGetMissingReturnsNotFound(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.Get(context.Background(), "zzzzzzz"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("ErrNotFound bekleniyordu, %v", err)
	}
}
