// Package store — bellek içi link deposu.
//
// EN: Level 00 crashed under load because a plain map was written from many goroutines. The fix
//
//	here is an RWMutex — enough to stop the crash, but NOT the real answer: the data still lives
//	inside one process, so it dies with the process (P01-01) and cannot be shared with a second
//	replica (P01-02). Level 02 moves it out.
//
// TR: Seviye 00, düz map'e birçok goroutine'den yazıldığı için yük altında çöküyordu. Buradaki
//
//	düzeltme bir RWMutex — çökmeyi durdurmaya YETER ama gerçek cevap DEĞİL: veri hâlâ tek sürecin
//	içinde, yani süreçle birlikte ölüyor (P01-01) ve ikinci bir replika ile paylaşılamıyor (P01-02).
//	02 onu dışarı taşıyor.
//
// [Topic · Konu: Eşzamanlılık, durum yönetimi]
package store

import (
	"errors"
	"sync"
	"time"
)

var ErrExists = errors.New("kod zaten var")

type Link struct {
	Code      string    `json:"code"`
	URL       string    `json:"url"`
	Clicks    int64     `json:"clicks"`
	CreatedAt time.Time `json:"created_at"`
}

type Memory struct {
	mu    sync.RWMutex
	links map[string]*Link
}

func NewMemory() *Memory { return &Memory{links: make(map[string]*Link)} }

// CreateUnique — kod zaten varsa ErrExists döner, ASLA üzerine yazmaz.
// EN: The conditional insert is the point. Its semantics map 1:1 onto SQL's UNIQUE constraint and
//
//	DynamoDB's attribute_not_exists, so level 02 swaps the implementation without changing callers.
//
// TR: Koşullu ekleme asıl mesele. Semantiği SQL'in UNIQUE kısıtı ve DynamoDB'nin
//
//	attribute_not_exists'i ile birebir örtüşür; 02 çağıranı değiştirmeden gerçekleştirimi değiştirir.
func (m *Memory) CreateUnique(l *Link) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, exists := m.links[l.Code]; exists {
		return ErrExists
	}
	cp := *l
	m.links[l.Code] = &cp
	return nil
}

func (m *Memory) Get(code string) (*Link, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	l, ok := m.links[code]
	if !ok {
		return nil, false
	}
	cp := *l
	return &cp, true
}

func (m *Memory) IncrementClicks(code string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if l, ok := m.links[code]; ok {
		l.Clicks++
	}
}

func (m *Memory) Delete(code string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.links, code)
}

func (m *Memory) Len() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.links)
}
