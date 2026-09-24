package store

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
)

// acquireStats — db_pool_acquire_duration_seconds'ın örnek sayısı, toplamı ve en büyük kovası.
func acquireStats(t *testing.T, reg *prometheus.Registry) (count uint64, sum float64) {
	t.Helper()
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() == "db_pool_acquire_duration_seconds" {
			h := mf.GetMetric()[0].GetHistogram()
			return h.GetSampleCount(), h.GetSampleSum()
		}
	}
	t.Fatal("db_pool_acquire_duration_seconds kayıtlı değil")
	return 0, 0
}

// Bekleme, pgxpool'un Acquire'ının başı ile sonu arasında ölçülmeli: QueryRow/Exec/Begin'in
// içindeki bekleme ancak orada görünür.
func TestAcquireTracerObservesTheWait(t *testing.T) {
	reg := prometheus.NewRegistry()
	tr := acquireTracer{m: NewDBMetrics(reg)}
	ctx := tr.TraceAcquireStart(context.Background(), nil, pgxpool.TraceAcquireStartData{})
	time.Sleep(30 * time.Millisecond) // havuzda boş bağlantı bekleniyor
	tr.TraceAcquireEnd(ctx, nil, pgxpool.TraceAcquireEndData{})
	n, sum := acquireStats(t, reg)
	if n != 1 || sum < 0.03 {
		t.Fatalf("bekleme ölçülmedi: örnek=%d toplam=%.3f sn (≥0.030 bekleniyordu)", n, sum)
	}
}

// Entegrasyon: 1 bağlantılık havuzda bağlantıyı tutarken yapılan sorgu BEKLER ve bu bekleme
// histogramda görünür. DATABASE_URL yoksa atlanır (postgres_test.go'daki komutla koş).
func TestPoolWaitIsVisibleWhenPoolIsFull(t *testing.T) {
	_ = openTestDB(t) // şema (migration) — ya da DATABASE_URL yoksa atlama mesajı
	dsn := os.Getenv("DATABASE_URL")
	reg := prometheus.NewRegistry()
	db, err := Open(context.Background(), dsn, 1, NewDBMetrics(reg))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	held, err := db.Pool().Acquire(context.Background()) // tek bağlantıyı rehin al
	if err != nil {
		t.Fatal(err)
	}
	go func() { time.Sleep(150 * time.Millisecond); held.Release() }()
	if _, err := db.Count(context.Background()); err != nil {
		t.Fatal(err)
	}
	_, sum := acquireStats(t, reg)
	if sum < 0.1 {
		t.Fatalf("dolu havuzda bekleme görünmedi: toplam=%.3f sn", sum)
	}
}
