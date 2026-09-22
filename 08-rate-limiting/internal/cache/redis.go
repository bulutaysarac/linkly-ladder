package cache

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

// Redis — L2: pod'ların DIŞINDA, paylaşılan önbellek.
//
// EN: Moving the cache out of the process fixes every consistency problem of level 03 at once:
//
//	one copy, one invalidation, one warm cache that survives deploys. What it buys with is a
//	network hop on the hot path and a new dependency that can be slow, full, or dead. The rule
//	this level teaches: a cache you depend on is no longer a cache, it is a database — unless
//	you make its failure survivable.
//
// TR: Önbelleği süreç dışına taşımak 03'ün bütün tutarlılık sorunlarını tek hamlede çözer: tek
//
//	kopya, tek geçersiz kılma, dağıtımlardan sağ çıkan sıcak bir önbellek. Karşılığında sıcak
//	yola bir ağ adımı ve yavaşlayabilen, dolabilen ya da ölebilen yeni bir bağımlılık koyar.
//	Bu seviyenin öğrettiği kural: bağımlı olduğun bir önbellek artık önbellek değil, veritabanıdır
//	— arızasını hayatta kalınabilir yapmadıkça.
//
// [Topic · Konu: Paylaşılan önbellek, bağımlılık, degrade]
type Redis[V any] struct {
	rdb    *redis.Client
	cfg    Config
	m      *Metrics
	prefix string
	// failOpen: Redis arızasında DB'ye düş (true) ya da hata döndür (false).
	// Bu seviyede HER ZAMAN true — ama 04'te bunun bedeli ölçülüyor (P04-01): DB o yükü kaldırabilmeli.
	failOpen bool
	rnd      func() float64
	// POD İÇİ SINGLEFLIGHT — 04'te YANLIŞLIKLA DÜŞMÜŞTÜ.
	// EN: the comment on GetOrLoad said "per-pod singleflight (kept below)" and there was no
	//     singleflight below. L1 (the in-process LRU of level 03) had it; when the cache moved to
	//     Redis the guard was not carried over, and TRAP_NO_SINGLEFLIGHT — which P03-05 toggles to
	//     prove the guard exists — was left unread in config. So from level 04 on, the stampede
	//     protection was absent AND unmeasurable, while a comment asserted it was there.
	//     A comment is not an implementation, and a trap nobody reads cannot contradict it.
	// TR: GetOrLoad'ın yorumu "pod içi singleflight (aşağıda korunuyor)" diyordu ve aşağıda
	//     singleflight YOKTU. L1'de (03'ün süreç içi LRU'su) vardı; önbellek Redis'e taşınınca
	//     koruma taşınmadı ve P03-05'in korumanın varlığını kanıtlamak için açtığı
	//     TRAP_NO_SINGLEFLIGHT config'de okunmadan kaldı. Yani 04'ten itibaren izdiham koruması
	//     hem YOKTU hem de ÖLÇÜLEMEZDİ, üstelik bir yorum var olduğunu iddia ediyordu.
	//     Yorum bir gerçekleştirim değildir ve kimsenin okumadığı bir tuzak onu yalanlayamaz.
	mu      sync.Mutex
	flights map[string]*flight[V]
}

func NewRedis[V any](rdb *redis.Client, cfg Config, m *Metrics, prefix string) *Redis[V] {
	if cfg.Jitter <= 0 {
		cfg.Jitter = 0.2
	}
	return &Redis[V]{rdb: rdb, cfg: cfg, m: m, prefix: prefix, failOpen: true, rnd: randFloat,
		flights: map[string]*flight[V]{}}
}

const negativeMarker = "\x00NEG"

func (c *Redis[V]) key(k string) string { return c.prefix + k }

func (c *Redis[V]) ttl(base time.Duration) time.Duration {
	if c.cfg.NoJitter {
		return base
	}
	delta := float64(base) * c.cfg.Jitter
	return base + time.Duration((c.rnd()*2-1)*delta)
}

// GetOrLoad — cache-aside, L2 sürümü.
//
// EN: Note what is NOT here: a distributed lock around the load. Cross-process singleflight needs
//
//	a lock, and a lock needs a lease, a renewal and a failure story — real complexity for a
//	partial win. Per-pod singleflight (kept below) collapses N concurrent misses per pod, which
//	is most of the benefit; the remaining cross-pod stampede is bounded by the replica count,
//	not by the request rate. Know which stampede you actually have before buying a lock.
//
// TR: Burada OLMAYAN şeye dikkat: yükleme etrafında dağıtık kilit yok. Süreçler arası singleflight
//
//	bir kilit ister; kilit de kira süresi, yenileme ve arıza senaryosu ister — kısmi bir kazanç
//	için gerçek karmaşıklık. Pod içi singleflight (aşağıda korunuyor) pod başına N eşzamanlı
//	ıskayı birleştirir ki faydanın çoğu budur; kalan pod'lar arası izdiham istek hızıyla değil
//	REPLİKA SAYISIYLA sınırlıdır. Kilit satın almadan önce hangi izdihama sahip olduğunu bil.
func (c *Redis[V]) GetOrLoad(ctx context.Context, k string, load func(context.Context) (V, bool, error)) (V, error) {
	var zero V
	raw, err := c.rdb.Get(ctx, c.key(k)).Result()
	switch {
	case err == nil:
		if raw == negativeMarker {
			c.m.Ops.WithLabelValues(c.cfg.Layer, "negative_hit").Inc()
			return zero, ErrNegative
		}
		var v V
		if jsonErr := json.Unmarshal([]byte(raw), &v); jsonErr != nil {
			// Bozuk kayıt: önbelleği gerçeğin kaynağı sanma. Sil, DB'den yükle, devam et.
			c.m.Errors.WithLabelValues("decode").Inc()
			c.rdb.Del(ctx, c.key(k))
			break
		}
		c.m.Ops.WithLabelValues(c.cfg.Layer, "hit").Inc()
		return v, nil
	case errors.Is(err, redis.Nil):
		c.m.Ops.WithLabelValues(c.cfg.Layer, "miss").Inc()
	default:
		// Redis arızası. Önbellek YOK sayılır ve DB'ye düşülür (fail-open).
		c.m.Errors.WithLabelValues("get").Inc()
		if !c.failOpen {
			return zero, err
		}
		c.m.Ops.WithLabelValues(c.cfg.Layer, "miss").Inc()
	}

	if c.cfg.NoSingleflight {
		return c.loadAndStore(ctx, k, load)
	}
	c.mu.Lock()
	if f, inflight := c.flights[k]; inflight {
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
	c.flights[k] = f
	c.mu.Unlock()
	f.val, f.err = c.loadAndStore(ctx, k, load)
	close(f.done)
	c.mu.Lock()
	delete(c.flights, k)
	c.mu.Unlock()
	return f.val, f.err
}

func (c *Redis[V]) loadAndStore(ctx context.Context, k string, load func(context.Context) (V, bool, error)) (V, error) {
	var zero V
	v, found, loadErr := load(ctx)
	if loadErr != nil {
		c.m.Errors.WithLabelValues("load").Inc()
		return zero, loadErr
	}
	if !found {
		if !c.cfg.NoNegative {
			if err := c.rdb.Set(ctx, c.key(k), negativeMarker, c.ttl(c.cfg.NegativeTTL)).Err(); err != nil {
				c.m.Errors.WithLabelValues("set").Inc()
			}
		}
		return zero, ErrNegative
	}
	if b, err := json.Marshal(v); err == nil {
		if err := c.rdb.Set(ctx, c.key(k), b, c.ttl(c.cfg.TTL)).Err(); err != nil {
			// SET başarısızlığı SESSİZ kalmamalı: önbellek yazamıyorsa her istek DB'ye iner ve
			// sistem "önbellekli" görünmeye devam eder. P04-06 tam olarak bu durumu üretiyor.
			c.m.Errors.WithLabelValues("set").Inc()
		}
	}
	return v, nil
}

func (c *Redis[V]) Invalidate(ctx context.Context, k string) {
	if err := c.rdb.Del(ctx, c.key(k)).Err(); err != nil {
		c.m.Errors.WithLabelValues("del").Inc()
	} else {
		c.m.Evictions.WithLabelValues("invalidate").Inc()
	}
}

func (c *Redis[V]) Ping(ctx context.Context) error { return c.rdb.Ping(ctx).Err() }
