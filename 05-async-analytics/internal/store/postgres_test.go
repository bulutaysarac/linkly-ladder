package store

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
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
	dsn := migratedDSN(t)
	db, err := Open(context.Background(), dsn, 5, NewDBMetrics(prometheus.NewRegistry()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	return db
}

// migratedDSN — şemayı kur, tabloyu boşalt, DSN'i ver (DATABASE_URL yoksa testi atla).
func migratedDSN(t *testing.T) string {
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
	return dsn
}

// Havuz beklemesi GERÇEKTEN ölçülüyor mu? (P02-06, P05-03 bu metriğe dayanıyor.)
// EN: Hold every connection of a 2-connection pool, start a query, release after 200 ms. The
// acquire hidden INSIDE QueryRow reaches acquireTracer, so the observed wait covers those 200 ms
// and the empty-acquire counter sees a pool at its ceiling. db_query_duration_seconds is what the
// request sees — wait + query — so it covers them too.
// TR: 2 bağlantılık havuzun iki bağlantısını da tut, bir sorgu başlat, 200 ms sonra bırak.
// QueryRow'un İÇİNDEKİ alım acquireTracer'a ulaşır: gözlenen bekleme o 200 ms'yi kapsar ve boş
// alma sayacı tavandaki havuzu görür. db_query_duration_seconds isteğin gördüğü süredir —
// bekleme + sorgu — yani o da 200 ms'yi kapsar.
func TestAcquireWaitMeasuresRealPoolWait(t *testing.T) {
	dsn := migratedDSN(t)
	ctx := context.Background()
	reg := prometheus.NewRegistry()
	db, err := Open(ctx, dsn, 2, NewDBMetrics(reg))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var held []*pgxpool.Conn
	for i := 0; i < 2; i++ {
		c, err := db.Pool().Acquire(ctx)
		if err != nil {
			t.Fatal(err)
		}
		held = append(held, c)
	}
	done := make(chan error, 1)
	go func() { _, err := db.Count(ctx); done <- err }()
	time.Sleep(200 * time.Millisecond)
	for _, c := range held {
		c.Release()
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	var wait, empty, query float64
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		switch mf.GetName() {
		case "db_pool_acquire_duration_seconds":
			wait = mf.GetMetric()[0].GetHistogram().GetSampleSum()
		case "db_pool_empty_acquire_total":
			empty = mf.GetMetric()[0].GetCounter().GetValue()
		case "db_query_duration_seconds":
			for _, m := range mf.GetMetric() {
				for _, l := range m.GetLabel() {
					if l.GetName() == "op" && l.GetValue() == "count" {
						query = m.GetHistogram().GetSampleSum()
					}
				}
			}
		}
	}
	if wait < 0.15 {
		t.Fatalf("havuz 200 ms doluydu ama ölçülen bekleme %.4f s — metrik beklemeyi görmüyor", wait)
	}
	if empty < 1 {
		t.Fatalf("havuz tavandayken alma yapıldı ama db_pool_empty_acquire_total = %v", empty)
	}
	if query < 0.15 {
		t.Fatalf("db_query_duration_seconds beklemeyi de içermeli (bekleme + sorgu), ama count için %.4f s", query)
	}
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
