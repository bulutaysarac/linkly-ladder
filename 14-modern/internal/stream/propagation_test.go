package stream

import (
	"context"
	"testing"

	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
	"go.opentelemetry.io/otel/trace/noop"
)

func withTracing(t *testing.T) {
	t.Helper()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSampler(sdktrace.AlwaysSample()))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() {
		_ = tp.Shutdown(context.Background())
		otel.SetTracerProvider(noop.NewTracerProvider())
		otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator())
	})
}

func header(r *kgo.Record, k string) string { return kafkaHeaderCarrier{rec: r}.Get(k) }

// Bağlam kuyruğu geçmeli: üretici kaydın header'ına traceparent yazar, tüketici partinin span'ini
// o trace'e bağlar. Tuzak (TRAP_NO_KAFKA_PROPAGATION) YALNIZCA header'ı kaldırır.
func TestTraceContextCrossesKafkaUnlessTrapped(t *testing.T) {
	withTracing(t)
	ctx, parent := otel.Tracer("test").Start(context.Background(), "GET /{code}")
	defer parent.End()
	want := parent.SpanContext().TraceID()

	p := &Producer{topic: "clicks"}
	rec, span, err := p.newRecord(ctx, "abc1234")
	if err != nil {
		t.Fatal(err)
	}
	span.End()
	if header(rec, "traceparent") == "" {
		t.Fatal("traceparent header'a yazılmadı: tüketici trace'i yetim kalır")
	}
	if got := trace.SpanContextFromContext(batchParent(context.Background(), []*kgo.Record{rec})).TraceID(); got != want {
		t.Fatalf("tüketici başka bir trace'e bağlandı: %s ≠ %s", got, want)
	}

	p.SetNoPropagation(true)
	rec2, span2, _ := p.newRecord(ctx, "abc1234")
	span2.End()
	if header(rec2, "traceparent") != "" {
		t.Fatal("tuzak açıkken bağlam yine header'a yazıldı — tuzak etkisiz")
	}
	if sc := trace.SpanContextFromContext(batchParent(context.Background(), []*kgo.Record{rec2})); sc.IsValid() {
		t.Fatal("header yokken tüketicinin bir ebeveyni olmamalı (yetim kök beklenir)")
	}
}

// Parti span'inin ebeveyni: ÖRNEKLENMİŞ ilk üretici. İlk kaydı körü körüne almak, %5 sampling'de
// neredeyse hep örneklenmemiş bir ebeveyn seçer ve örneklenmiş trace'leri tüketiciden koparır.
func TestBatchParentPrefersSampledProducer(t *testing.T) {
	withTracing(t)
	prop := otel.GetTextMapPropagator()
	mk := func(tid byte, sampled bool) *kgo.Record {
		var flags trace.TraceFlags
		if sampled {
			flags = trace.FlagsSampled
		}
		sc := trace.NewSpanContext(trace.SpanContextConfig{
			TraceID: trace.TraceID{tid, 1}, SpanID: trace.SpanID{tid, 2}, TraceFlags: flags, Remote: true,
		})
		r := &kgo.Record{}
		prop.Inject(trace.ContextWithSpanContext(context.Background(), sc), kafkaHeaderCarrier{rec: r})
		return r
	}
	recs := []*kgo.Record{{}, mk(1, false), mk(2, true), mk(3, true)}
	got := trace.SpanContextFromContext(batchParent(context.Background(), recs))
	if got.TraceID() != (trace.TraceID{2, 1}) || !got.IsSampled() {
		t.Fatalf("örneklenmiş ilk üretici seçilmedi: %s sampled=%v", got.TraceID(), got.IsSampled())
	}
	onlyUnsampled := []*kgo.Record{mk(1, false)}
	if sc := trace.SpanContextFromContext(batchParent(context.Background(), onlyUnsampled)); sc.IsSampled() {
		t.Fatal("örneklenmemiş ebeveyn örneklenmiş gibi davrandı")
	}
}
