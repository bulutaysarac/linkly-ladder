package cache

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

func newCache(t *testing.T, cfg Config) *LRU[string] {
	t.Helper()
	if cfg.TTL == 0 {
		cfg.TTL = time.Minute
	}
	if cfg.NegativeTTL == 0 {
		cfg.NegativeTTL = 10 * time.Second
	}
	cfg.Layer = "l1"
	return New[string](cfg, NewMetrics(prometheus.NewRegistry(), "l1"))
}

func loader(v string, found bool) func(context.Context) (string, bool, error) {
	return func(context.Context) (string, bool, error) { return v, found, nil }
}

func TestHitAvoidsSecondLoad(t *testing.T) {
	c := newCache(t, Config{Capacity: 10})
	var loads int32
	load := func(context.Context) (string, bool, error) {
		atomic.AddInt32(&loads, 1)
		return "https://e", true, nil
	}
	for i := 0; i < 5; i++ {
		if v, err := c.GetOrLoad(context.Background(), "k", load); err != nil || v != "https://e" {
			t.Fatalf("beklenmeyen: %v %v", v, err)
		}
	}
	if loads != 1 {
		t.Fatalf("yükleyici %d kez çağrıldı, 1 bekleniyordu — önbellek çalışmıyor", loads)
	}
}

// P03-05'in korunması: TTL dolan sıcak anahtarda tek yükleme olmalı.
func TestSingleflightCollapsesConcurrentMisses(t *testing.T) {
	c := newCache(t, Config{Capacity: 10})
	var loads int32
	release := make(chan struct{})
	load := func(context.Context) (string, bool, error) {
		atomic.AddInt32(&loads, 1)
		<-release // ilk yükleyiciyi tut ki diğerleri gerçekten aynı anda gelsin
		return "v", true, nil
	}
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = c.GetOrLoad(context.Background(), "hot", load) }()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	if loads != 1 {
		t.Fatalf("50 eşzamanlı miss %d yükleme üretti, 1 bekleniyordu — stampede koruması yok", loads)
	}
}

func TestNoSingleflightTrapStampedes(t *testing.T) {
	c := newCache(t, Config{Capacity: 10, NoSingleflight: true})
	var loads int32
	release := make(chan struct{})
	load := func(context.Context) (string, bool, error) {
		atomic.AddInt32(&loads, 1)
		<-release
		return "v", true, nil
	}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = c.GetOrLoad(context.Background(), "hot", load) }()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	if loads < 2 {
		t.Fatalf("TRAP açıkken izdiham bekleniyordu, yükleme sayısı %d", loads)
	}
}

func TestNegativeCacheStopsRepeatedLookups(t *testing.T) {
	c := newCache(t, Config{Capacity: 10})
	var loads int32
	load := func(context.Context) (string, bool, error) {
		atomic.AddInt32(&loads, 1)
		return "", false, nil
	}
	for i := 0; i < 5; i++ {
		if _, err := c.GetOrLoad(context.Background(), "yok", load); !errors.Is(err, ErrNegative) {
			t.Fatalf("ErrNegative bekleniyordu, %v", err)
		}
	}
	if loads != 1 {
		t.Fatalf("negatif önbellek yok: %d yükleme (tarama her seferinde DB'ye iniyor)", loads)
	}
}

func TestNoNegativeTrapHitsLoaderEveryTime(t *testing.T) {
	c := newCache(t, Config{Capacity: 10, NoNegative: true})
	var loads int32
	load := func(context.Context) (string, bool, error) {
		atomic.AddInt32(&loads, 1)
		return "", false, nil
	}
	for i := 0; i < 5; i++ {
		_, _ = c.GetOrLoad(context.Background(), "yok", load)
	}
	if loads != 5 {
		t.Fatalf("TRAP açıkken her çağrı yüklemeli, %d oldu", loads)
	}
}

func TestCapacityEvictsOldest(t *testing.T) {
	c := newCache(t, Config{Capacity: 3})
	for i := 0; i < 5; i++ {
		_, _ = c.GetOrLoad(context.Background(), strconv.Itoa(i), loader("v", true))
	}
	if c.Len() != 3 {
		t.Fatalf("kapasite 3 iken %d kayıt var — bellek sınırsız büyüyor", c.Len())
	}
}

func TestTTLExpiry(t *testing.T) {
	c := newCache(t, Config{Capacity: 10, TTL: 50 * time.Millisecond, Jitter: 0.01})
	var loads int32
	load := func(context.Context) (string, bool, error) { atomic.AddInt32(&loads, 1); return "v", true, nil }
	_, _ = c.GetOrLoad(context.Background(), "k", load)
	time.Sleep(120 * time.Millisecond)
	_, _ = c.GetOrLoad(context.Background(), "k", load)
	if loads != 2 {
		t.Fatalf("TTL sonrası yeniden yükleme bekleniyordu, yükleme: %d", loads)
	}
}

// Jitter'ın işi: aynı anda yazılanlar aynı anda dolmasın.
func TestJitterSpreadsExpiry(t *testing.T) {
	c := newCache(t, Config{Capacity: 1000, TTL: time.Hour, Jitter: 0.2})
	base := c.now()
	c.now = func() time.Time { return base }
	for i := 0; i < 200; i++ {
		_, _ = c.GetOrLoad(context.Background(), strconv.Itoa(i), loader("v", true))
	}
	seen := map[int64]int{}
	c.mu.Lock()
	for _, e := range c.items {
		seen[e.expiresAt.Unix()]++
	}
	c.mu.Unlock()
	if len(seen) < 10 {
		t.Fatalf("TTL'ler yalnızca %d farklı saniyeye dağılmış — jitter çalışmıyor", len(seen))
	}
}

func TestNoJitterTrapAlignsExpiry(t *testing.T) {
	c := newCache(t, Config{Capacity: 1000, TTL: time.Hour, NoJitter: true})
	base := c.now()
	c.now = func() time.Time { return base }
	for i := 0; i < 50; i++ {
		_, _ = c.GetOrLoad(context.Background(), strconv.Itoa(i), loader("v", true))
	}
	seen := map[int64]int{}
	c.mu.Lock()
	for _, e := range c.items {
		seen[e.expiresAt.Unix()]++
	}
	c.mu.Unlock()
	if len(seen) != 1 {
		t.Fatalf("TRAP açıkken tüm TTL'ler aynı ana denk gelmeliydi, %d farklı an var", len(seen))
	}
}

func TestInvalidateIsLocalOnly(t *testing.T) {
	// İki ayrı önbellek = iki ayrı pod. Birinde invalidate, diğerini ETKİLEMEZ (P03-01).
	a := newCache(t, Config{Capacity: 10})
	b := newCache(t, Config{Capacity: 10})
	_, _ = a.GetOrLoad(context.Background(), "k", loader("eski", true))
	_, _ = b.GetOrLoad(context.Background(), "k", loader("eski", true))
	a.Invalidate("k")
	if v, _ := b.GetOrLoad(context.Background(), "k", loader("yeni", true)); v != "eski" {
		t.Fatal("ikinci pod'un önbelleği de temizlendi — testin varsayımı yanlış")
	}
	if v, _ := a.GetOrLoad(context.Background(), "k", loader("yeni", true)); v != "yeni" {
		t.Fatal("invalidate çalışmadı")
	}
}
