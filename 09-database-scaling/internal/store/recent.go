package store

import (
	"context"
	"strconv"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

// RecentWrites — "bu kodu az önce YAZDIM mı?" sorusunun cevabı. Yapışkan okumanın (sticky read)
// tek girdisi budur: cevap evetse okuma replikaya değil primary'ye gider.
//
// EN: A per-pod, in-memory marker covers "the common case (same client, same connection, same
//
//	pod)". That holds for a single service and is FALSE here, because from level 07 on the
//	ladder splits the app in two: the create goes to api-svc and the redirect goes to
//	redirect-svc. Two different processes. A marker written in one and looked up in the other
//	never matches, so `db_sticky_reads_total` would sit at a steady 0 — and nobody would notice,
//	because a mechanism that never fires looks exactly like a mechanism that is never needed.
//	That is why the marker lives in Redis, shared by both services. The lesson is not "use
//	Redis": in-process state silently stops working the day you split a service, and the only
//	thing that catches it is a counter someone actually reads.
//
// TR: Pod başına, hafızada tutulan bir işaret "yaygın durumu (aynı client, aynı bağlantı, aynı
//
//	pod)" kapsar. Bu tek servisli bir dünyada doğrudur, burada YANLIŞTIR, çünkü merdiven 07'den
//	itibaren uygulamayı ikiye böler: oluşturma api-svc'ye, yönlendirme redirect-svc'ye gider.
//	İki ayrı süreç. Birinde yazılıp diğerinde aranan işaret hiç eşleşmez; `db_sticky_reads_total`
//	sabit 0 kalır ve kimse fark etmez, çünkü hiç çalışmayan bir mekanizma, hiç gerekmeyen bir
//	mekanizmaya benzer.
//	İşaretin iki servisin paylaştığı Redis'te durmasının nedeni bu. Ders "Redis kullan" değil:
//	süreç içi durum, bir servisi böldüğün gün SESSİZCE çalışmayı bırakır ve bunu yakalayan tek
//	şey, birinin gerçekten baktığı bir sayaçtır.
//
// [Topic · Konu: Read-your-writes, yapışkan okuma, süreç içi durumun sınırı]
type RecentWrites interface {
	Mark(code string)
	WroteRecently(code string, window time.Duration) bool
}

// localRecent — süreç içi. Tek replikalı, tek servisli bir dünyada doğrudur; burada yalnızca
// Redis yokken devreye girer (ve o durumda yapışkan okuma servisler arası ÇALIŞMAZ).
type localRecent struct {
	mu sync.RWMutex
	at map[string]time.Time
}

func NewLocalRecent() RecentWrites {
	r := &localRecent{at: map[string]time.Time{}}
	go r.gc()
	return r
}

func (r *localRecent) Mark(code string) {
	r.mu.Lock()
	r.at[code] = time.Now()
	r.mu.Unlock()
}

func (r *localRecent) WroteRecently(code string, window time.Duration) bool {
	r.mu.RLock()
	t, ok := r.at[code]
	r.mu.RUnlock()
	return ok && time.Since(t) < window
}

// gc — pencere dolmuş kayıtları temizle. Bu map sınırsız büyümemeli (P00-08'in dersi).
func (r *localRecent) gc() {
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

// sharedRecent — işaret Redis'te. Maliyeti dürüstçe söylemek gerekir: önbellek ISKALAYAN her
// okumaya bir ağ adımı ekler (önbellek isabetinde okuma zaten DB'ye inmez, bu kod çalışmaz).
// Karşılığında yapışkan okuma servisler arası ÇALIŞIR — ki tek varlık sebebi buydu.
type sharedRecent struct {
	rdb    *redis.Client
	prefix string
	ttl    time.Duration
}

// NewSharedRecent — ttl, işaretin Redis'te ne kadar yaşayacağı. Yapışkan pencereden BÜYÜK
// tutulur: ihlal tespiti (P09-01) pencere kapandıktan sonra da doğru cevap verebilsin diye.
func NewSharedRecent(rdb *redis.Client, prefix string, ttl time.Duration) RecentWrites {
	return &sharedRecent{rdb: rdb, prefix: prefix, ttl: ttl}
}

func (s *sharedRecent) Mark(code string) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	// Hata yutuluyor: işaret yazılamazsa okuma replikaya gider ve kullanıcı eski veri görebilir.
	// Yazma yolunu Redis'in hatasıyla BAŞARISIZ yapmak, tazelikten daha pahalı bir seçimdir.
	s.rdb.Set(ctx, s.prefix+code, strconv.FormatInt(time.Now().UnixNano(), 10), s.ttl)
}

func (s *sharedRecent) WroteRecently(code string, window time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	v, err := s.rdb.Get(ctx, s.prefix+code).Result()
	if err != nil {
		return false // fail-open: Redis yoksa okuma replikadan yapılır
	}
	ns, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return false
	}
	return time.Since(time.Unix(0, ns)) < window
}
