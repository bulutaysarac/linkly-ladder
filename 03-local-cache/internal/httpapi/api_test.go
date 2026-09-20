package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/bulutaysarac/linkly-ladder/03-local-cache/internal/config"
	"github.com/bulutaysarac/linkly-ladder/03-local-cache/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/03-local-cache/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/03-local-cache/internal/store"
)

func newTestAPI(t *testing.T) http.Handler {
	t.Helper()
	h, _ := newTestAPIWithStore(t, store.NewFake())
	return h
}

func newTestAPIWithStore(t *testing.T, st *store.Fake) (http.Handler, *store.Fake) {
	t.Helper()
	cfg := config.Load()
	cfg.RateLimitPerSec = 100000
	cfg.RateLimitBurst = 100000
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))
	api := New(cfg, log, metrics.New(false), st, "test")
	api.SetReady(true)
	return api.Handler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst)), st
}

func createAs(t *testing.T, h http.Handler, tenant, url string) string {
	t.Helper()
	r := httptest.NewRequest("POST", "/api/links", strings.NewReader(`{"url":"`+url+`"}`))
	r.Header.Set("X-Tenant-ID", tenant)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusCreated {
		t.Fatalf("create %d: %s", w.Code, w.Body.String())
	}
	var body map[string]string
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	return body["code"]
}

func do(t *testing.T, h http.Handler, method, path, tenant string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, nil)
	if tenant != "" {
		r.Header.Set("X-Tenant-ID", tenant)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

// 02'nin yeni sınırı: kiracı. A, B'nin linkini SİLEMEMELİ ve listesinde GÖRMEMELİ.
// Not: silme denemesi 404 döner, 403 değil — başkasının linkinin VARLIĞINI bile sızdırmıyoruz.
func TestTenantBoundaryOnDeleteAndList(t *testing.T) {
	h := newTestAPI(t)
	codeA := createAs(t, h, "tenant-a", "https://example.com/a")
	_ = createAs(t, h, "tenant-b", "https://example.com/b")

	if got := do(t, h, "DELETE", "/api/links/"+codeA, "tenant-b").Code; got != http.StatusNotFound {
		t.Fatalf("yabancı kiracı silebildi (%d) — kiracı sınırı yok", got)
	}
	if got := do(t, h, "GET", "/"+codeA, "tenant-b").Code; got != http.StatusFound {
		t.Fatalf("redirect kiracıdan bağımsız olmalı, %d geldi", got)
	}

	var list struct {
		Links []store.Link `json:"links"`
	}
	_ = json.Unmarshal(do(t, h, "GET", "/api/links", "tenant-b").Body.Bytes(), &list)
	for _, l := range list.Links {
		if l.Tenant != "tenant-b" {
			t.Fatalf("liste yabancı kiracının linkini sızdırdı: %+v", l)
		}
	}
	if got := do(t, h, "DELETE", "/api/links/"+codeA, "tenant-a").Code; got != http.StatusNoContent {
		t.Fatalf("sahibi silemedi: %d", got)
	}
}

// Veritabanı düştüğünde: 500 değil 503 + yapılandırılmış hata; asla panic, asla boş 200.
func TestDatabaseFailureReturns503(t *testing.T) {
	fake := store.NewFake()
	h, _ := newTestAPIWithStore(t, fake)
	fake.FailWith = errors.New("connection refused")

	for _, tc := range []struct{ method, path string }{
		{"GET", "/abcdefg"}, {"GET", "/api/links"}, {"GET", "/api/links/abcdefg"},
	} {
		if got := do(t, h, tc.method, tc.path, "t1").Code; got != http.StatusServiceUnavailable {
			t.Errorf("%s %s → %d (503 bekleniyordu)", tc.method, tc.path, got)
		}
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/api/links", strings.NewReader(`{"url":"https://example.com"}`))
	h.ServeHTTP(w, r)
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("POST → %d (503 bekleniyordu)", w.Code)
	}
}

// readyz varsayılan olarak bağımlılığa BAKMAZ: DB düşse de pod "hazır" kalır.
// Sebebi P02-10'da ölçülüyor — aksi hâlde kısmi arıza tam kesintiye dönüşür.
func TestReadyzIgnoresDatabaseByDefault(t *testing.T) {
	fake := store.NewFake()
	h, _ := newTestAPIWithStore(t, fake)
	fake.FailWith = errors.New("db down")
	if got := do(t, h, "GET", "/readyz", "").Code; got != http.StatusOK {
		t.Fatalf("readyz DB'ye bağımlı hâle gelmiş (%d) — P02-10'daki tuzak varsayılan olmuş", got)
	}
}

func create(t *testing.T, h http.Handler, url string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest("POST", "/api/links", strings.NewReader(`{"url":"`+url+`"}`))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

// P00-10: 301 + önbellek başlığı yok → tarayıcı kalıcı önbellekliyordu.
func TestRedirectIs302WithNoStore(t *testing.T) {
	h := newTestAPI(t)
	var body map[string]string
	_ = json.Unmarshal(create(t, h, "https://example.com/x").Body.Bytes(), &body)

	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/"+body["code"], nil))
	if w.Code != http.StatusFound {
		t.Fatalf("302 bekleniyordu, %d geldi (301 geri gelmiş olabilir)", w.Code)
	}
	if cc := w.Header().Get("Cache-Control"); !strings.Contains(cc, "no-store") {
		t.Fatalf("Cache-Control: no-store bekleniyordu, %q geldi", cc)
	}
}

// P00-06: javascript:, iç adresler ve dev gövde kabul ediliyordu.
func TestUnsafeTargetsRejected(t *testing.T) {
	h := newTestAPI(t)
	for _, u := range []string{
		"javascript:alert(1)", "data:text/html,x", "", "   ", "not-a-url",
		"http://169.254.169.254/latest/meta-data/", "http://127.0.0.1:8080/",
		"http://10.0.0.5/admin", "http://localhost/x",
	} {
		if got := create(t, h, u).Code; got != http.StatusBadRequest {
			t.Errorf("%q için 400 bekleniyordu, %d geldi", u, got)
		}
	}
}

func TestLargeBodyRejected(t *testing.T) {
	h := newTestAPI(t)
	big := strings.Repeat("a", 64*1024)
	if got := create(t, h, "https://example.com/"+big).Code; got != http.StatusRequestEntityTooLarge {
		t.Fatalf("413 bekleniyordu, %d geldi — MaxBytesReader devrede değil", got)
	}
}

func TestHealthReadyMetricsBypassBusinessChain(t *testing.T) {
	h := newTestAPI(t)
	for path, want := range map[string]int{"/healthz": 200, "/readyz": 200, "/metrics": 200} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != want {
			t.Errorf("%s → %d (beklenen %d)", path, w.Code, want)
		}
	}
}

// Sıfırla kaydedilen sayaçlar: "hiç olmadı" ile "raporlamıyor" ayırt edilebilmeli.
func TestCountersPreRegisteredAtZero(t *testing.T) {
	h := newTestAPI(t)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/metrics", nil))
	out := w.Body.String()
	for _, want := range []string{
		`redirect_total{result="not_found"} 0`,
		`create_total{result="collision"} 0`,
		`create_rejected_unsafe_total{reason="scheme"} 0`,
		`ratelimit_decisions_total{decision="reject",key_type="ip"} 0`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("metrik sıfırda kayıtlı değil: %s", want)
		}
	}
}

func TestRateLimitReturns429(t *testing.T) {
	cfg := config.Load()
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))
	api := New(cfg, log, metrics.New(false), store.NewFake(), "test")
	api.SetReady(true)
	h := api.Handler(ratelimit.New(1, 1)) // 1 rps, 1 burst

	first := httptest.NewRecorder()
	h.ServeHTTP(first, httptest.NewRequest("GET", "/abcdefg", nil))
	second := httptest.NewRecorder()
	h.ServeHTTP(second, httptest.NewRequest("GET", "/abcdefg", nil))
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("ikinci istekte 429 bekleniyordu, %d geldi", second.Code)
	}
	if second.Header().Get("Retry-After") == "" {
		t.Error("429 yanıtında Retry-After yok — client ne zaman deneyeceğini bilemez")
	}
}

func TestRedirectNotFoundCounted(t *testing.T) {
	h := newTestAPI(t)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/zzzzzzz", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("404 bekleniyordu, %d", w.Code)
	}
	m := httptest.NewRecorder()
	h.ServeHTTP(m, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(m.Body.String(), `redirect_total{result="not_found"} 1`) {
		t.Error("404 sayılmadı — P00-09 geri gelmiş (kaç 404 döndüğünü söyleyemiyorsun)")
	}
}
