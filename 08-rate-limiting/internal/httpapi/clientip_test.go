package httpapi

import (
	"bufio"
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"testing"

	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/config"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/08-rate-limiting/internal/store"
)

func req(xff string) *httptest.ResponseRecorder { return httptest.NewRecorder() }

func TestClientIPTrustsOnlyOurProxyHop(t *testing.T) {
	r := httptest.NewRequest("GET", "/x", nil)
	r.RemoteAddr = "10.0.0.1:1234"
	// Client "1.2.3.4" yazdı (taklit); ingress GERÇEK adresi (203.0.113.9) sona ekledi.
	// Güvenilir olan, bizim proxy'mizin eklediği son değerdir.
	r.Header.Set("X-Forwarded-For", "1.2.3.4, 203.0.113.9")

	if got := clientIPFrom(r, 1, false, false); got != "203.0.113.9" {
		t.Fatalf("güvenilen hop yanlış: %s (client'ın yazdığına güvenildi mi?)", got)
	}
}

func TestTrustAnyXFFIsSpoofable(t *testing.T) {
	r := httptest.NewRequest("GET", "/x", nil)
	r.RemoteAddr = "10.0.0.1:1234"
	r.Header.Set("X-Forwarded-For", "1.2.3.4, 203.0.113.9")
	if got := clientIPFrom(r, 1, true, false); got != "1.2.3.4" {
		t.Fatalf("TRAP açıkken client'ın yazdığı değer beklenirdi, %s geldi", got)
	}
}

func TestIgnoreXFFCollapsesEveryoneIntoOneBucket(t *testing.T) {
	a := httptest.NewRequest("GET", "/x", nil)
	a.RemoteAddr = "10.0.0.1:1111"
	// ingress GERÇEK client adresini SONA ekler; baştaki değer client'ın yazdığıdır.
	a.Header.Set("X-Forwarded-For", "1.2.3.4, 198.51.100.11")
	b := httptest.NewRequest("GET", "/x", nil)
	b.RemoteAddr = "10.0.0.1:2222"
	b.Header.Set("X-Forwarded-For", "1.2.3.4, 198.51.100.22")
	if clientIPFrom(a, 1, false, true) != clientIPFrom(b, 1, false, true) {
		t.Fatal("TRAP_IGNORE_XFF açıkken iki farklı client aynı kovada olmalıydı")
	}
	if clientIPFrom(a, 1, false, false) == clientIPFrom(b, 1, false, false) {
		t.Fatal("varsayılanda iki farklı client AYRI kovalarda olmalı")
	}
}

func TestNoXFFFallsBackToPeer(t *testing.T) {
	r := httptest.NewRequest("GET", "/x", nil)
	r.RemoteAddr = "192.0.2.7:9999"
	if got := clientIPFrom(r, 1, false, false); got != "192.0.2.7" {
		t.Fatalf("XFF yokken soket adresi beklenirdi, %s", got)
	}
}

// Access log'un `ip` alanı, limiter'ın kovasını seçtiği adresle AYNI olmalı: client'ın başa yazdığı
// adres loglarda da kimseyi tanımlamaz.
func TestAccessLogRecordsTheLimiterClientIP(t *testing.T) {
	var buf bytes.Buffer
	cfg := config.Load()
	cfg.TrustedProxyHops = 1
	api := New(cfg, slog.New(slog.NewJSONHandler(&buf, nil)), metrics.New(false), store.NewFake(), "test")
	api.SetReady(true)
	h := api.Handler(ratelimit.New(100000, 100000))

	r := httptest.NewRequest("GET", "/api/links", nil)
	r.RemoteAddr = "10.0.0.1:1234"
	r.Header.Set("X-Forwarded-For", "6.6.6.6, 203.0.113.9") // client "6.6.6.6" yazdı; ingress 203.0.113.9 ekledi
	r.Header.Set("X-Tenant-ID", "t1")
	h.ServeHTTP(httptest.NewRecorder(), r)

	want := clientIPFrom(r, cfg.TrustedProxyHops, cfg.TrapTrustAnyXFF, cfg.TrapIgnoreXFF)
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var line map[string]any
		if json.Unmarshal(sc.Bytes(), &line) != nil || line["msg"] != "http" {
			continue
		}
		if line["ip"] != want || want != "203.0.113.9" {
			t.Fatalf("access log ip=%v, limiter'ın gördüğü %s — ikisi aynı istemci olmalı", line["ip"], want)
		}
		return
	}
	t.Fatal("access log satırı yazılmadı")
}
