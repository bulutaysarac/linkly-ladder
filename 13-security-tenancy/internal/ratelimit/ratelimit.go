// Package ratelimit — süreç İÇİ, IP başına token bucket.
//
// EN: Deliberately wrong at scale, and the README says so: with N replicas each pod keeps its own
//
//	bucket, so the effective limit is N × limit and depends on how the load balancer spreads the
//	client. Level 02 measures that error; level 08 fixes it with a shared limiter in Redis.
//
// TR: Ölçekte bilerek YANLIŞ ve README bunu söylüyor: N replikada her pod kendi kovasını tutar,
//
//	yani gerçek limit N × limit olur ve load balancer'ın client'ı nasıl dağıttığına bağlıdır.
//	02 bu hatayı ölçüyor; 08 Redis'teki paylaşılan limiter ile düzeltiyor.
//
// [Topic · Konu: Hız sınırlama, dağıtık durum]
package ratelimit

import (
	"sync"
	"time"
)

type bucket struct {
	tokens float64
	last   time.Time
}

type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	rate    float64 // saniyede token
	burst   float64
	now     func() time.Time
}

func New(ratePerSec float64, burst int) *Limiter {
	return &Limiter{buckets: map[string]*bucket{}, rate: ratePerSec, burst: float64(burst), now: time.Now}
}

func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b, ok := l.buckets[key]
	if !ok {
		// Not: bu map sınırsız büyür — her yeni IP yeni kayıt. Gerçek bir sorun (bellek sızıntısı
		// yüzeyi) ve 08'de paylaşılan limiter'a geçerken TTL ile çözülüyor.
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	elapsed := now.Sub(b.last).Seconds()
	b.last = now
	b.tokens += elapsed * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

func (l *Limiter) Keys() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
