package store

import (
	"context"
	"sort"
	"sync"
	"time"
)

// Fake — testler için bellek içi Store. 01'in gerçek deposunun neredeyse aynısı; buradaki farkı
// görmek öğretici: aynı kod, artık üretim yolu değil yalnızca bir test ikizi.
//
// EN: Why a hand-written fake instead of a real Postgres in unit tests? Because these tests are
//
//	about HTTP behaviour — status codes, tenant boundaries, validation — not about SQL. The SQL
//	is verified separately by postgres_test.go against a real database (skipped without
//	DATABASE_URL). Mixing the two makes every test slow and none of them clear.
//
// TR: Birim testlerde gerçek Postgres yerine neden elle yazılmış bir ikiz? Çünkü bu testler HTTP
//
//	davranışıyla ilgili — durum kodları, kiracı sınırı, doğrulama — SQL ile değil. SQL'i ayrıca
//	postgres_test.go gerçek veritabanına karşı doğruluyor (DATABASE_URL yoksa atlanıyor). İkisini
//	karıştırmak bütün testleri yavaşlatır ve hiçbirini netleştirmez.
//
// [Topic · Konu: Test ikizleri, test piramidi]
type Fake struct {
	mu    sync.RWMutex
	links map[string]*Link
	// FailWith ayarlanırsa her çağrı bu hatayı döndürür — bağımlılık arızası senaryoları için.
	FailWith error
}

func NewFake() *Fake { return &Fake{links: map[string]*Link{}} }

func (f *Fake) CreateUnique(ctx context.Context, l *Link) error {
	if f.FailWith != nil {
		return f.FailWith
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.links[l.Code]; ok {
		return ErrExists
	}
	cp := *l
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now().UTC()
	}
	f.links[l.Code] = &cp
	return nil
}

func (f *Fake) Get(ctx context.Context, code string) (*Link, error) {
	if f.FailWith != nil {
		return nil, f.FailWith
	}
	f.mu.RLock()
	defer f.mu.RUnlock()
	l, ok := f.links[code]
	if !ok {
		return nil, ErrNotFound
	}
	cp := *l
	return &cp, nil
}

func (f *Fake) IncrementClicks(ctx context.Context, code string) error {
	if f.FailWith != nil {
		return f.FailWith
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if l, ok := f.links[code]; ok {
		l.Clicks++
		return nil
	}
	return ErrNotFound
}

func (f *Fake) Delete(ctx context.Context, tenant, code string) error {
	if f.FailWith != nil {
		return f.FailWith
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	l, ok := f.links[code]
	if !ok || l.Tenant != tenant {
		return ErrNotFound // başkasının linki "yok" görünür — varlığını sızdırma
	}
	delete(f.links, code)
	return nil
}

func (f *Fake) ListByTenant(ctx context.Context, tenant string, limit int) ([]Link, error) {
	if f.FailWith != nil {
		return nil, f.FailWith
	}
	f.mu.RLock()
	defer f.mu.RUnlock()
	var out []Link
	for _, l := range f.links {
		if l.Tenant == tenant {
			out = append(out, *l)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (f *Fake) Count(ctx context.Context) (int64, error) {
	if f.FailWith != nil {
		return 0, f.FailWith
	}
	f.mu.RLock()
	defer f.mu.RUnlock()
	return int64(len(f.links)), nil
}

func (f *Fake) Ping(ctx context.Context) error { return f.FailWith }
func (f *Fake) Close()                         {}

var _ Store = (*Fake)(nil)
