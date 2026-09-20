package ratelimit

import (
	"testing"
	"time"
)

func TestBurstThenRefill(t *testing.T) {
	now := time.Now()
	l := New(10, 5)
	l.now = func() time.Time { return now }

	for i := 0; i < 5; i++ {
		if !l.Allow("ip1") {
			t.Fatalf("burst içindeki %d. istek reddedildi", i+1)
		}
	}
	if l.Allow("ip1") {
		t.Fatal("burst bittikten sonra izin verildi")
	}
	now = now.Add(500 * time.Millisecond) // 10/s × 0.5s = 5 token
	if !l.Allow("ip1") {
		t.Fatal("yenilenmeden sonra reddedildi")
	}
}

func TestKeysAreIndependent(t *testing.T) {
	now := time.Now()
	l := New(1, 1)
	l.now = func() time.Time { return now }
	if !l.Allow("a") || !l.Allow("b") {
		t.Fatal("farklı anahtarlar birbirini etkiliyor")
	}
	if l.Allow("a") {
		t.Fatal("aynı anahtar ikinci kez geçti")
	}
}
