package store

import (
	"sync"
	"testing"
	"time"
)

func TestCreateUniqueDoesNotOverwrite(t *testing.T) {
	s := NewMemory()
	if err := s.CreateUnique(&Link{Code: "abc", URL: "https://first", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateUnique(&Link{Code: "abc", URL: "https://second"}); err != ErrExists {
		t.Fatalf("ErrExists bekleniyordu, %v geldi", err)
	}
	l, _ := s.Get("abc")
	if l.URL != "https://first" {
		t.Fatalf("ilk kayıt ezilmiş: %s — 00'daki sessiz üzerine yazma geri gelmiş", l.URL)
	}
}

// 00'ı çökerten senaryo: aynı map'e paralel yazım. -race ile koş.
func TestConcurrentWritesDoNotCrash(t *testing.T) {
	s := NewMemory()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				_ = s.CreateUnique(&Link{Code: string(rune('a'+i%26)) + string(rune('a'+j%26)), URL: "https://e"})
				s.IncrementClicks("aa")
				s.Get("aa")
			}
		}(i)
	}
	wg.Wait()
	if s.Len() == 0 {
		t.Fatal("hiç kayıt yazılmadı")
	}
}

func TestGetReturnsCopy(t *testing.T) {
	s := NewMemory()
	_ = s.CreateUnique(&Link{Code: "x", URL: "https://e"})
	l, _ := s.Get("x")
	l.URL = "https://mutated"
	again, _ := s.Get("x")
	if again.URL != "https://e" {
		t.Fatal("Get içerideki kaydın işaretçisini sızdırıyor: çağıran store'u dışarıdan değiştirebiliyor")
	}
}
