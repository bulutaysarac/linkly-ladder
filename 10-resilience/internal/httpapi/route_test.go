package httpapi

import (
	"net/http/httptest"
	"testing"
)

// Metrik etiketi = rota ŞABLONU. Her uç kendi şablonuna düşmeli; iki ucu tek şablona toplamak,
// dashboard'daki uç-başına panelleri (ör. stats p99) sessizce boşaltır.
func TestRouteTemplates(t *testing.T) {
	cases := map[string]string{
		"/":                        "/",
		"/abc1234":                 "/{code}",
		"/api/links":               "/api/links",
		"/api/links/abc1234":       "/api/links/{code}",
		"/api/links/abc1234/stats": "/api/links/{code}/stats",
	}
	for path, want := range cases {
		if got := routeOf(httptest.NewRequest("GET", path, nil)); got != want {
			t.Errorf("routeOf(%q) = %q, beklenen %q", path, got, want)
		}
	}
	if got := shortCodeOf(httptest.NewRequest("GET", "/api/links/abc1234/stats", nil)); got != "abc1234" {
		t.Errorf("shortCodeOf(stats) = %q, beklenen abc1234", got)
	}
}
