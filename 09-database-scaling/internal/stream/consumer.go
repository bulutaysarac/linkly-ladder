package stream

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/twmb/franz-go/pkg/kgo"
)

type ConsumerMetrics struct {
	Records *prometheus.CounterVec // result
	Commits prometheus.Counter
	Batch   prometheus.Histogram
	Lag     prometheus.Gauge
}

func NewConsumerMetrics(reg prometheus.Registerer) *ConsumerMetrics {
	m := &ConsumerMetrics{
		Records: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "consumer_records_total", Help: "Tüketilen kayıt"}, []string{"result"}),
		Commits: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "consumer_commits_total", Help: "Offset commit"}),
		Batch: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "consumer_batch_duration_seconds", Help: "Parti işleme süresi",
			Buckets: []float64{.001, .005, .01, .05, .1, .5, 1, 2.5, 5}}),
		Lag: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "consumer_lag_estimate", Help: "Tahmini gecikme (son kayıt yaşı, sn)"}),
	}
	reg.MustRegister(m.Records, m.Commits, m.Batch, m.Lag)
	for _, r := range []string{"ok", "duplicate", "dlq", "error", "unknown_version"} {
		m.Records.WithLabelValues(r)
	}
	return m
}

type Sink interface {
	// WriteClicksIdempotent — parti + görülen olay kimlikleri. Tekrar işlenirse ÇİFT SAYMAMALI.
	WriteClicksIdempotent(ctx context.Context, counts map[string]int64, eventIDs []string) (applied int, err error)
}

type ConsumerConfig struct {
	Brokers      []string
	Topic        string
	DLQTopic     string
	Group        string
	BatchTimeout time.Duration
	WriteTimeout time.Duration
	// TRAP: commit'i yazmadan ÖNCE yap → en fazla bir kez, tüketici ölürse veri kaybı.
	CommitBeforeWrite bool
	// TRAP: bozuk mesajı DLQ'ya göndermek yerine hata verip dur → crashloop, sonsuz lag.
	NoDLQ bool
}

type Consumer struct {
	cl   *kgo.Client
	cfg  ConsumerConfig
	sink Sink
	m    *ConsumerMetrics
	log  *slog.Logger
}

func NewConsumer(cfg ConsumerConfig, sink Sink, m *ConsumerMetrics, log *slog.Logger) (*Consumer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ConsumeTopics(cfg.Topic),
		kgo.ConsumerGroup(cfg.Group),
		// EN: Manual commits. Auto-commit would commit on a timer regardless of whether the batch
		//     was written, which silently turns at-least-once into at-most-once and loses data on
		//     every rebalance. The commit point IS the delivery guarantee — never let a library
		//     default decide it for you.
		// TR: Elle commit. Otomatik commit, parti yazıldı mı yazılmadı mı bakmaksızın zamanlayıcıyla
		//     commit eder; bu, en-az-bir-kez'i sessizce en-fazla-bir-kez'e çevirir ve her yeniden
		//     dengelemede veri kaybettirir. Commit NOKTASI teslimat garantisinin ta kendisidir —
		//     bunu bir kütüphane varsayılanına bırakma.
		// [Topic · Konu: Teslimat garantisi, commit noktası]
		kgo.DisableAutoCommit(),
		kgo.FetchMaxWait(cfg.BatchTimeout),
	)
	if err != nil {
		return nil, err
	}
	return &Consumer{cl: cl, cfg: cfg, sink: sink, m: m, log: log}, nil
}

func (c *Consumer) Run(ctx context.Context) error {
	for {
		if ctx.Err() != nil {
			return nil
		}
		fetches := c.cl.PollFetches(ctx)
		if errs := fetches.Errors(); len(errs) > 0 {
			for _, e := range errs {
				if errors.Is(e.Err, context.Canceled) {
					return nil
				}
				c.log.Warn("fetch hatası", "topic", e.Topic, "partition", e.Partition, "err", e.Err)
			}
			continue
		}
		if fetches.NumRecords() == 0 {
			continue
		}
		start := time.Now()

		counts := map[string]int64{}
		ids := make([]string, 0, fetches.NumRecords())
		var poison []*kgo.Record
		var newest time.Time

		fetches.EachRecord(func(r *kgo.Record) {
			var ev ClickEvent
			if err := json.Unmarshal(r.Value, &ev); err != nil || ev.Code == "" {
				poison = append(poison, r)
				return
			}
			if ev.Version > CurrentVersion {
				// Bilinmeyen (ileri) sürüm: ATLA ama SAY. Patlamak, tek bir yeni alan yüzünden
				// tüm tüketiciyi durdurmak demektir (P06-07).
				c.m.Records.WithLabelValues("unknown_version").Inc()
				return
			}
			counts[ev.Code]++
			ids = append(ids, ev.EventID)
			if ev.At.After(newest) {
				newest = ev.At
			}
		})

		if len(poison) > 0 {
			c.handlePoison(ctx, poison)
		}

		if c.cfg.CommitBeforeWrite {
			// TRAP: önce commit → yazma başarısız olursa o kayıtlar bir daha GELMEZ (veri kaybı).
			if err := c.cl.CommitUncommittedOffsets(ctx); err == nil {
				c.m.Commits.Inc()
			}
		}

		if len(ids) > 0 {
			wctx, cancel := context.WithTimeout(ctx, c.cfg.WriteTimeout)
			applied, err := c.sink.WriteClicksIdempotent(wctx, counts, ids)
			cancel()
			if err != nil {
				c.m.Records.WithLabelValues("error").Add(float64(len(ids)))
				c.log.Warn("parti yazılamadı, commit EDİLMİYOR — kayıtlar tekrar gelecek",
					"err", err, "records", len(ids))
				// Commit YOK: aynı kayıtlar yeniden teslim edilir. En az bir kez'in bedeli ve faydası.
				continue
			}
			c.m.Records.WithLabelValues("ok").Add(float64(applied))
			if dup := len(ids) - applied; dup > 0 {
				// Tekrar teslim edilmiş ama daha önce uygulanmış olaylar: idempotency çalıştı.
				c.m.Records.WithLabelValues("duplicate").Add(float64(dup))
			}
		}

		if !newest.IsZero() {
			c.m.Lag.Set(time.Since(newest).Seconds())
		}
		c.m.Batch.Observe(time.Since(start).Seconds())

		if !c.cfg.CommitBeforeWrite {
			// DOĞRU SIRA: yaz, sonra commit. Arada ölürsen kayıtlar tekrar gelir (en az bir kez)
			// ve idempotency çift saymayı engeller.
			if err := c.cl.CommitUncommittedOffsets(ctx); err != nil {
				c.log.Warn("commit başarısız", "err", err)
				continue
			}
			c.m.Commits.Inc()
		}
	}
}

// handlePoison — ayrıştırılamayan mesaj.
//
// EN: A message the consumer cannot parse will be redelivered forever if you just fail: the offset
//
//	never advances, lag grows without bound, and one malformed record stops all analytics. A dead
//	letter topic turns an unbounded outage into a bounded, inspectable one.
//
// TR: Tüketicinin ayrıştıramadığı bir mesaj, sadece hata verirsen sonsuza dek yeniden teslim edilir:
//
//	offset ilerlemez, lag sınırsız büyür ve tek bir bozuk kayıt tüm analitiği durdurur. Ölü mektup
//	topic'i, sınırsız bir kesintiyi sınırlı ve incelenebilir bir olaya çevirir.
//
// [Topic · Konu: Poison message, DLQ]
func (c *Consumer) handlePoison(ctx context.Context, recs []*kgo.Record) {
	if c.cfg.NoDLQ {
		// TRAP: DLQ yok → kayıtları atlamak yerine sayıp geçiyoruz ama gerçek "kötü" davranış
		// (patlayıp durmak) TRAP_POISON_FATAL ile tetikleniyor; burada en azından görünür kılıyoruz.
		c.m.Records.WithLabelValues("error").Add(float64(len(recs)))
		c.log.Error("bozuk mesaj ve DLQ kapalı", "count", len(recs))
		return
	}
	for _, r := range recs {
		c.cl.Produce(ctx, &kgo.Record{Topic: c.cfg.DLQTopic, Key: r.Key, Value: r.Value}, nil)
	}
	c.m.Records.WithLabelValues("dlq").Add(float64(len(recs)))
	c.log.Warn("bozuk mesaj DLQ'ya taşındı", "count", len(recs), "topic", c.cfg.DLQTopic)
}

func (c *Consumer) Close() { c.cl.Close() }
