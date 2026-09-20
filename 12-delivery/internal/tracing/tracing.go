// Package tracing — OpenTelemetry kurulumu ve örnekleme kararları.
//
// EN: Metrics tell you THAT p99 is high. Traces tell you WHERE. Logs tell you WHY for one request.
//
//	The three only become useful together when they share an identifier — which is why every
//	log line here carries trace_id and every histogram carries exemplars. Correlation is not a
//	feature of the tools; it is a discipline in the code.
//
// TR: Metrikler p99'un yüksek OLDUĞUNU söyler. Trace'ler NEREDE olduğunu. Log'lar tek bir istek
//
//	için NEDEN'i. Üçü ancak ortak bir kimlik paylaştıklarında birlikte işe yarar — bu yüzden
//	buradaki her log satırı trace_id taşıyor ve her histogram exemplar taşıyor. Korelasyon
//	araçların bir özelliği değil, KODDAKİ bir disiplindir.
//
// [Topic · Konu: Metrik/log/trace korelasyonu, sampling]
package tracing

import (
	"context"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
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

// SpanIDs — mevcut span'in trace/span kimlikleri (log'lara eklemek için).
func SpanIDs(ctx context.Context) (traceID, spanID string) {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return "", ""
	}
	return sc.TraceID().String(), sc.SpanID().String()
}

// Start — isimlendirilmiş bir alt span aç.
func Start(ctx context.Context, name string, attrs ...attribute.KeyValue) (context.Context, trace.Span) {
	return otel.Tracer("linkly").Start(ctx, name, trace.WithAttributes(attrs...))
}
