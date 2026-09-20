package cache

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// L1 isabeti L2'ye HİÇ gitmemeli: bu, 14'ün tek somut performans vaadi.
func TestL1HitDoesNotTouchL2(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := NewMetrics(reg, "l1")
	l1 := New[string](Config{Capacity: 10, TTL: time.Minute, NegativeTTL: 10 * time.Second, Layer: "l1"}, m)

	var loads int32
	load := func(context.Context) (string, bool, error) {
		atomic.AddInt32(&loads, 1)
		return "v", true, nil
	}
	for i := 0; i < 10; i++ {
		if _, err := l1.GetOrLoad(context.Background(), "k", load); err != nil {
			t.Fatal(err)
		}
	}
	if loads != 1 {
		t.Fatalf("L1 isabetinde alt katmana %d kez gidildi, 1 bekleniyordu", loads)
	}
}

// Yayın kaçarsa bayatlık penceresi L1 TTL'i kadar olmalı — bu yüzden TTL KISA.
func TestL1TTLBoundsStalenessWindow(t *testing.T) {
	m := NewMetrics(prometheus.NewRegistry(), "l1")
	l1 := New[string](Config{Capacity: 10, TTL: 60 * time.Millisecond, NegativeTTL: 10 * time.Millisecond,
		Jitter: 0.01, Layer: "l1"}, m)

	var version atomic.Int32
	version.Store(1)
	load := func(context.Context) (string, bool, error) {
		if version.Load() == 1 {
			return "eski", true, nil
		}
		return "yeni", true, nil
	}
	if v, _ := l1.GetOrLoad(context.Background(), "k", load); v != "eski" {
		t.Fatalf("beklenmeyen: %s", v)
	}
	// Alt katman değişti ama YAYIN KAÇTI (Invalidate çağrılmadı).
	version.Store(2)
	if v, _ := l1.GetOrLoad(context.Background(), "k", load); v != "eski" {
		t.Fatalf("TTL dolmadan taze değer geldi: %s", v)
	}
	time.Sleep(120 * time.Millisecond)
	if v, _ := l1.GetOrLoad(context.Background(), "k", load); v != "yeni" {
		t.Fatalf("TTL dolduktan sonra hâlâ bayat: %s — bayatlık penceresi sınırsız", v)
	}
}

func TestInvalidateClearsL1Immediately(t *testing.T) {
	m := NewMetrics(prometheus.NewRegistry(), "l1")
	l1 := New[string](Config{Capacity: 10, TTL: time.Hour, Layer: "l1"}, m)
	var version atomic.Int32
	version.Store(1)
	load := func(context.Context) (string, bool, error) {
		if version.Load() == 1 {
			return "eski", true, nil
		}
		return "yeni", true, nil
	}
	_, _ = l1.GetOrLoad(context.Background(), "k", load)
	version.Store(2)
	l1.Invalidate("k")
	if v, _ := l1.GetOrLoad(context.Background(), "k", load); v != "yeni" {
		t.Fatalf("yerel geçersiz kılma çalışmadı: %s", v)
	}
}
