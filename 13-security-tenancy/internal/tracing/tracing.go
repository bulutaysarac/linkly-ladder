// Package tracing — OpenTelemetry kurulumu ve örnekleme kararları.
//
// EN: Metrics tell you THAT p99 is high. Traces tell you WHERE. Logs tell you WHY for one request.
//
//	The three only become useful together when they share an identifier — which is why the log
//	line and the histogram observation of every SAMPLED request carry its trace_id. Correlation
//	is not a feature of the tools; it is a discipline in the code (and in middleware order).
//
// TR: Metrikler p99'un yüksek OLDUĞUNU söyler. Trace'ler NEREDE olduğunu. Log'lar tek bir istek
//
//	için NEDEN'i. Üçü ancak ortak bir kimlik paylaştıklarında birlikte işe yarar — bu yüzden
//	ÖRNEKLENEN her isteğin log satırı ve histogram gözlemi trace_id taşıyor. Korelasyon
//	araçların bir özelliği değil, KODDAKİ bir disiplindir (ve middleware sırasındaki).
//
// [Topic · Konu: Metrik/log/trace korelasyonu, sampling]
package tracing

import (
	"context"
	"net/http"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

type Config struct {
	Endpoint    string // alloy/otel-collector, örn. alloy.monitoring.svc:4317
	ServiceName string
	Version     string
	SampleRatio float64 // 0..1
	Enabled     bool
}

// Setup — TracerProvider kur, kapatma fonksiyonu döndür.
func Setup(ctx context.Context, cfg Config) (func(context.Context) error, error) {
	if !cfg.Enabled || cfg.Endpoint == "" {
		otel.SetTracerProvider(trace.NewNoopTracerProvider())
		return func(context.Context) error { return nil }, nil
	}
	exp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(cfg.Endpoint),
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithTimeout(5*time.Second),
	)
	if err != nil {
		return nil, err
	}
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(cfg.ServiceName),
			semconv.ServiceVersion(cfg.Version),
		),
	)
	if err != nil {
		return nil, err
	}

	// EN: Head sampling: the decision is made at the START of the trace, before you know whether
	//     it was slow or failed. That is its weakness (P11-03): rare errors are missed exactly
	//     because they are rare. Tail sampling fixes that but requires buffering every span in a
	//     collector until the trace ends — real memory, real complexity. At this scale, a low
	//     head ratio plus exemplars (which always point at a REAL request) is the better trade.
	// TR: Head sampling: karar trace'in BAŞINDA verilir, yavaş mı ya da hatalı mı olduğunu daha
	//     bilmeden. Zayıflığı da bu (P11-03): nadir hatalar, tam da nadir oldukları için kaçar.
	//     Tail sampling bunu düzeltir ama her span'i trace bitene kadar bir collector'da
	//     tamponlamayı gerektirir — gerçek bellek, gerçek karmaşıklık. Bu ölçekte düşük bir head
	//     oranı + exemplar (her zaman GERÇEK bir isteği gösterir) daha iyi bir takas.
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp, sdktrace.WithMaxQueueSize(2048), sdktrace.WithBatchTimeout(2*time.Second)),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(cfg.SampleRatio))),
	)
	otel.SetTracerProvider(tp)
	// Bağlam yayılımı: W3C traceparent + baggage. Bu olmadan servisler arası trace KOPAR (P11-02).
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))
	return tp.Shutdown, nil
}

// SpanIDs — mevcut span'in trace/span kimlikleri (log satırı ve exemplar için) — YALNIZCA
// örneklenmiş (sampled) bir span varsa.
//
// EN: With 5% head sampling the SDK still gives the other 95% of requests valid trace IDs; their
//
//	spans are simply never exported. Logging those IDs turns every log line into a Loki→Tempo
//	link and every exemplar into a dot that leads to "trace not found" 19 times out of 20 —
//	which teaches the reader that the bridge is broken. An identifier that leads nowhere is
//	worse than none; request_id still correlates the unsampled lines.
//
// TR: %5 head sampling'de SDK geri kalan %95'e de GEÇERLİ trace kimliği verir; yalnızca span'leri
//
//	hiç gönderilmez. O kimlikleri loglamak her log satırını bir Loki→Tempo linkine, her exemplar'ı
//	20'de 19 kez "trace not found"a çıkan bir noktaya çevirir — ve okuyucuya köprünün bozuk
//	olduğunu öğretir. Hiçbir yere götürmeyen bir kimlik, hiç olmamasından kötüdür; örneklenmeyen
//	satırları request_id yine birbirine bağlar.
func SpanIDs(ctx context.Context) (traceID, spanID string) {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() || !sc.IsSampled() {
		return "", ""
	}
	return sc.TraceID().String(), sc.SpanID().String()
}

// Start — isimlendirilmiş bir alt span aç (iç adım: guard, önbellek, sorgu).
func Start(ctx context.Context, name string, attrs ...attribute.KeyValue) (context.Context, trace.Span) {
	return otel.Tracer("linkly").Start(ctx, name, trace.WithAttributes(attrs...))
}

// StartKind — türü belirtilmiş span (Kafka üreticisi / tüketicisi).
func StartKind(ctx context.Context, name string, kind trace.SpanKind, attrs ...attribute.KeyValue) (context.Context, trace.Span) {
	return otel.Tracer("linkly").Start(ctx, name, trace.WithSpanKind(kind), trace.WithAttributes(attrs...))
}

// EndErr — span'i bitir; hata varsa span'e işle (Tempo'da kırmızı görünsün).
func EndErr(span trace.Span, err error) {
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	span.End()
}

// HTTPServer — isteğin KÖK span'i (ya da gelen `traceparent`'in çocuğu), log ve metrik
// katmanlarından ÖNCE açılır.
//
// EN: The access log and the request histogram are the two places that publish a trace ID — the
//
//	log line's trace_id (the Loki → Tempo derived field) and the exemplar — and both read it
//	from the request context. So the server span must already be in that context when they
//	run: a span opened inside the handler is invisible to them, every line would carry
//	"trace_id":"" and the three pillars would be wired correctly and connected to nothing.
//	Extracting `traceparent` first lets a caller that is already tracing (a gateway, another
//	service, a test) continue ITS trace. Correlation is decided by middleware ORDER.
//
// TR: Erişim logu ve istek histogramı trace kimliğini yayınlayan iki yerdir — log satırındaki
//
//	trace_id (Loki → Tempo derived field) ve exemplar — ve ikisi de onu istek bağlamından okur.
//	Yani onlar çalıştığında sunucu span'i o bağlamda HAZIR olmalı: handler'ın içinde açılan bir
//	span onlara görünmez, her satır "trace_id":"" taşır ve üç ayak doğru bağlanmış olup HİÇBİR
//	ŞEYE bağlı olmaz. Önce `traceparent`i çıkarmak, zaten iz süren bir çağıranın (ağ geçidi,
//	başka bir servis, bir test) KENDİ trace'ine devam etmesini sağlar. Korelasyonu middleware
//	SIRASI belirler.
//
// [Topic · Konu: Bağlam yayılımı, middleware sırası]
func HTTPServer(next http.Handler, route func(*http.Request) string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Client bir trace başlattıysa (traceparent) ona bağlan: ParentBased sampler onun
		// örnekleme kararını da onurlandırır.
		ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
		rt := route(r)
		ctx, span := otel.Tracer("linkly").Start(ctx, r.Method+" "+rt,
			trace.WithSpanKind(trace.SpanKindServer),
			trace.WithAttributes(semconv.HTTPRequestMethodKey.String(r.Method), semconv.HTTPRoute(rt)))
		defer span.End()
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r.WithContext(ctx))
		if sw.status == 0 {
			sw.status = http.StatusOK
		}
		span.SetAttributes(semconv.HTTPResponseStatusCode(sw.status))
		if sw.status >= 500 {
			span.SetStatus(codes.Error, http.StatusText(sw.status))
		}
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(c int) {
	if w.status == 0 {
		w.status = c
	}
	w.ResponseWriter.WriteHeader(c)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}
