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
// EN: The first implementation was per-pod, in memory, and its comment argued that this "covers
//
//	the common case (same client, same connection, same pod)". That argument was true at level
//	05 and FALSE from level 07 on, because the ladder splits the app in two: the create goes to
//	api-svc and the redirect goes to redirect-svc. Two different processes. The marker was
//	written in one and looked up in the other, so `db_sticky_reads_total` measured a steady 0 —
//	the mechanism never fired once, and nobody noticed because a mechanism that never fires
//	looks exactly like a mechanism that is never needed.
//	The lesson is not "use Redis". It is that in-process state silently stops working the day
//	you split a service, and the only thing that would have caught it was a counter nobody read.
//
// TR: İlk gerçekleştirim pod başına, hafızadaydı ve yorumu "yaygın durumu kapsıyor (aynı client,
//
//	aynı bağlantı, aynı pod)" diye savunuyordu. Bu savunma 05'te doğruydu ve 07'den itibaren
//	YANLIŞ, çünkü merdiven uygulamayı ikiye bölüyor: oluşturma api-svc'ye, yönlendirme
//	redirect-svc'ye gidiyor. İki ayrı süreç. İşaret birinde yazılıp diğerinde aranıyordu, yani
//	`db_sticky_reads_total` sabit 0 ölçüyordu — mekanizma bir kez bile çalışmadı ve kimse fark
//	etmedi, çünkü hiç çalışmayan bir mekanizma, hiç gerekmeyen bir mekanizmaya benzer.
//	Ders "Redis kullan" değil. Ders şu: süreç içi durum, bir servisi böldüğün gün SESSİZCE
//	çalışmayı bırakır ve bunu yakalayabilecek tek şey, kimsenin bakmadığı bir sayaçtı.
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
