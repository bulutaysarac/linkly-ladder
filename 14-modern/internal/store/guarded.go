package store

import (
	"context"
	"errors"

	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/resilience"
)

// Guarded — bir Postgres Store'unu devre kesici + bulkhead + timeout + retry ile saran dekoratör.
//
// EN: The fourth wrapper around the same interface: Cached → ReadWrite → Guarded → Postgres.
//
//	Note what each layer is responsible for and that none of them knows about the others:
//	caching does not know about retries, retries do not know about replicas. That separation
//	is what makes it possible to turn any single layer off and measure what it was buying.
//	The guard sits UNDER the cache, so it sees database calls and nothing else: a cache hit
//	is not a "postgres call" in its latency histogram, it does not reset the breaker's failure
//	count, and an open breaker still lets the cache answer — that is the `cache_only` degrade
//	mode. Where a guard sits decides what it measures.
//
// TR: Aynı arayüzün DÖRDÜNCÜ sarmalaması: Cached → ReadWrite → Guarded → Postgres. Her katmanın
//
//	neyden sorumlu olduğuna ve hiçbirinin diğerini bilmediğine dikkat: önbellek retry'ı bilmez,
//	retry replikayı bilmez. Bu ayrışma sayesinde herhangi bir katmanı kapatıp onun ne satın
//	aldığını ÖLÇEBİLİYORUZ. Guard önbelleğin ALTINDA durur, yani yalnızca veritabanı çağrılarını
//	görür: önbellek isabeti gecikme histogramında bir "postgres çağrısı" değildir, devre
//	kesicinin hata sayacını sıfırlamaz ve açık devre önbelleğin cevap vermesini engellemez —
//	`cache_only` degrade modu budur. Guard'ın NEREDE durduğu, NEYİ ölçtüğünü belirler.
//
// [Topic · Konu: Katmanlı koruma, dekoratör]
type Guarded struct {
	inner Store
	// call — guard + degrade işareti. Devre açıkken veritabanına gidilmez; üstteki Cached
	// katmanı isabetleri cevaplamaya devam eder ("cache_only": okumalar yalnızca önbellekten).
	call func(ctx context.Context, fn func(context.Context) error) error
}

func NewGuarded(inner Store, g *resilience.Guard, onDegrade func(string, bool)) *Guarded {
	return &Guarded{inner: inner, call: GuardCall(g, "cache_only", onDegrade)}
}

// GuardCall — korumalı çağrı + degrade işareti. Postgres ("cache_only") ve Redis ("no_cache")
// AYNI kalıbı kullanır: guard çağrıyı reddettiyse (devre açık / bulkhead dolu) mod 1, çağrı
// başarılıysa 0. Bağımlılığın kendisi hata verdiyse mod değişmez — o bir degrade kararı değil.
//
// EN: degrade is a DECISION the guard makes (stop asking), not an error the dependency returns.
//
//	Marking it only on ErrOpen/ErrBulkhead keeps the gauge honest: "we are deliberately serving
//	without X", not "X had a bad moment".
//
// TR: degrade, bağımlılığın döndürdüğü bir hata değil, guard'ın verdiği bir KARARDIR (sormayı
//
//	bırak). Yalnızca ErrOpen/ErrBulkhead'de işaretlemek göstergeyi dürüst tutar: "X'siz BİLEREK
//	hizmet veriyoruz", "X'in kötü bir anı oldu" değil.
func GuardCall(g *resilience.Guard, mode string, onDegrade func(string, bool)) func(context.Context, func(context.Context) error) error {
	if onDegrade == nil {
		onDegrade = func(string, bool) {}
	}
	return func(ctx context.Context, fn func(context.Context) error) error {
		err := g.Do(ctx, fn)
		switch {
		case errors.Is(err, resilience.ErrOpen), errors.Is(err, resilience.ErrBulkhead):
			onDegrade(mode, true)
		case err == nil:
			onDegrade(mode, false)
		}
		return err
	}
}

func (s *Guarded) CreateUnique(ctx context.Context, l *Link) error {
	return s.call(ctx, func(ctx context.Context) error { return s.inner.CreateUnique(ctx, l) })
}

func (s *Guarded) Get(ctx context.Context, code string) (*Link, error) {
	var out *Link
	err := s.call(ctx, func(ctx context.Context) error {
		l, e := s.inner.Get(ctx, code)
		// ErrNotFound bir ARIZA DEĞİLDİR: devre kesiciyi tetiklememeli. Bunu ayırt etmemek,
		// çok sayıda 404'ün devreyi açmasına ve sağlıklı bir bağımlılığı "bozuk" ilan etmesine
		// yol açar — en sık yapılan devre kesici hatası.
		if errors.Is(e, ErrNotFound) {
			out = nil
			return nil
		}
		out = l
		return e
	})
	if err != nil {
		return nil, err
	}
	if out == nil {
		return nil, ErrNotFound
	}
	return out, nil
}

func (s *Guarded) IncrementClicks(ctx context.Context, code string) error {
	return s.call(ctx, func(ctx context.Context) error { return s.inner.IncrementClicks(ctx, code) })
}

func (s *Guarded) Delete(ctx context.Context, tenant, code string) error {
	return s.call(ctx, func(ctx context.Context) error { return s.inner.Delete(ctx, tenant, code) })
}

func (s *Guarded) ListByTenant(ctx context.Context, tenant string, limit int) ([]Link, error) {
	var out []Link
	err := s.call(ctx, func(ctx context.Context) error {
		l, e := s.inner.ListByTenant(ctx, tenant, limit)
		out = l
		return e
	})
	return out, err
}

func (s *Guarded) Count(ctx context.Context) (int64, error) {
	var n int64
	err := s.call(ctx, func(ctx context.Context) error {
		v, e := s.inner.Count(ctx)
		n = v
		return e
	})
	return n, err
}

func (s *Guarded) WriteClicks(ctx context.Context, counts map[string]int64) error {
	return s.call(ctx, func(ctx context.Context) error { return s.inner.WriteClicks(ctx, counts) })
}

func (s *Guarded) WriteClicksIdempotent(ctx context.Context, counts map[string]int64, ids []string) (int, error) {
	var n int
	err := s.call(ctx, func(ctx context.Context) error {
		v, e := s.inner.WriteClicksIdempotent(ctx, counts, ids)
		n = v
		return e
	})
	return n, err
}

func (s *Guarded) Stats(ctx context.Context, code string, days int) (*Stats, error) {
	var out *Stats
	err := s.call(ctx, func(ctx context.Context) error {
		v, e := s.inner.Stats(ctx, code, days)
		out = v
		return e
	})
	return out, err
}

// Ping — devre kesiciden GEÇMEZ.
// EN: Health checks must see the raw truth. Routing them through the breaker would make a
//
//	tripped breaker report "healthy" (no call made) or keep it open forever (no probe traffic).
//
// TR: Sağlık kontrolleri HAM gerçeği görmeli. Onları devre kesiciden geçirmek, açık bir devrenin
//
//	"sağlıklı" raporlamasına (çağrı yapılmıyor) ya da sonsuza dek açık kalmasına (deneme
//	trafiği yok) yol açardı.
func (s *Guarded) Ping(ctx context.Context) error { return s.inner.Ping(ctx) }
func (s *Guarded) Close()                         { s.inner.Close() }

var _ Store = (*Guarded)(nil)
