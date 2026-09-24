package httpapi

import (
	"net/http/httptest"
	"testing"
)

// Her rota KENDİ şablon etiketini almalı; stats ucu `/api/links/{code}`e karışırsa
// "İstatistik ucu süresi (p99)" paneli boş kalır.
func TestRouteOfSeparatesStats(t *testing.T) {
	cases := map[string]string{
		"/api/links":               "/api/links",
		"/api/links/abc1234":       "/api/links/{code}",
		"/api/links/abc1234/stats": "/api/links/{code}/stats",
		"/abc1234":                 "/{code}",
		"/":                        "/",
	}
	for path, want := range cases {
		if got := routeOf(httptest.NewRequest("GET", path, nil)); got != want {
			t.Errorf("routeOf(%q) = %q, beklenen %q", path, got, want)
		}
	}
}

// Uçtan uca: stats isteği /metrics'te panelin süzdüğü etiketle görünmeli.
func TestStatsRequestHasOwnRouteSeries(t *testing.T) {
	h := newTestAPI(t)
	code := createAs(t, h, "t1", "https://example.com/route")
	if w := do(t, h, "GET", "/api/links/"+code+"/stats", "t1"); w.Code != 200 {
		t.Fatalf("stats %d", w.Code)
	}
	body := do(t, h, "GET", "/metrics", "").Body.String()
	if !contains(body, `http_request_duration_seconds_count{route="/api/links/{code}/stats"}`) {
		t.Fatal(`/metrics'te route="/api/links/{code}/stats" serisi yok — panel boş kalır`)
	}
}
