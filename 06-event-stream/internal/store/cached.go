package store

import (
	"context"
	"errors"

	"github.com/bulutaysarac/linkly-ladder/06-event-stream/internal/cache"
)

// Cached — Store'u cache-aside ile saran dekoratör. 03'te L1 (pod içi), 04'te L2 (Redis).
// Dekoratörün kendisi neredeyse hiç değişmedi: değişen yalnızca önbelleğin NEREDE durduğu.
//
// EN: A decorator, not a new store: handlers keep talking to the same interface and cannot tell the
//     difference. That is what makes the caching decision reversible — and reversibility matters,
//     because caching is the one change most likely to be WRONG in a way that only shows up in
//     production (stale reads, split brain between replicas, invalidation you forgot).
// TR: Yeni bir store değil, bir dekoratör: handler'lar aynı arayüzle konuşmaya devam ediyor ve farkı
//     anlayamıyorlar. Önbellek kararını GERİ ALINABİLİR kılan şey bu — ve geri alınabilirlik önemli,
//     çünkü önbellek, yalnızca üretimde ortaya çıkan biçimlerde yanlış olma ihtimali en yüksek
//     değişikliktir (bayat okuma, replikalar arası ayrışma, unutulan geçersiz kılma).
// [Topic · Konu: Cache-aside, dekoratör]
type Cached struct {
	inner Store
	links *cache.Redis[Link]
	// Artık geçersiz kılma PAYLAŞILAN önbellekte oluyor: bir pod siler, herkes görür (P03-01 çözüldü).
}

func NewCached(inner Store, c *cache.Redis[Link]) *Cached {
	return &Cached{inner: inner, links: c}
}

func (c *Cached) CreateUnique(ctx context.Context, l *Link) error {
	if err := c.inner.CreateUnique(ctx, l); err != nil {
		return err
	}
	// Yeni kaydı önbelleğe YAZMIYORUZ (write-through değil).
	// EN: A freshly created link is usually not read immediately, and writing it here would hide a
	//     real problem behind a lucky local hit: at level 09 the read may land on a replica that has
	//     not received the row yet (read-your-writes, P09-01). Keep the read path honest.
	// TR: Yeni oluşturulan link genelde hemen okunmaz ve burada yazmak, gerçek bir sorunu şanslı bir
	//     yerel isabetin arkasına saklardı: 09'da okuma, satırı henüz almamış bir replikaya düşebilir
	//     (read-your-writes, P09-01). Okuma yolunu dürüst tut.
	c.links.Invalidate(ctx, l.Code) // negatif kayıt varsa temizle — artık TÜM pod'lar için
	return nil
}

func (c *Cached) Get(ctx context.Context, code string) (*Link, error) {
	l, err := c.links.GetOrLoad(ctx, code, func(ctx context.Context) (Link, bool, error) {
		got, err := c.inner.Get(ctx, code)
		if errors.Is(err, ErrNotFound) {
			return Link{}, false, nil // "yok" bir hata değil, negatif olarak önbelleklenecek bir CEVAP
		}
		if err != nil {
			return Link{}, false, err
		}
		return *got, true, nil
	})
	if errors.Is(err, cache.ErrNegative) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	cp := l
	return &cp, nil
}

// IncrementClicks — önbelleğe DOKUNMUYOR.
// EN: The cached copy carries a click count that is already stale by design. Invalidating on every
//     click would turn the cache into a cache-miss generator on exactly the hottest keys — the
//     opposite of what it is for. The honest statement is: redirect targets are cached, click counts
//     are not authoritative in the cache. Say it out loud rather than pretending consistency.
// TR: Önbellekteki kopya, tasarım gereği zaten bayat bir tıklama sayısı taşıyor. Her tıklamada
//     geçersiz kılmak, önbelleği tam da en sıcak anahtarlarda bir ıska üreticisine çevirirdi —
//     varlık amacının tam tersi. Dürüst ifade şu: yönlendirme hedefi önbelleklidir, tıklama sayısı
//     önbellekte yetkili değildir. Tutarlılık numarası yapmak yerine bunu açıkça söyle.
func (c *Cached) IncrementClicks(ctx context.Context, code string) error {
	return c.inner.IncrementClicks(ctx, code)
}

func (c *Cached) Delete(ctx context.Context, tenant, code string) error {
	if err := c.inner.Delete(ctx, tenant, code); err != nil {
		return err
	}
	c.links.Invalidate(ctx, code) // paylaşılan önbellekten siler → hiçbir pod bayat kopya tutmuyor
	return nil
}

func (c *Cached) ListByTenant(ctx context.Context, tenant string, limit int) ([]Link, error) {
	// Liste önbelleklenmiyor: sonucu her yazmada değişir ve geçersiz kılması pahalıdır.
	// Neyin önbelleklenmeyeceğine karar vermek, neyin önbellekleneceğine karar vermek kadar önemlidir.
	return c.inner.ListByTenant(ctx, tenant, limit)
}

func (c *Cached) Count(ctx context.Context) (int64, error) { return c.inner.Count(ctx) }

func (c *Cached) WriteClicksIdempotent(ctx context.Context, counts map[string]int64, ids []string) (int, error) {
	return c.inner.WriteClicksIdempotent(ctx, counts, ids)
}

func (c *Cached) WriteClicks(ctx context.Context, counts map[string]int64) error {
	return c.inner.WriteClicks(ctx, counts)
}

// Stats önbelleklenmiyor: sürekli değişen bir toplam ve okunma sıklığı düşük.
func (c *Cached) Stats(ctx context.Context, code string, days int) (*Stats, error) {
	return c.inner.Stats(ctx, code, days)
}
func (c *Cached) Ping(ctx context.Context) error           { return c.inner.Ping(ctx) }
func (c *Cached) Close()                                   { c.inner.Close() }

var _ Store = (*Cached)(nil)
