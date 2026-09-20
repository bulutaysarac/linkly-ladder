package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/auth"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/config"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/store"
	"github.com/prometheus/client_golang/prometheus"
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

// 13'ten itibaren kiracı, DOĞRULANMIŞ kimlikten gelir. Testler de bu sözleşmeye uymalı:
// header göndererek kiracı seçmek artık mümkün değil — ve bu, testlerin değişmesi gereken
// türden bir değişikliktir. "Testi değiştirmek zorunda kaldım" bazen bir sinyal, bazen de
// SÖZLEŞMENİN gerçekten değiştiğinin kanıtıdır.
func newAuthedAPI(t *testing.T, st *store.Fake) (http.Handler, map[string]string) {
	t.Helper()
	cfg := config.Load()
	cfg.RateLimitPerSec, cfg.RateLimitBurst = 100000, 100000
	cfg.AuthRequired = true
	cfg.ResolveDNS = false // birim testte DNS'e çıkma
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))
	api := New(cfg, log, metrics.New(false), st, "test")
	api.SetReady(true)
	keys := auth.NewStore(auth.NewMetrics(prometheus.NewRegistry()))
	tokens := map[string]string{"tenant-a": "key-a", "tenant-b": "key-b"}
	for tenant, key := range tokens {
		keys.Add(key, auth.Identity{Tenant: tenant, Tier: "pro"})
	}
	api.SetAuth(keys)
	// Dağıtık limiter yoksa chain() süreç içi zincire düşer ve auth devreye girmez;
	// bu yüzden testte auth'u doğrudan sarıyoruz.
	business := api.APIHandler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst))
	return authenticate(business, keys, cfg.AuthRequired, cfg.TrapHeaderTenant), tokens
}

func withKey(r *http.Request, key string) *http.Request {
	r.Header.Set("Authorization", "Bearer "+key)
	return r
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
// Kiracı sınırı artık API ANAHTARINA dayanıyor, header'a değil.
func TestTenantBoundaryUsesVerifiedIdentity(t *testing.T) {
	h, keys := newAuthedAPI(t, store.NewFake())

	// A kiracısı bir link oluşturur.
	w := httptest.NewRecorder()
	h.ServeHTTP(w, withKey(httptest.NewRequest("POST", "/api/links",
		strings.NewReader(`{"url":"https://example.com/a"}`)), keys["tenant-a"]))
	if w.Code != http.StatusCreated {
		t.Fatalf("create %d: %s", w.Code, w.Body.String())
	}
	var body map[string]string
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	codeA := body["code"]

	// B kiracısı A'nın linkini silemez — VARLIĞINI bile öğrenemez (404, 403 değil).
	del := httptest.NewRecorder()
	h.ServeHTTP(del, withKey(httptest.NewRequest("DELETE", "/api/links/"+codeA, nil), keys["tenant-b"]))
	if del.Code != http.StatusNotFound {
		t.Fatalf("yabancı kiracı silebildi (%d) — kiracı sınırı kimliğe bağlı değil", del.Code)
	}

	// Header ile kiracı TAKLİT ETMEK artık işe yaramaz: karar anahtardan geliyor.
	spoof := httptest.NewRequest("DELETE", "/api/links/"+codeA, nil)
	spoof.Header.Set("X-Tenant-ID", "tenant-a")
	sw := httptest.NewRecorder()
	h.ServeHTTP(sw, withKey(spoof, keys["tenant-b"]))
	if sw.Code == http.StatusNoContent {
		t.Fatal("X-Tenant-ID header'ı ile kiracı taklit edilebildi — kimlik etkisiz")
	}

	// Sahibi silebilir.
	own := httptest.NewRecorder()
	h.ServeHTTP(own, withKey(httptest.NewRequest("DELETE", "/api/links/"+codeA, nil), keys["tenant-a"]))
	if own.Code != http.StatusNoContent {
		t.Fatalf("sahibi silemedi: %d", own.Code)
	}
}

// Kimlik bilgisi olmadan yönetim uçları 401 dönmeli (WWW-Authenticate ile).
func TestManagementRequiresCredentials(t *testing.T) {
	h, _ := newAuthedAPI(t, store.NewFake())
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/api/links", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("kimliksiz istek %d aldı, 401 bekleniyordu", w.Code)
	}
	if w.Header().Get("WWW-Authenticate") == "" {
		t.Error("401 yanıtı WWW-Authenticate taşımıyor — client nasıl kimlik göndereceğini bilemez")
	}
	bad := httptest.NewRecorder()
	h.ServeHTTP(bad, withKey(httptest.NewRequest("GET", "/api/links", nil), "yanlis-anahtar"))
	if bad.Code != http.StatusUnauthorized {
		t.Fatalf("geçersiz anahtar %d aldı, 401 bekleniyordu", bad.Code)
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

// --- 05'e özgü ---

type countingRecorder struct {
	mu sync.Mutex
	n  map[string]int
}

func (c *countingRecorder) Record(code string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.n == nil {
		c.n = map[string]int{}
	}
	c.n[code]++
}

func (c *countingRecorder) count(code string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n[code]
}

// Redirect artık DB'ye YAZMIYOR: tıklama kaydediciye gidiyor, store'a değil.
func TestRedirectRecordsClickWithoutWritingStore(t *testing.T) {
	st := store.NewFake()
	cfg := config.Load()
	cfg.RateLimitPerSec, cfg.RateLimitBurst = 100000, 100000
	api := New(cfg, slog.New(slog.NewJSONHandler(io.Discard, nil)), metrics.New(false), st, "test")
	api.SetReady(true)
	rec := &countingRecorder{}
	api.SetClicks(rec)
	h := api.Handler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst))

	code := createAs(t, h, "t1", "https://example.com/async")
	for i := 0; i < 7; i++ {
		if got := do(t, h, "GET", "/"+code, "t1").Code; got != http.StatusFound {
			t.Fatalf("redirect %d", got)
		}
	}
	if rec.count(code) != 7 {
		t.Fatalf("7 tıklama kaydedilmeliydi, %d oldu", rec.count(code))
	}
	l, _ := st.Get(context.Background(), code)
	if l.Clicks != 0 {
		t.Fatalf("redirect store'a yazmamalıydı (clicks=%d) — yazma okuma yolundan çıkmadı", l.Clicks)
	}
}

// Analitik bağlı değilse bile redirect çalışmalı: eksik bağımlılık ana işlevi düşürmemeli.
func TestRedirectWorksWithoutRecorder(t *testing.T) {
	h := newTestAPI(t)
	code := createAs(t, h, "t1", "https://example.com/norec")
	if got := do(t, h, "GET", "/"+code, "t1").Code; got != http.StatusFound {
		t.Fatalf("kaydedici yokken redirect %d", got)
	}
}

// Stats ucu tazeliğini İLAN ETMELİ: sayı bayat olabilir ve API bunu söylemeli.
func TestStatsDeclaresFreshness(t *testing.T) {
	h := newTestAPI(t)
	code := createAs(t, h, "t1", "https://example.com/stats")
	w := do(t, h, "GET", "/api/links/"+code+"/stats", "t1")
	if w.Code != http.StatusOK {
		t.Fatalf("stats %d: %s", w.Code, w.Body.String())
	}
	if w.Header().Get("X-Stats-Freshness") != "eventual" {
		t.Error("stats yanıtı tazelik garantisini ilan etmiyor")
	}
}
