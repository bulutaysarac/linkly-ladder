package store

import (
	"sync"
	"time"
)

// recentWrites — "bu kodu az önce ben mi yazdım?" sorusunun ucuz cevabı.
//
// EN: Deliberately per-pod and deliberately small. A shared version (Redis) would be more correct
//
//	— another pod's write would also stick — but it would put a network hop on every read to
//	solve a problem that lasts a few hundred milliseconds. The honest framing: this covers the
//	common case (same client, same connection, same pod) and the README says which case it does
//	not cover.
//
// TR: Bilerek pod başına ve bilerek küçük. Paylaşılan bir sürüm (Redis) daha doğru olurdu —
//
//	başka bir pod'un yazması da yapışırdı — ama birkaç yüz milisaniye süren bir sorunu çözmek
//	için HER okumaya bir ağ adımı eklerdi. Dürüst çerçeve: bu, yaygın durumu kapsıyor (aynı
//	client, aynı bağlantı, aynı pod) ve README hangi durumu KAPSAMADIĞINI söylüyor.
//
// [Topic · Konu: Read-your-writes, yapışkan okuma]
type recentWrites struct {
	mu sync.RWMutex
	at map[string]time.Time
}

func newRecentWrites() *recentWrites {
	r := &recentWrites{at: map[string]time.Time{}}
	go r.gc()
	return r
}

func (r *recentWrites) mark(code string) {
	r.mu.Lock()
	r.at[code] = time.Now()
	r.mu.Unlock()
}

func (r *recentWrites) wroteRecently(code string, window time.Duration) bool {
	r.mu.RLock()
	t, ok := r.at[code]
	r.mu.RUnlock()
	return ok && time.Since(t) < window
}

// gc — pencere dolmuş kayıtları temizle. Bu map sınırsız büyümemeli (P00-08'in dersi).
func (r *recentWrites) gc() {
	tick := time.NewTicker(30 * time.Second)
	for range tick.C {
		cutoff := time.Now().Add(-2 * time.Minute)
		r.mu.Lock()
		for k, v := range r.at {
			if v.Before(cutoff) {
				delete(r.at, k)
			}
		}
		r.mu.Unlock()
	}
}
