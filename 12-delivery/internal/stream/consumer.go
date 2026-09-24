package stream

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"time"

	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/tracing"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

// batchParent — partinin span'ine ebeveyn olacak üretici bağlamı.
//
// EN: A batch has many parents and a span has one. It is the first record whose producer was
//
//	SAMPLED: with 5% head sampling the first record is almost never from a sampled request,
//	and a ParentBased sampler would then drop the batch span — the traces that WERE sampled
//	would never be joined to their consumer side. If no producer was sampled, the (unsampled)
//	first context is used and the batch is correctly not recorded. No header at all (the P11-02
//	trap) → a fresh root: an orphan trace, sampled at 5% on its own.
//
// TR: Bir partinin çok ebeveyni, bir span'in tek ebeveyni vardır. Ebeveyn, üreticisi ÖRNEKLENMİŞ
//
//	ilk kayıttır: %5 head sampling'de ilk kayıt neredeyse hiç örneklenmiş bir istekten gelmez;
//	ParentBased sampler o zaman parti span'ini düşürür ve ÖRNEKLENMİŞ trace'ler tüketici yakasına
//	hiç bağlanmaz. Hiçbir üretici örneklenmemişse (örneklenmemiş) ilk bağlam kullanılır ve parti
//	doğru biçimde kaydedilmez. Hiç header yoksa (P11-02 tuzağı) → yeni bir kök: kendi başına %5
//	örneklenen, yetim bir trace.
func batchParent(ctx context.Context, recs []*kgo.Record) context.Context {
	prop := otel.GetTextMapPropagator()
	var first context.Context
	for _, r := range recs {
		c := prop.Extract(ctx, kafkaHeaderCarrier{rec: r})
		sc := trace.SpanContextFromContext(c)
		if !sc.IsValid() {
			continue
		}
		if sc.IsSampled() {
			return c
		}
		if first == nil {
			first = c
		}
	}
	if first != nil {
		return first
	}
	return ctx
}

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
	// TRAP: bozuk mesaj için çıkış yolu yok → tüketici aynı partide takılır, offset ilerlemez,
	// lag sınırsız büyür (P06-04).
	NoDLQ bool
	// TRAP: yazma ile offset commit'i arasına bekleme koy. Varsayılan sırada (yaz → commit)
	// "yazıldı, commit edilmedi" penceresini (P06-01), TRAP_COMMIT_BEFORE_WRITE ile (commit → yaz)
	// "commit edildi, yazılmadı" penceresini (P06-06) vurulabilir kılar. 0 = bekleme yok (varsayılan).
	CommitDelay time.Duration
}

// kafkaClient — tüketicinin kullandığı *kgo.Client yüzeyi. Commit davranışı broker olmadan
// sınanabilsin diye arayüz: test, neyin ne zaman commit edildiğini kaydeden sahte bir istemci verir.
type kafkaClient interface {
	PollFetches(context.Context) kgo.Fetches
	CommitUncommittedOffsets(context.Context) error
	Produce(context.Context, *kgo.Record, func(*kgo.Record, error))
	Close()
}

// maxWriteRetry — başarısız partiyi yeniden deneme aralığının tavanı (geri çekilme bunu aşmaz).
const maxWriteRetry = 10 * time.Second

type Consumer struct {
	cl   kafkaClient
	cfg  ConsumerConfig
	sink Sink
	m    *ConsumerMetrics
	log  *slog.Logger
	// poisonRetry — TRAP_NO_DLQ'da aynı bozuk partiyi yeniden deneme aralığı (testte kısaltılır).
	poisonRetry time.Duration
	// writeRetry — yazılamayan partiyi ilk yeniden deneme aralığı; her denemede ikiye katlanır
	// (tavan maxWriteRetry). Testte kısaltılır.
	writeRetry time.Duration
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
	return &Consumer{cl: cl, cfg: cfg, sink: sink, m: m, log: log,
		poisonRetry: time.Second, writeRetry: 250 * time.Millisecond}, nil
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
		// Üreticinin koyduğu bağlamı çıkar: bu partinin span'i, onu üreten isteğin ÇOCUĞU olur.
		batchCtx, span := tracing.StartKind(batchParent(ctx, fetches.Records()), "consume-batch",
			trace.SpanKindConsumer,
			attribute.String("messaging.system", "kafka"),
			attribute.Int("messaging.batch.message_count", fetches.NumRecords()))

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

		if len(poison) > 0 && !c.handlePoison(ctx, poison) {
			// TRAP_NO_DLQ: handlePoison yalnızca kapanışta döner; bu partiyi ne yazdık ne commit ettik.
			span.End()
			return nil
		}

		if c.cfg.CommitBeforeWrite {
			// TRAP: önce commit → yazma başarısız olursa o kayıtlar bir daha GELMEZ (veri kaybı).
			if err := c.cl.CommitUncommittedOffsets(ctx); err == nil {
				c.m.Commits.Inc()
			}
			// "Commit edildi, henüz yazılmadı": bu aralıkta ölen tüketici partiyi KAYBEDER (P06-06).
			c.holdCommitGap(ctx)
		}

		if len(ids) > 0 {
			applied, err := c.writeBatch(batchCtx, counts, ids)
			if err != nil {
				// Span'i BİTİR: bitmeyen span hiç gönderilmez — trace'te en çok görmek istediğin
				// parti (yazılamayan) kaybolurdu.
				tracing.EndErr(span, err)
				if ctx.Err() != nil {
					// Kapanış: parti yazılmadı ve (varsayılan sırada) commit de edilmedi — yeniden
					// başlayan tüketici aynı kayıtları commit edilmiş offset'ten tekrar okur.
					return nil
				}
				// Yalnızca TRAP_COMMIT_BEFORE_WRITE buraya düşer: offset zaten commit edildi.
				c.log.Error("parti yazılamadı ve offset'i ZATEN commit edildi — bu kayıtlar KAYBOLDU",
					"err", err, "records", len(ids))
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

		span.End()
		if !c.cfg.CommitBeforeWrite {
			// "Yazıldı, henüz commit edilmedi": bu aralıkta ölen tüketicinin partisi TEKRAR gelir (P06-01).
			c.holdCommitGap(ctx)
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

// writeBatch — partiyi yaz. Offset'i commit edilmemiş bir parti, yazılana kadar YERİNDE yeniden
// denenir; hata yalnızca kapanışta ya da TRAP_COMMIT_BEFORE_WRITE'ta döner.
//
// EN: CommitUncommittedOffsets commits everything polled so far. A consumer that skips a failed
//
//	batch and polls on commits PAST it with the next good batch, and those records are never read
//	again: at-least-once turns into at-most-once for exactly the batches that met a database
//	error. So the consumer never polls past a batch it has not written. It retries the same batch
//	in place with capped exponential backoff and the offset stays put until the write succeeds;
//	a restart meanwhile re-reads the batch from the committed offset, and the idempotent write
//	absorbs any repeat. Under TRAP_COMMIT_BEFORE_WRITE the offset is committed before the write,
//	so there is nothing left to protect: one attempt, and a failure is a loss — that is the trap.
//
// TR: CommitUncommittedOffsets o ana kadar okunan HER ŞEYİ commit eder. Başarısız partiyi atlayıp
//
//	okumaya devam eden tüketici, sonraki sağlam partiyle onun ÖTESİNİ commit eder ve o kayıtlar bir
//	daha okunmaz: en-az-bir-kez, tam da veritabanı hatasına denk gelen partiler için en-fazla-bir-
//	kez'e döner. Bu yüzden tüketici yazmadığı bir partinin ötesini okumaz: aynı partiyi yerinde,
//	tavanlı üstel geri çekilmeyle yeniden dener; yazma başarılı olana kadar offset yerinde kalır.
//	Bu arada yeniden başlarsa parti commit edilmiş offset'ten tekrar okunur ve idempotent yazma
//	tekrarı emer. TRAP_COMMIT_BEFORE_WRITE'ta offset yazmadan ÖNCE commit edilmiştir, korunacak
//	bir şey kalmaz: tek deneme, başarısızlık kayıptır — tuzak da budur.
//
// [Topic · Konu: Teslimat garantisi, yeniden deneme]
func (c *Consumer) writeBatch(ctx context.Context, counts map[string]int64, ids []string) (int, error) {
	backoff := c.writeRetry
	for {
		wctx, cancel := context.WithTimeout(ctx, c.cfg.WriteTimeout)
		applied, err := c.sink.WriteClicksIdempotent(wctx, counts, ids)
		cancel()
		if err == nil {
			return applied, nil
		}
		c.m.Records.WithLabelValues("error").Add(float64(len(ids)))
		if c.cfg.CommitBeforeWrite || ctx.Err() != nil {
			return 0, err
		}
		c.log.Warn("parti yazılamadı, commit EDİLMİYOR — aynı parti yeniden denenecek",
			"err", err, "records", len(ids), "retry_in", backoff)
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-time.After(backoff):
		}
		backoff = min(2*backoff, maxWriteRetry)
	}
}

// holdCommitGap — TRAP_COMMIT_DELAY_MS: yazma ile commit arasındaki boşluğu GENİŞLET.
//
// EN: Every consumer has a gap between writing a batch and committing its offset; left alone it
//
//	is the few milliseconds of one commit, and a backlog is fetched in one poll, so no externally
//	timed kill can land inside it. The delay keeps the ORDER of the two steps and only holds the
//	gap open long enough to hit on purpose: write → commit shows redelivery (P06-01),
//	commit → write shows loss (P06-06). It does not change the guarantee.
//
// TR: Her tüketicide parti yazmak ile offset'ini commit etmek arasında bir boşluk vardır; kendi
//
//	hâlinde tek bir commit'in birkaç milisaniyesidir ve birikim tek poll'da okunur, yani dışarıdan
//	zamanlanan hiçbir öldürme içine denk gelemez. Gecikme iki adımın SIRASINI korur, yalnızca
//	boşluğu bilerek vurulabilecek kadar açık tutar: yaz → commit tekrar teslimi (P06-01),
//	commit → yaz kaybı (P06-06) gösterir. Garantiyi değiştirmez.
func (c *Consumer) holdCommitGap(ctx context.Context) {
	if c.cfg.CommitDelay <= 0 {
		return
	}
	select {
	case <-ctx.Done():
	case <-time.After(c.cfg.CommitDelay):
	}
}

// handlePoison — ayrıştırılamayan mesaj. false dönerse tüketici bu partinin ÖTESİNE GEÇMEMELİ.
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
func (c *Consumer) handlePoison(ctx context.Context, recs []*kgo.Record) bool {
	if c.cfg.NoDLQ {
		// TRAP_NO_DLQ: çıkış yolu YOK — "hata ver, sonra tekrar dene".
		// EN: counting the record as `error` and moving on would be a skip, i.e. an exit path: the
		//     pipeline would never stall and P06-04 could not show what it claims.
		//     Without an exit path the batch is retried: nothing is written, nothing is committed,
		//     and the consumer never polls past this record. Retrying in place is what redelivery
		//     looks like from inside one process — a restart re-reads the same record from the
		//     committed offset and ends up here again. It also must not `continue` to the next
		//     poll: CommitUncommittedOffsets commits everything polled so far, so the next good
		//     batch would silently commit PAST the poison record — skipping it after all.
		// TR: kaydı `error` sayıp geçmek bir atlama, yani bir çıkış yolu olurdu — boru hattı hiç
		//     durmaz ve P06-04 iddia ettiği şeyi gösteremezdi. Çıkış yolu yoksa parti yeniden
		//     denenir: hiçbir şey yazılmaz, hiçbir şey commit edilmez ve tüketici bu kaydın
		//     ötesini hiç okumaz. Yerinde yeniden denemek, tek bir sürecin içinden bakınca
		//     yeniden teslimin ta kendisidir — yeniden başlatma aynı kaydı commit edilmiş
		//     offset'ten tekrar okur ve yine buraya gelir. `continue` ile sonraki poll'a da
		//     GEÇMEMELİ: CommitUncommittedOffsets o ana kadar okunan her şeyi commit eder, yani
		//     sonraki sağlam parti bozuk kaydın ÖTESİNİ sessizce commit ederdi — yine atlamış olurduk.
		for {
			c.m.Records.WithLabelValues("error").Add(float64(len(recs)))
			c.log.Error("bozuk mesaj ve DLQ kapalı: parti yeniden deneniyor, offset İLERLEMİYOR",
				"count", len(recs), "partition", recs[0].Partition, "offset", recs[0].Offset)
			select {
			case <-ctx.Done():
				return false
			case <-time.After(c.poisonRetry):
				// Bozuk kayıt her denemede AYNI biçimde bozuktur: yeniden denemek hiçbir şeyi değiştirmez.
			}
		}
	}
	for _, r := range recs {
		c.cl.Produce(ctx, &kgo.Record{Topic: c.cfg.DLQTopic, Key: r.Key, Value: r.Value}, nil)
	}
	c.m.Records.WithLabelValues("dlq").Add(float64(len(recs)))
	c.log.Warn("bozuk mesaj DLQ'ya taşındı", "count", len(recs), "topic", c.cfg.DLQTopic)
	return true
}

func (c *Consumer) Close() { c.cl.Close() }
