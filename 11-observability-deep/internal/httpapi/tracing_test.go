package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/bulutaysarac/linkly-ladder/11-observability-deep/internal/config"
	"github.com/bulutaysarac/linkly-ladder/11-observability-deep/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/11-observability-deep/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/11-observability-deep/internal/store"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	"go.opentelemetry.io/otel/trace/noop"
)

// withTestTracing — küresel TracerProvider'ı bir kayıt ediciye bağla. ParentBased(NeverSample):
// kendi başına HİÇBİR isteği örneklemez; yalnızca gelen traceparent "sampled" diyorsa örnekler.
// Böylece test hem "gelen bağlam onurlandırılıyor mu?" hem de "örneklenmeyen istek kimlik
// sızdırıyor mu?" sorularını aynı anda sınar.
func withTestTracing(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	sr := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.NeverSample())),
		sdktrace.WithSpanProcessor(sr))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() {
		_ = tp.Shutdown(context.Background())
		otel.SetTracerProvider(noop.NewTracerProvider())
		otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator())
	})
	return sr
}

func accessLines(t *testing.T, buf *bytes.Buffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, ln := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		var m map[string]any
		if json.Unmarshal([]byte(ln), &m) == nil && m["msg"] == "http" {
			out = append(out, m)
		}
	}
	return out
}

// Sunucu span'i erişim logu ve metrik katmanından ÖNCE açılmalı: log satırı trace_id taşımalı,
// histogram exemplar almalı ve gelen traceparent'in trace'ine bağlanılmalı. Handler'ın içinde
// açılan bir span bu üçüne de görünmez.
func TestServerSpanFeedsLogAndExemplarAndHonoursTraceparent(t *testing.T) {
	sr := withTestTracing(t)
	var logs bytes.Buffer
	cfg := config.Load()
	cfg.RateLimitPerSec, cfg.RateLimitBurst = 100000, 100000
	met := metrics.New(false, false)
	api := New(cfg, slog.New(slog.NewJSONHandler(&logs, nil)), met, store.NewFake(), "test")
	api.SetReady(true)
	var got trace.SpanContext
	api.SetClicks(recorderFunc(func(ctx context.Context, _ string) { got = trace.SpanContextFromContext(ctx) }))
	h := api.Handler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst))
	code := createAs(t, h, "t1", "https://example.com/traced")

	const traceID = "4bf92f3577b34da6a3ce929d0e0e4736"
	r := httptest.NewRequest("GET", "/"+code, nil)
	r.Header.Set("traceparent", "00-"+traceID+"-00f067aa0ba902b7-01")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusFound {
		t.Fatalf("redirect %d", w.Code)
	}

	// (1) log satırı: örneklenmemiş create'te trace_id BOŞ, traceparent'li redirect'te dolu.
	lines := accessLines(t, &logs)
	if len(lines) != 2 {
		t.Fatalf("2 erişim satırı bekleniyordu, %d", len(lines))
	}
	if lines[0]["trace_id"] != "" {
		t.Errorf("örneklenmemiş istek trace_id sızdırdı: %v (Tempo'da olmayan bir trace'e link olurdu)", lines[0]["trace_id"])
	}
	if lines[1]["trace_id"] != traceID {
		t.Fatalf("log satırındaki trace_id=%v, gelen traceparent=%s — span log katmanından SONRA mı açılıyor?", lines[1]["trace_id"], traceID)
	}
	// (2) sunucu span'i gelen span'in çocuğu.
	var server sdktrace.ReadOnlySpan
	for _, s := range sr.Ended() {
		if s.Name() == "GET /{code}" {
			server = s
		}
	}
	if server == nil {
		t.Fatal(`"GET /{code}" sunucu span'i kaydedilmedi`)
	}
	if server.Parent().SpanID().String() != "00f067aa0ba902b7" || server.SpanContext().TraceID().String() != traceID {
		t.Fatalf("sunucu span'i gelen traceparent'e bağlanmadı: parent=%s trace=%s", server.Parent().SpanID(), server.SpanContext().TraceID())
	}
	// (3) bağlam tıklama kaydedicisine (Kafka üreticisine) kadar taşınıyor.
	if got.TraceID().String() != traceID {
		t.Fatalf("Record'a giden bağlamda trace yok (%s): Kafka header'ına yazılacak bir şey kalmaz", got.TraceID())
	}
	// (4) exemplar: histogram gözlemi bu trace'e işaret ediyor.
	mr := httptest.NewRequest("GET", "/metrics", nil)
	mr.Header.Set("Accept", "application/openmetrics-text; version=1.0.0")
	mw := httptest.NewRecorder()
	h.ServeHTTP(mw, mr)
	body, _ := io.ReadAll(mw.Body)
	if !strings.Contains(string(body), `trace_id="`+traceID+`"`) {
		t.Fatal("http_request_duration_seconds exemplar'ı bu trace_id'yi taşımıyor")
	}
}

type recorderFunc func(ctx context.Context, code string)

func (f recorderFunc) Record(ctx context.Context, code string) { f(ctx, code) }

// Profil uçları yalnızca iç handler'da: servis portunda (ingress'in gönderdiği yer) YOK.
func TestPprofOnlyOnInternalPort(t *testing.T) {
	w := httptest.NewRecorder()
	PprofHandler().ServeHTTP(w, httptest.NewRequest("GET", "/debug/pprof/", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("iç pprof ucu %d döndü", w.Code)
	}
	cfg := config.Load()
	api := New(cfg, slog.New(slog.NewJSONHandler(io.Discard, nil)), metrics.New(false, false), store.NewFake(), "test")
	for name, h := range map[string]http.Handler{
		"redirect": api.RedirectHandler(ratelimit.New(1000, 1000)),
		"api":      api.APIHandler(ratelimit.New(1000, 1000)),
	} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", "/debug/pprof/", nil))
		if w.Code == http.StatusOK {
			t.Errorf("%s servis portunda /debug/pprof açık — ingress onu internete çıkarır", name)
		}
	}
}
