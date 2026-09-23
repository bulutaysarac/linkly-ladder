package httpapi

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"

	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/config"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/store"
)

// Muafiyet YALNIZCA doğru jetonla geçer. Redis'e ulaşılamayan, fail-closed bir limiter kuruyoruz:
// orada HER istek reddedilir, yani 429 almayan tek istek limiter'ı hiç görmemiş olandır.
func TestLoadTestTokenBypassesLimiterOnlyWithTheRightToken(t *testing.T) {
	rdb := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1", DialTimeout: 50 * time.Millisecond, MaxRetries: -1})
	t.Cleanup(func() { _ = rdb.Close() })
	build := func(token string) http.Handler {
		cfg := config.Load()
		cfg.LoadTestToken = token
		d := ratelimit.NewDistributed(context.Background(), rdb,
			ratelimit.DistConfig{Window: 10 * time.Second, PerIP: 1, PerTenant: 1, FailOpen: false},
			ratelimit.NewMetrics(prometheus.NewRegistry()))
		api := New(cfg, slog.New(slog.NewJSONHandler(io.Discard, nil)), metrics.New(false, false), store.NewFake(), "test")
		api.SetReady(true)
		api.SetDistributedLimiter(d)
		return api.Handler(ratelimit.New(100000, 100000))
	}
	get := func(h http.Handler, hdr string) int {
		r := httptest.NewRequest("GET", "/abcdefg", nil)
		if hdr != "" {
			r.Header.Set(LoadTestHeader, hdr)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}

	h := build("s3cret")
	if c := get(h, ""); c != http.StatusTooManyRequests {
		t.Fatalf("başlıksız istek limiter'dan geçmemeliydi: %d", c)
	}
	if c := get(h, "yanlis"); c != http.StatusTooManyRequests {
		t.Fatalf("yanlış jetonlu istek limiter'dan geçmemeliydi: %d", c)
	}
	if c := get(h, "s3cret"); c == http.StatusTooManyRequests {
		t.Fatal("doğru jetonlu istek yine de 429 aldı — muafiyet çalışmıyor")
	}
	// Jeton yapılandırılmamışsa kimse muaf değildir; boş başlık boş jetonla EŞLEŞMEMELİ.
	if c := get(build(""), ""); c != http.StatusTooManyRequests {
		t.Fatalf("jeton yokken muafiyet olmamalıydı: %d", c)
	}
}
