// Package store — link deposu. 01'de bellek içi bir map'ti; artık Postgres.
//
// EN: The interface barely changed, and that is the point: CreateUnique's conditional-insert
//
//	semantics were chosen at level 01 precisely because they map 1:1 onto SQL's UNIQUE constraint
//	(ON CONFLICT DO NOTHING). Picking the narrow, honest interface early is what makes the swap
//	a one-file change instead of a rewrite.
//
// TR: Arayüz neredeyse hiç değişmedi ve mesele tam olarak bu: CreateUnique'in koşullu ekleme
//
//	semantiği 01'de tesadüfen değil, SQL'in UNIQUE kısıtına (ON CONFLICT DO NOTHING) birebir
//	otursun diye seçilmişti. Dar ve dürüst arayüzü erken seçmek, değişimi baştan yazmak yerine
//	tek dosyalık bir işe çeviriyor.
//
// [Topic · Konu: Arayüz tasarımı, kalıcılık]
package store

import (
	"context"
	"errors"
	"time"
)

var (
	ErrExists   = errors.New("kod zaten var")
	ErrNotFound = errors.New("kayıt yok")
)

type Link struct {
	Code      string    `json:"code"`
	URL       string    `json:"url"`
	Tenant    string    `json:"tenant"`
	Clicks    int64     `json:"clicks"`
	CreatedAt time.Time `json:"created_at"`
}

type DailyCount struct {
	Day   string `json:"day"`
	Count int64  `json:"count"`
}

type Stats struct {
	Code   string       `json:"code"`
	Clicks int64        `json:"clicks"`
	ByDay  []DailyCount `json:"by_day"`
}

type Store interface {
	CreateUnique(ctx context.Context, l *Link) error
	Get(ctx context.Context, code string) (*Link, error)
	IncrementClicks(ctx context.Context, code string) error
	Delete(ctx context.Context, tenant, code string) error
	ListByTenant(ctx context.Context, tenant string, limit int) ([]Link, error)
	Count(ctx context.Context) (int64, error)
	// WriteClicks — toplu, idempotent OLMAYAN artırma. Toplayıcı çağırır, istek yolu ASLA.
	WriteClicks(ctx context.Context, counts map[string]int64) error
	Stats(ctx context.Context, code string, days int) (*Stats, error)
	Ping(ctx context.Context) error
	Close()
}
