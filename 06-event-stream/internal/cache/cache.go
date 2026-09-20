// Package cache — süreç içi (L1) önbellek: sınırlı LRU + TTL + singleflight + negatif önbellek.
//
// EN: The cheapest possible cache: a map in the pod's memory. It removes most of the database read
//     load measured at P02-01 — and immediately creates a new class of problem, because now there
//     are N copies of the truth and none of them knows when it became wrong (P03-01 … P03-04).
// TR: Mümkün olan en ucuz önbellek: pod belleğinde bir map. P02-01'de ölçülen veritabanı okuma
//     yükünün çoğunu kaldırıyor — ve anında yeni bir sorun sınıfı yaratıyor, çünkü artık gerçeğin
//     N kopyası var ve hiçbiri ne zaman yanlışlandığını bilmiyor (P03-01 … P03-04).
// [Topic · Konu: Cache-aside, LRU, TTL, stampede]
package cache

import (
	"container/list"
	"context"
	"errors"
	"math/rand"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

var ErrNegative = errors.New("negatif önbellek: kayıt yok")

type entry[V any] struct {
	key       string
	val       V
	negative  bool
	expiresAt time.Time
	elem      *list.Element
}

type Metrics struct {
	Ops       *prometheus.CounterVec // layer, result
	Stampede  prometheus.Counter
	Evictions *prometheus.CounterVec // reason
	Entries   prometheus.Gauge
	Errors    *prometheus.CounterVec // op
}

func NewMetrics(reg prometheus.Registerer, layer string) *Metrics {
	m := &Metrics{
		Ops: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "cache_ops_total", Help: "Önbellek işlemi"}, []string{"layer", "result"}),
		Stampede: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "cache_stampede_wait_total", Help: "Aynı anahtarı bekleyen çağrı (singleflight)"}),
		Evictions: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "cache_evictions_total", Help: "Önbellekten çıkarma"}, []string{"reason"}),
		Entries: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "cache_entries", Help: "Önbellekteki kayıt (bu pod)"}),
		Errors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "cache_errors_total", Help: "Önbellek hatası"}, []string{"op"}),
	}
	reg.MustRegister(m.Ops, m.Stampede, m.Evictions, m.Entries, m.Errors)
	// Sıfırla pre-register: "hiç olmadı" ile "raporlamıyor" ayırt edilebilsin.
	for _, r := range []string{"hit", "miss", "negative_hit", "expired"} {
		m.Ops.WithLabelValues(layer, r)
	}
	for _, r := range []string{"capacity", "ttl", "invalidate"} {
		m.Evictions.WithLabelValues(r)
	}
	m.Errors.WithLabelValues("load")
	return m
}

type Config struct {
	Capacity      int
	TTL           time.Duration
	NegativeTTL   time.Duration
	Jitter        float64 // TTL'e eklenen rastgelelik oranı (0.2 = ±%20)
	Layer         string
	NoSingleflight bool // TRAP
	NoNegative     bool // TRAP
	NoJitter       bool // TRAP
}

type LRU[V any] struct {
	mu      sync.Mutex
	cfg     Config
	items   map[string]*entry[V]
	order   *list.List // en yeni önde
	m       *Metrics
	flights map[string]*flight[V]
	rnd     *rand.Rand
	now     func() time.Time
}

type flight[V any] struct {
	done chan struct{}
	val  V
	err  error
}

func New[V any](cfg Config, m *Metrics) *LRU[V] {
	if cfg.Capacity <= 0 {
		cfg.Capacity = 10000
	}
	if cfg.Jitter <= 0 {
		cfg.Jitter = 0.2
	}
	return &LRU[V]{
		cfg: cfg, items: map[string]*entry[V]{}, order: list.New(), m: m,
		flights: map[string]*flight[V]{},
		rnd:     rand.New(rand.NewSource(time.Now().UnixNano())),
		now:     time.Now,
	}
}

// ttlWithJitter — aynı anda dolan TTL'ler aynı anda miss üretir.
// EN: Without jitter, every key written during the same second expires during the same second, and
//     the database sees a periodic spike forever after. Jitter is not noise, it is de-correlation.
// TR: Jitter olmadan aynı saniyede yazılan her anahtar aynı saniyede dolar ve veritabanı sonsuza
//     kadar periyodik bir tepe görür. Jitter gürültü değil, korelasyon kırıcıdır.
// [Topic · Konu: Thundering herd, TTL jitter]
func (c *LRU[V]) ttlWithJitter(base time.Duration) time.Duration {
	if c.cfg.NoJitter {
		return base
	}
	delta := float64(base) * c.cfg.Jitter
	return base + time.Duration((c.rnd.Float64()*2-1)*delta)
}

// GetOrLoad — cache-aside: bul, yoksa yükle, yaz.
// EN: The singleflight wrapper is what stops a cache MISS from becoming a database STAMPEDE: when a
//     hot key expires, a thousand concurrent requests would otherwise all query the database for the
//     same row. One loads, the rest wait. cache_stampede_wait_total going up is not an error — it is
//     proof the guard is working, and you cannot see that from hit ratio alone.
// TR: singleflight sarmalayıcısı, bir önbellek ISKASININ veritabanı İZDİHAMINA dönüşmesini engeller:
//     sıcak bir anahtarın TTL'i dolduğunda binlerce eşzamanlı istek aynı satır için veritabanına
//     giderdi. Biri yükler, kalanı bekler. cache_stampede_wait_total'ın artması hata değil, korumanın
//     çalıştığının kanıtıdır — ve bunu hit oranına bakarak göremezsin.
func (c *LRU[V]) GetOrLoad(ctx context.Context, key string, load func(context.Context) (V, bool, error)) (V, error) {
	var zero V
	if v, negative, ok := c.lookup(key); ok {
		if negative {
			return zero, ErrNegative
		}
		return v, nil
	}

	if c.cfg.NoSingleflight {
		return c.loadAndStore(ctx, key, load)
	}

	c.mu.Lock()
	if f, inflight := c.flights[key]; inflight {
		c.mu.Unlock()
		c.m.Stampede.Inc()
		select {
		case <-f.done:
			return f.val, f.err
		case <-ctx.Done():
			return zero, ctx.Err()
		}
	}
	f := &flight[V]{done: make(chan struct{})}
	c.flights[key] = f
	c.mu.Unlock()

	f.val, f.err = c.loadAndStore(ctx, key, load)
	close(f.done)
	c.mu.Lock()
	delete(c.flights, key)
	c.mu.Unlock()
	return f.val, f.err
}

func (c *LRU[V]) loadAndStore(ctx context.Context, key string, load func(context.Context) (V, bool, error)) (V, error) {
	var zero V
	v, found, err := load(ctx)
	if err != nil {
		c.m.Errors.WithLabelValues("load").Inc()
		return zero, err
	}
	if !found {
		// Negatif önbellek: "yok" da bir cevaptır ve önbelleklenmezse tarama saldırısı (ya da
		// sadece ölü linkler) her seferinde veritabanına iner.
		if !c.cfg.NoNegative {
			c.store(key, zero, true, c.cfg.NegativeTTL)
		}
		return zero, ErrNegative
	}
	c.store(key, v, false, c.cfg.TTL)
	return v, nil
}

func (c *LRU[V]) lookup(key string) (V, bool, bool) {
	var zero V
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.items[key]
	if !ok {
		c.m.Ops.WithLabelValues(c.cfg.Layer, "miss").Inc()
		return zero, false, false
	}
	if c.now().After(e.expiresAt) {
		c.removeLocked(e, "ttl")
		c.m.Ops.WithLabelValues(c.cfg.Layer, "expired").Inc()
		c.m.Ops.WithLabelValues(c.cfg.Layer, "miss").Inc()
		return zero, false, false
	}
	c.order.MoveToFront(e.elem)
	if e.negative {
		c.m.Ops.WithLabelValues(c.cfg.Layer, "negative_hit").Inc()
		return zero, true, true
	}
	c.m.Ops.WithLabelValues(c.cfg.Layer, "hit").Inc()
	return e.val, false, true
}

func (c *LRU[V]) store(key string, v V, negative bool, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.items[key]; ok {
		e.val, e.negative, e.expiresAt = v, negative, c.now().Add(c.ttlWithJitter(ttl))
		c.order.MoveToFront(e.elem)
		return
	}
	e := &entry[V]{key: key, val: v, negative: negative, expiresAt: c.now().Add(c.ttlWithJitter(ttl))}
	e.elem = c.order.PushFront(e)
	c.items[key] = e
	// Sınır: bellek sınırsız büyüyemez (P00-08/P01-04'ün önbellekteki hâli olmasın diye).
	for len(c.items) > c.cfg.Capacity {
		oldest := c.order.Back()
		if oldest == nil {
			break
		}
		c.removeLocked(oldest.Value.(*entry[V]), "capacity")
	}
	c.m.Entries.Set(float64(len(c.items)))
}

func (c *LRU[V]) removeLocked(e *entry[V], reason string) {
	c.order.Remove(e.elem)
	delete(c.items, e.key)
	c.m.Evictions.WithLabelValues(reason).Inc()
	c.m.Entries.Set(float64(len(c.items)))
}

// Invalidate — YEREL geçersiz kılma. Diğer pod'lar bunu DUYMAZ (P03-01).
func (c *LRU[V]) Invalidate(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.items[key]; ok {
		c.removeLocked(e, "invalidate")
	}
}

func (c *LRU[V]) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.items)
}
