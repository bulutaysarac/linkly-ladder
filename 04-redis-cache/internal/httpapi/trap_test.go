package httpapi

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/bulutaysarac/linkly-ladder/04-redis-cache/internal/config"
	"github.com/bulutaysarac/linkly-ladder/04-redis-cache/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/04-redis-cache/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/04-redis-cache/internal/store"
)

func handlerWith(t *testing.T, mut func(*config.Config), rate float64, burst int) http.Handler {
	t.Helper()
	cfg := config.Load()
	mut(&cfg)
	api := New(cfg, slog.New(slog.NewJSONHandler(io.Discard, nil)), metrics.New(cfg.TrapMetricLabelCode), store.NewFake(), "test")
	api.SetReady(true)
	return api.Handler(ratelimit.New(rate, burst))
}

// Doğru davranış: sağlık ucu hız sınırının DIŞINDA — trafik dalgası probe'u düşürmemeli.
func TestHealthzNotRateLimitedByDefault(t *testing.T) {
	h := handlerWith(t, func(c *config.Config) {}, 1, 1)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/abcdefg", nil)) // kovayı tüket
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/abcdefg", nil))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/healthz", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("healthz hız sınırına takıldı (%d) — bir trafik dalgası pod'u öldürürdü", w.Code)
	}
}

// TRAP açıkken: sağlık ucu iş zincirine giriyor ve 429 yiyebiliyor (P01-07).
func TestTrapLivenessStrictPutsHealthBehindRateLimit(t *testing.T) {
	h := handlerWith(t, func(c *config.Config) { c.TrapLivenessStrict = true }, 1, 1)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/abcdefg", nil))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/abcdefg", nil))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/healthz", nil))
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("TRAP açıkken healthz'in 429 alması bekleniyordu, %d geldi", w.Code)
	}
}

// TRAP_METRIC_LABEL_CODE: her kısa kod yeni zaman serisi (P01-06).
func TestTrapMetricLabelCodeAddsSeriesPerCode(t *testing.T) {
	h := handlerWith(t, func(c *config.Config) { c.TrapMetricLabelCode = true }, 100000, 100000)
	for _, code := range []string{"aaaaaaa", "bbbbbbb", "ccccccc"} {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/"+code, nil))
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/metrics", nil))
	body := w.Body.String()
	for _, code := range []string{"aaaaaaa", "bbbbbbb", "ccccccc"} {
		if !contains(body, `short_code="`+code+`"`) {
			t.Fatalf("TRAP açıkken %s için ayrı seri bekleniyordu", code)
		}
	}
}

func contains(h, n string) bool { return len(h) >= len(n) && (func() bool { return indexOf(h, n) >= 0 })() }
func indexOf(h, n string) int {
	for i := 0; i+len(n) <= len(h); i++ {
		if h[i:i+len(n)] == n {
			return i
		}
	}
	return -1
}
