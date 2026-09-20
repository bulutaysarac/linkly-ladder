package auth

import (
	"errors"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

func newStore(t *testing.T) *Store {
	t.Helper()
	return NewStore(NewMetrics(prometheus.NewRegistry()))
}

func TestVerifyAcceptsKnownKeyAndRejectsOthers(t *testing.T) {
	s := newStore(t)
	s.Add("secret-acme", Identity{Tenant: "acme", Tier: "pro"})
	id, err := s.Verify("secret-acme")
	if err != nil || id.Tenant != "acme" || id.Tier != "pro" {
		t.Fatalf("geçerli anahtar kabul edilmedi: %+v %v", id, err)
	}
	if _, err := s.Verify("secret-wrong"); !errors.Is(err, ErrInvalidKey) {
		t.Fatalf("geçersiz anahtar kabul edildi: %v", err)
	}
	if _, err := s.Verify(""); !errors.Is(err, ErrNoCredentials) {
		t.Fatalf("boş anahtar için ErrNoCredentials bekleniyordu: %v", err)
	}
}

// Anahtarlar HASH'lenmiş saklanmalı: sızan bir depo çalışan kimlik bilgisi vermemeli.
func TestKeysAreStoredHashedNotPlaintext(t *testing.T) {
	s := newStore(t)
	s.Add("super-secret-value", Identity{Tenant: "t1"})
	s.mu.RLock()
	defer s.mu.RUnlock()
	for stored := range s.keys {
		if stored == "super-secret-value" {
			t.Fatal("anahtar DÜZ METİN saklanmış — sızan depo doğrudan kullanılabilir olurdu")
		}
		if len(stored) != 64 {
			t.Fatalf("sha256 hex bekleniyordu, uzunluk %d", len(stored))
		}
	}
}

func TestLoadFromSpecParsesTenantTierKey(t *testing.T) {
	s := newStore(t)
	n := s.LoadFromSpec("acme:pro:key-a, globex:free:key-b, bozuk-satir")
	if n != 2 {
		t.Fatalf("2 anahtar bekleniyordu, %d yüklendi", n)
	}
	if id, err := s.Verify("key-b"); err != nil || id.Tenant != "globex" || id.Tier != "free" {
		t.Fatalf("beklenmeyen kimlik: %+v %v", id, err)
	}
}

func TestBearerTokenExtraction(t *testing.T) {
	cases := map[string]string{
		"Bearer abc123": "abc123",
		"bearer abc123": "abc123",
		"abc123":        "",
		"Bearer ":       "",
		"":              "",
	}
	for in, want := range cases {
		if got := BearerToken(in); got != want {
			t.Errorf("BearerToken(%q) = %q, beklenen %q", in, got, want)
		}
	}
}
