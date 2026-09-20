package resilience

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

func newGuard(t *testing.T, cfg Config) *Guard {
	t.Helper()
	if cfg.Name == "" {
		cfg.Name = "postgres"
	}
	if cfg.Timeout == 0 {
		cfg.Timeout = 200 * time.Millisecond
	}
	return NewGuard(cfg, NewMetrics(prometheus.NewRegistry()))
}

var errBoom = errors.New("boom")

func TestBreakerOpensAfterThreshold(t *testing.T) {
	g := newGuard(t, Config{FailureThreshold: 3, OpenDuration: time.Hour})
	for i := 0; i < 3; i++ {
		_ = g.Do(context.Background(), func(context.Context) error { return errBoom })
	}
	if g.State() != Open {
		t.Fatalf("3 hatadan sonra devre açılmalıydı, durum: %v", g.State())
	}
	// Açıkken çağrı YAPILMAMALI: bağımlılığı da kendini de beklemekten koru.
	called := false
	err := g.Do(context.Background(), func(context.Context) error { called = true; return nil })
	if called {
		t.Fatal("devre açıkken bağımlılığa çağrı yapıldı")
	}
	if !errors.Is(err, ErrOpen) {
		t.Fatalf("ErrOpen bekleniyordu, %v", err)
	}
}

func TestBreakerHalfOpenRecovers(t *testing.T) {
	g := newGuard(t, Config{FailureThreshold: 2, OpenDuration: 50 * time.Millisecond, HalfOpenProbes: 1})
	for i := 0; i < 2; i++ {
		_ = g.Do(context.Background(), func(context.Context) error { return errBoom })
	}
	time.Sleep(80 * time.Millisecond)
	if err := g.Do(context.Background(), func(context.Context) error { return nil }); err != nil {
		t.Fatalf("yarı açıkken başarılı deneme geçmeliydi: %v", err)
	}
	if g.State() != Closed {
		t.Fatalf("başarılı denemeden sonra devre kapanmalıydı, durum: %v", g.State())
	}
}

func TestBulkheadLimitsConcurrency(t *testing.T) {
	g := newGuard(t, Config{MaxConcurrent: 2, FailureThreshold: 100, Timeout: time.Second})
	release := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = g.Do(context.Background(), func(context.Context) error { <-release; return nil })
		}()
	}
	time.Sleep(50 * time.Millisecond)
	err := g.Do(context.Background(), func(context.Context) error { return nil })
	if !errors.Is(err, ErrBulkhead) {
		t.Fatalf("bulkhead dolu olmalıydı, %v", err)
	}
	close(release)
	wg.Wait()
}

// Retry bütçesi: hata oranı yüksekken retry'lar trafiği KATLAMAMALI.
func TestRetryBudgetCapsAmplification(t *testing.T) {
	g := newGuard(t, Config{MaxRetries: 3, RetryBudget: 0.1, FailureThreshold: 1000,
		Timeout: 20 * time.Millisecond})
	var calls int
	var mu sync.Mutex
	for i := 0; i < 200; i++ {
		_ = g.Do(context.Background(), func(context.Context) error {
			mu.Lock()
			calls++
			mu.Unlock()
			return errBoom
		})
	}
	mu.Lock()
	total := calls
	mu.Unlock()
	// Bütçesiz olsaydı 200 × 4 = 800 çağrı olurdu. Bütçe ile ~200 + %10 civarı beklenir.
	if total > 400 {
		t.Fatalf("retry bütçesi çalışmıyor: 200 istek %d çağrıya dönüştü (bütçesiz 800 olurdu)", total)
	}
}

func TestTimeoutIsEnforcedPerAttempt(t *testing.T) {
	g := newGuard(t, Config{Timeout: 50 * time.Millisecond, FailureThreshold: 100})
	start := time.Now()
	err := g.Do(context.Background(), func(ctx context.Context) error {
		<-ctx.Done()
		return ctx.Err()
	})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("deadline bekleniyordu, %v", err)
	}
	if time.Since(start) > 500*time.Millisecond {
		t.Fatal("timeout uygulanmadı")
	}
}

func TestShedderRejectsAboveLimitButNeverHealth(t *testing.T) {
	m := NewMetrics(prometheus.NewRegistry())
	s := NewShedder(1, true, m)
	block := make(chan struct{})
	// Yalnızca iş yolundaki istekler bloklansın; sağlık ucu serbest kalsın, yoksa test kendi
	// kendini kilitler (ilk yazımda tam olarak bu oldu).
	h := s.Middleware(blockingExcept(block, "/healthz", "/readyz", "/metrics"))

	go func() { h.ServeHTTP(newRecorder(), newRequest("/abc")) }()
	time.Sleep(30 * time.Millisecond)

	rec := newRecorder()
	h.ServeHTTP(rec, newRequest("/def"))
	if rec.Code != 503 {
		t.Fatalf("limit üstü istek 503 almalıydı, %d", rec.Code)
	}
	// Sağlık ucu ASLA atılmamalı: yük altında probe düşerse pod öldürülür.
	hrec := newRecorder()
	h.ServeHTTP(hrec, newRequest("/healthz"))
	if hrec.Code == 503 {
		t.Fatal("sağlık ucu yük atmaya takıldı — yük artışı kesintiye dönüşür (P01-07)")
	}
	close(block)
}
