package stream

import (
	"context"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
)

// kafkaHeaderCarrier — OTel bağlamını Kafka header'larına taşır.
type kafkaHeaderCarrier struct{ rec *kgo.Record }

func (c kafkaHeaderCarrier) Get(key string) string {
	for _, h := range c.rec.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}

func (c kafkaHeaderCarrier) Set(key, value string) {
	c.rec.Headers = append(c.rec.Headers, kgo.RecordHeader{Key: key, Value: []byte(value)})
}

func (c kafkaHeaderCarrier) Keys() []string {
	out := make([]string, 0, len(c.rec.Headers))
	for _, h := range c.rec.Headers {
		out = append(out, h.Key)
	}
	return out
}

type ProducerMetrics struct {
	Records  *prometheus.CounterVec // result
	Buffered prometheus.Gauge
	Latency  prometheus.Histogram
}

func NewProducerMetrics(reg prometheus.Registerer) *ProducerMetrics {
	m := &ProducerMetrics{
		Records: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "producer_records_total", Help: "Üretilen kayıt"}, []string{"result"}),
		Buffered: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "producer_buffered_records", Help: "Tamponda bekleyen kayıt"}),
		Latency: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "producer_ack_duration_seconds", Help: "Üretimden ack'e kadar geçen süre",
			Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5}}),
	}
	reg.MustRegister(m.Records, m.Buffered, m.Latency)
	for _, r := range []string{"ok", "error", "dropped"} {
		m.Records.WithLabelValues(r)
	}
	return m
}

type Producer struct {
	cl            *kgo.Client
	noPropagation bool
	topic         string
	m             *ProducerMetrics
	log           *slog.Logger
	buffered      atomic.Int64
	maxBuf        int64
}

func NewProducer(brokers []string, topic string, maxBuffered int, m *ProducerMetrics, log *slog.Logger) (*Producer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.DefaultProduceTopic(topic),
		// EN: acks=all is the difference between "the broker said yes" and "the data survives a
		//     broker restart". It costs latency on the PRODUCER side only — and the producer here
		//     is asynchronous, so the user never feels it. Choosing durability is free exactly
		//     when the write is off the request path (level 05 made that possible).
		// TR: acks=all, "broker evet dedi" ile "veri broker yeniden başlasa da yaşar" arasındaki
		//     farktır. Bedeli yalnızca ÜRETİCİ tarafında gecikmedir — ve buradaki üretici asenkron
		//     olduğu için kullanıcı bunu hiç hissetmez. Dayanıklılık seçmek, tam da yazma istek
		//     yolundan çıktığında bedavadır (bunu 05 mümkün kıldı).
		kgo.RequiredAcks(kgo.AllISRAcks()),
		kgo.ProducerBatchMaxBytes(1<<20),
		kgo.ProducerLinger(20*time.Millisecond),
		kgo.RecordRetries(5),
		kgo.RetryTimeout(10*time.Second),
	)
	if err != nil {
		return nil, err
	}
	return &Producer{cl: cl, topic: topic, m: m, log: log, maxBuf: int64(maxBuffered)}, nil
}

// Record — istek yolundan çağrılır ve ASLA bloklamaz.
//
// EN: franz-go's Produce is already asynchronous, but "asynchronous" is not the same as "bounded".
//
//	If the broker is down, records pile up in the client's buffer until memory runs out — the
//	unbounded-queue mistake of P05-02, moved one layer down. So we keep our own counter and
//	DROP past a limit. A broker outage must degrade analytics, never the redirect.
//
// TR: franz-go'nun Produce'u zaten asenkron, ama "asenkron" ile "sınırlı" aynı şey değil. Broker
//
//	düşerse kayıtlar istemci tamponunda bellek bitene kadar birikir — P05-02'deki sınırsız kuyruk
//	hatasının bir kat aşağı taşınmış hâli. Bu yüzden kendi sayacımızı tutup sınırı aşınca
//	DÜŞÜRÜYORUZ. Bir broker kesintisi analitiği bozabilir, redirect'i ASLA.
//
// [Topic · Konu: Back pressure, bağımlılık izolasyonu]
func (p *Producer) Record(code string) { p.RecordCtx(context.Background(), code) }

func (p *Producer) RecordCtx(ctx context.Context, code string) {
	if p.buffered.Load() >= p.maxBuf {
		p.m.Records.WithLabelValues("dropped").Inc()
		return
	}
	ev := NewClickEvent(code)
	val, err := ev.Marshal()
	if err != nil {
		p.m.Records.WithLabelValues("error").Inc()
		return
	}
	start := time.Now()
	p.buffered.Add(1)
	p.m.Buffered.Set(float64(p.buffered.Load()))
	// Anahtar = kısa kod: aynı linkin olayları aynı partition'a gider, yani SIRA korunur.
	// Bedeli: sıcak bir link tek partition'a yüklenir (P06-03 ile aynı madalyonun iki yüzü).
	rec := &kgo.Record{Key: []byte(code), Value: val}
	// Trace bağlamını mesaj HEADER'ına koy: tüketicideki span, üreticideki span'in ÇOCUĞU olsun.
	// Konmazsa trace kuyrukta KOPAR ve tüketici span'ları yetim kalır (P11-02) — "istek nerede
	// yavaşladı?" sorusu tam da asenkron sınırda cevapsız kalır.
	if !p.noPropagation {
		carrier := kafkaHeaderCarrier{rec: rec}
		otel.GetTextMapPropagator().Inject(ctx, carrier)
	}
	p.cl.Produce(context.Background(), rec,
		func(_ *kgo.Record, err error) {
			p.buffered.Add(-1)
			p.m.Buffered.Set(float64(p.buffered.Load()))
			p.m.Latency.Observe(time.Since(start).Seconds())
			if err != nil {
				p.m.Records.WithLabelValues("error").Inc()
				return
			}
			p.m.Records.WithLabelValues("ok").Inc()
		})
}

// Flush — kapanışta tampondakileri gönder. 05'teki drain'in karşılığı.
// SetNoPropagation — TRAP_NO_KAFKA_PROPAGATION (P11-02).
func (p *Producer) SetNoPropagation(v bool) { p.noPropagation = v }

func (p *Producer) Flush(ctx context.Context) error { return p.cl.Flush(ctx) }
func (p *Producer) Close()                          { p.cl.Close() }
func (p *Producer) Buffered() int64                 { return p.buffered.Load() }
