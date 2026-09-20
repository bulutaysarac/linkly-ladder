// Package auth — API anahtarı doğrulama ve kiracı çözümleme.
//
// EN: Twelve levels used `X-Tenant-ID` and every README said the same thing in capitals: THIS IS
//
//	NOT AUTHENTICATION. Here it finally becomes one. The change is small in code and total in
//	meaning: before, the tenant was something the CLIENT claimed; now it is something the
//	SERVER derives from a secret only the real tenant holds.
//
// TR: On iki seviye boyunca `X-Tenant-ID` kullandık ve her README aynı şeyi büyük harflerle
//
//	söyledi: BU KİMLİK DOĞRULAMA DEĞİLDİR. Burada nihayet oluyor. Değişiklik kodda küçük,
//	anlamda mutlak: önce kiracı, CLIENT'ın İDDİA ETTİĞİ bir şeydi; şimdi SUNUCUNUN, yalnızca
//	gerçek kiracının sahip olduğu bir sırdan TÜRETTİĞİ bir şey.
//
// [Topic · Konu: Kimlik doğrulama, kiracı sınırı]
package auth

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

var (
	ErrNoCredentials = errors.New("kimlik bilgisi yok")
	ErrInvalidKey    = errors.New("geçersiz API anahtarı")
)

type Identity struct {
	Tenant string
	KeyID  string
	Tier   string // free | pro | enterprise — 08'deki sabit kotanın yerine geçer
}

type Metrics struct {
	Attempts *prometheus.CounterVec // result
	Latency  prometheus.Histogram
}

func NewMetrics(reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		Attempts: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "auth_attempts_total", Help: "Kimlik doğrulama denemesi"}, []string{"result"}),
		Latency: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "auth_duration_seconds", Help: "Doğrulama süresi",
			Buckets: []float64{.0001, .0005, .001, .005, .01, .05}}),
	}
	reg.MustRegister(m.Attempts, m.Latency)
	for _, r := range []string{"ok", "missing", "invalid"} {
		m.Attempts.WithLabelValues(r)
	}
	return m
}

// Store — anahtar hash'i → kimlik.
//
// EN: Keys are stored HASHED, never in plaintext. Two reasons and both matter: a leaked database
//
//	does not hand over working credentials, and nobody — including an operator reading a
//	backup — can use a key they merely saw. The comparison is constant-time: a timing side
//	channel on a 32-byte secret is small but free to close.
//
// TR: Anahtarlar HASH'lenmiş saklanır, asla düz metin. İki sebep ve ikisi de önemli: sızan bir
//
//	veritabanı çalışan kimlik bilgisi teslim etmez ve hiç kimse — bir yedeği okuyan operatör
//	dahil — yalnızca GÖRDÜĞÜ bir anahtarı kullanamaz. Karşılaştırma sabit zamanlı: 32 baytlık
//	bir sırda zamanlama yan kanalı küçüktür ama kapatması bedavadır.
type Store struct {
	mu   sync.RWMutex
	keys map[string]Identity // sha256(key) → identity
	m    *Metrics
}

func NewStore(m *Metrics) *Store { return &Store{keys: map[string]Identity{}, m: m} }

func Hash(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

func (s *Store) Add(rawKey string, id Identity) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keys[Hash(rawKey)] = id
}

// LoadFromSpec — "tenant:tier:key,tenant:tier:key" biçiminde bir ortam değişkeninden yükle.
// Üretimde bu bir veritabanı ya da bir sır yöneticisi olurdu; burada dersin konusu anahtarın
// NEREDE saklandığı değil, NASIL doğrulandığı.
func (s *Store) LoadFromSpec(spec string) int {
	n := 0
	for _, entry := range strings.Split(spec, ",") {
		parts := strings.SplitN(strings.TrimSpace(entry), ":", 3)
		if len(parts) != 3 || parts[2] == "" {
			continue
		}
		s.Add(parts[2], Identity{Tenant: parts[0], Tier: parts[1], KeyID: Hash(parts[2])[:8]})
		n++
	}
	return n
}

func (s *Store) Verify(rawKey string) (Identity, error) {
	start := time.Now()
	defer func() { s.m.Latency.Observe(time.Since(start).Seconds()) }()
	if rawKey == "" {
		s.m.Attempts.WithLabelValues("missing").Inc()
		return Identity{}, ErrNoCredentials
	}
	want := Hash(rawKey)
	s.mu.RLock()
	defer s.mu.RUnlock()
	for h, id := range s.keys {
		if subtle.ConstantTimeCompare([]byte(h), []byte(want)) == 1 {
			s.m.Attempts.WithLabelValues("ok").Inc()
			return id, nil
		}
	}
	s.m.Attempts.WithLabelValues("invalid").Inc()
	return Identity{}, ErrInvalidKey
}

type ctxKey struct{}

func WithIdentity(ctx context.Context, id Identity) context.Context {
	return context.WithValue(ctx, ctxKey{}, id)
}

func FromContext(ctx context.Context) (Identity, bool) {
	id, ok := ctx.Value(ctxKey{}).(Identity)
	return id, ok
}

// BearerToken — Authorization header'ından token çıkar.
func BearerToken(header string) string {
	const p = "Bearer "
	if len(header) > len(p) && strings.EqualFold(header[:len(p)], p) {
		return header[len(p):]
	}
	return ""
}
