package store

import (
	"context"
	"errors"

	"github.com/bulutaysarac/linkly-ladder/10-resilience/internal/resilience"
)

// Guarded — Store'u devre kesici + bulkhead + timeout + retry ile saran dekoratör.
//
// EN: The fourth wrapper around the same interface (Postgres → Cached → ReadWrite → Guarded).
//
//	Note what each layer is responsible for and that none of them knows about the others:
//	caching does not know about retries, retries do not know about replicas. That separation
//	is what makes it possible to turn any single layer off and measure what it was buying.
//
// TR: Aynı arayüzün DÖRDÜNCÜ sarmalaması (Postgres → Cached → ReadWrite → Guarded). Her katmanın
//
//	neyden sorumlu olduğuna ve hiçbirinin diğerini bilmediğine dikkat: önbellek retry'ı bilmez,
//	retry replikayı bilmez. Bu ayrışma sayesinde herhangi bir katmanı kapatıp onun ne satın
//	aldığını ÖLÇEBİLİYORUZ.
//
// [Topic · Konu: Katmanlı koruma, dekoratör]
type Guarded struct {
	inner Store
	g     *resilience.Guard
	// degradeToCache: DB tamamen erişilemezken önbellekten okumaya devam et.
	onDegrade func(mode string, active bool)
}

func NewGuarded(inner Store, g *resilience.Guard, onDegrade func(string, bool)) *Guarded {
	if onDegrade == nil {
		onDegrade = func(string, bool) {}
	}
	return &Guarded{inner: inner, g: g, onDegrade: onDegrade}
}

func (s *Guarded) call(ctx context.Context, fn func(context.Context) error) error {
	err := s.g.Do(ctx, fn)
	switch {
	case errors.Is(err, resilience.ErrOpen), errors.Is(err, resilience.ErrBulkhead):
		s.onDegrade("cache_only", true)
	case err == nil:
		s.onDegrade("cache_only", false)
	}
	return err
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
