package stream

import (
	"context"
	"errors"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/twmb/franz-go/pkg/kgo"
)

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
	cl       *kgo.Client
	topic    string
	m        *ProducerMetrics
	log      *slog.Logger
	buffered atomic.Int64
	maxBuf   int64
}

func NewProducer(brokers []string, topic string, maxBuffered int, m *ProducerMetrics, log *slog.Logger) (*Producer, error) {
	if maxBuffered < 1 {
		maxBuffered = 1
	}
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
		// EN: franz-go has its OWN buffer limit — 10,000 records by default — and at that limit
		//     Produce BLOCKS. Our limit (PRODUCER_MAX_BUFFERED, 50,000) is above that default, so
		//     with the default left in place a long broker outage makes the library block first:
		//     Record() stalls the redirect request and our drop counter can never fire. The app's
		//     limit must be the effective one; the client's is only a safety net above it (and
		//     TryProduce below never blocks on it).
		// TR: franz-go'nun KENDİ tampon sınırı var — varsayılan 10.000 kayıt — ve o sınırda
		//     Produce BLOKLAR. Bizim sınırımız (PRODUCER_MAX_BUFFERED, 50.000) bu varsayılanın
		//     üstünde; varsayılan yerinde kalırsa uzun bir broker kesintisinde önce kütüphane
		//     bloklar: Record() redirect isteğini bekletir, bizim düşürme sayacımız hiç
		//     tetiklenemez. Geçerli sınır uygulamanınki
		//     olmalı; istemcininki onun üstünde yalnızca bir güvenlik ağı (aşağıdaki TryProduce
		//     ona çarpsa bile bloklamaz).
		kgo.MaxBufferedRecords(2*maxBuffered),
	)
	if err != nil {
		return nil, err
	}
	return &Producer{cl: cl, topic: topic, m: m, log: log, maxBuf: int64(maxBuffered)}, nil
}

// Record — istek yolundan çağrılır ve ASLA bloklamaz.
//
// EN: franz-go's Produce is asynchronous, but "asynchronous" is not the same as "never waits".
//
//	Its buffer is bounded (10,000 records by default) and when it is full Produce BLOCKS the
//	caller — here, the redirect request. A bound without a drop policy only moves the waiting
//	somewhere else: P05-02's lesson, one layer down. So we keep our own counter, DROP past it,
//	and enqueue with TryProduce, which fails instead of waiting. A broker outage must degrade
//	analytics, never the redirect.
//
// TR: franz-go'nun Produce'u asenkron, ama "asenkron" ile "hiç beklemez" aynı şey değil. Tamponu
//
//	sınırlı (varsayılan 10.000 kayıt) ve dolduğunda Produce çağıranı BLOKLAR — burada redirect
//	isteğini. Düşürme politikası olmayan bir sınır, beklemeyi yalnızca başka yere taşır:
//	P05-02'nin dersi, bir kat aşağıda. Bu yüzden kendi sayacımızı tutup sınırı aşınca
//	DÜŞÜRÜYORUZ ve kaydı beklemek yerine hata veren TryProduce ile ekliyoruz. Bir broker
//	kesintisi analitiği bozabilir, redirect'i ASLA.
//
// [Topic · Konu: Back pressure, bağımlılık izolasyonu]
func (p *Producer) Record(code string) {
	// Önce yer AYIR, sonra üret. "Oku, sınırın altındaysa ekle" iki eşzamanlı isteği aynı son
	// boşluğa sokabilir; Add'in dönüş değeri sınırı kesin kılar.
	if p.buffered.Add(1) > p.maxBuf {
		p.buffered.Add(-1)
		p.m.Records.WithLabelValues("dropped").Inc()
		return
	}
	p.m.Buffered.Set(float64(p.buffered.Load()))
	ev := NewClickEvent(code)
	val, err := ev.Marshal()
	if err != nil {
		p.buffered.Add(-1)
		p.m.Buffered.Set(float64(p.buffered.Load()))
		p.m.Records.WithLabelValues("error").Inc()
		return
	}
	start := time.Now()
	// Anahtar = kısa kod: aynı linkin olayları aynı partition'a gider, yani SIRA korunur.
	// Bedeli: sıcak bir link tek partition'a yüklenir (P06-03 ile aynı madalyonun iki yüzü).
	// TryProduce, Produce'un aksine istemcinin tamponu doluyken BEKLEMEZ: hemen ErrMaxBuffered döner.
	p.cl.TryProduce(context.Background(), &kgo.Record{Key: []byte(code), Value: val},
		func(_ *kgo.Record, err error) {
			p.buffered.Add(-1)
			p.m.Buffered.Set(float64(p.buffered.Load()))
			if errors.Is(err, kgo.ErrMaxBuffered) {
				p.m.Records.WithLabelValues("dropped").Inc()
				return
			}
			p.m.Latency.Observe(time.Since(start).Seconds())
			if err != nil {
				p.m.Records.WithLabelValues("error").Inc()
				return
			}
			p.m.Records.WithLabelValues("ok").Inc()
		})
}

// Flush — kapanışta tampondakileri gönder. 05'teki drain'in karşılığı.
func (p *Producer) Flush(ctx context.Context) error { return p.cl.Flush(ctx) }
func (p *Producer) Close()                          { p.cl.Close() }
func (p *Producer) Buffered() int64                 { return p.buffered.Load() }
