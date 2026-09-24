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
	"github.com/redis/go-redis/v9"
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

// Önbelleğe SORMANIN bedeli katman başına ölçülüyor mu — ve DB'den yükleme ona KARIŞMIYOR mu?
// P04-02 L2'nin ağ gidiş-gelişini L1'in bellek aramasıyla bu histogram üzerinden karşılaştırıyor.
// Yükleyici 20 ms uyuyor: ölçüye karışsaydı toplam 20 ms'yi geçerdi.
func TestLookupDurationObservedWithoutLoad(t *testing.T) {
	reg := prometheus.NewRegistry()
	c := New[string](Config{Capacity: 10, TTL: time.Minute, NegativeTTL: time.Second, Layer: "l1"}, NewMetrics(reg, "l1"))
	slow := func(context.Context) (string, bool, error) { time.Sleep(20 * time.Millisecond); return "v", true, nil }
	for i := 0; i < 3; i++ {
		if v, err := c.GetOrLoad(context.Background(), "k", slow); err != nil || v != "v" {
			t.Fatalf("beklenmeyen: %v %v", v, err)
		}
	}
	n, sum := lookupStats(t, reg, "l1")
	if n != 3 {
		t.Fatalf("3 arama bekleniyordu (1 ıska + 2 isabet), histogram %d saydı", n)
	}
	if sum >= 0.02 {
		t.Fatalf("arama süresi toplamı %.4f s — DB'den yükleme ölçüye karışmış", sum)
	}
}

func lookupStats(t *testing.T, reg *prometheus.Registry, layer string) (uint64, float64) {
	t.Helper()
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() != "cache_lookup_duration_seconds" {
			continue
		}
		for _, m := range mf.GetMetric() {
			for _, lp := range m.GetLabel() {
				if lp.GetName() == "layer" && lp.GetValue() == layer {
					return m.GetHistogram().GetSampleCount(), m.GetHistogram().GetSampleSum()
				}
			}
		}
	}
	t.Fatalf("cache_lookup_duration_seconds{layer=%q} yayınlanmıyor", layer)
	return 0, 0
}

// L2 araması = bir ağ gidiş-gelişi. Redis'e ulaşılamasa bile (fail-open) deneme histograma düşer
// ve DB'ye düşülen yükleme (100 ms) ona karışmaz: ölçülen şey yalnızca Redis'e sormanın bedeli.
func TestRedisLookupObservedWithoutLoad(t *testing.T) {
	// Yeniden denemeleri kapat: go-redis varsayılanı 5 bağlantı denemesi × 100 ms bekleme; ölçü onu da
	// (doğru olarak) sayardı ama bu testin sorusu yüklemenin karışıp karışmadığı.
	rdb := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1", DialTimeout: 50 * time.Millisecond,
		MaxRetries: -1, DialerRetries: 1, DialerRetryTimeout: time.Millisecond})
	defer rdb.Close()
	reg := prometheus.NewRegistry()
	c := NewRedis[string](rdb, Config{TTL: time.Minute, NegativeTTL: time.Second, Layer: "l2"}, NewMetrics(reg, "l2"), "t:")
	v, err := c.GetOrLoad(context.Background(), "k", func(context.Context) (string, bool, error) {
		time.Sleep(100 * time.Millisecond)
		return "v", true, nil
	})
	if err != nil || v != "v" {
		t.Fatalf("fail-open çalışmadı: %v %v", v, err)
	}
	n, sum := lookupStats(t, reg, "l2")
	if n != 1 {
		t.Fatalf("1 L2 araması bekleniyordu, histogram %d saydı", n)
	}
	if sum >= 0.1 {
		t.Fatalf("L2 arama süresi %.3f s — DB'den yükleme ölçüye karışmış", sum)
	}
}
