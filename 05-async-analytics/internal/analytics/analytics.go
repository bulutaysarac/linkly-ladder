// Package analytics — tıklamaları istek yolundan çıkaran sınırlı kuyruk + toplu yazıcı.
//
// EN: Level 02 measured what a synchronous counter costs: every redirect took a row lock on the
//
//	hottest row in the database (P02-08). The fix is not a faster UPDATE, it is removing the write
//	from the read path entirely. What you buy with is a delivery guarantee: this queue is
//	AT-MOST-ONCE. A full queue drops clicks; a crash loses whatever was buffered. Correct for
//	counters, wrong for billing — and the README says so out loud.
//
// TR: 02, senkron bir sayacın bedelini ölçtü: her redirect, veritabanının en sıcak satırında bir
//
//	satır kilidi alıyordu (P02-08). Çözüm daha hızlı bir UPDATE değil, yazmayı okuma yolundan
//	TAMAMEN çıkarmak. Karşılığında bir teslimat garantisi ödüyorsun: bu kuyruk EN FAZLA BİR KEZ.
//	Dolu kuyruk tıklama düşürür; çökme, tamponda ne varsa kaybeder. Sayaç için doğru, faturalama
//	için yanlış — ve README bunu açıkça söylüyor.
//
// [Topic · Konu: Asenkronizm, back pressure, teslimat garantisi]
package analytics

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

type Event struct {
	Code string
	At   time.Time
}

type Metrics struct {
	Events   *prometheus.CounterVec // result
	Depth    prometheus.Gauge
	Capacity prometheus.Gauge
	Batch    prometheus.Histogram
	BatchSz  prometheus.Histogram
}

func NewMetrics(reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		Events: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "analytics_events_total", Help: "Tıklama olayı"}, []string{"result"}),
		Depth: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "analytics_queue_depth", Help: "Kuyruktaki olay"}),
		Capacity: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "analytics_queue_capacity", Help: "Kuyruk kapasitesi"}),
		Batch: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "analytics_batch_duration_seconds", Help: "Toplu yazma süresi",
			Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1, 2.5}}),
		BatchSz: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "analytics_batch_size", Help: "Toplu yazma boyutu",
			Buckets: []float64{1, 5, 10, 25, 50, 100, 250, 500, 1000}}),
	}
	reg.MustRegister(m.Events, m.Depth, m.Capacity, m.Batch, m.BatchSz)
	for _, r := range []string{"enqueued", "dropped", "written", "write_error"} {
		m.Events.WithLabelValues(r)
	}
	return m
}

type Writer interface {
	WriteClicks(ctx context.Context, counts map[string]int64) error
}

type Config struct {
	QueueSize     int
	BatchSize     int
	FlushInterval time.Duration
	WriteTimeout  time.Duration
	Unbounded     bool // TRAP: sınırsız kuyruk
}

type Collector struct {
	cfg  Config
	ch   chan Event
	w    Writer
	m    *Metrics
	log  *slog.Logger
	wg   sync.WaitGroup
	done chan struct{}

	// Sınırsız mod (TRAP): kanal yerine büyüyen bir dilim.
	mu        sync.Mutex
	unbounded []Event
}

func New(cfg Config, w Writer, m *Metrics, log *slog.Logger) *Collector {
	if cfg.QueueSize <= 0 {
		cfg.QueueSize = 10000
	}
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = 200
	}
	if cfg.FlushInterval <= 0 {
		cfg.FlushInterval = time.Second
	}
	c := &Collector{cfg: cfg, ch: make(chan Event, cfg.QueueSize), w: w, m: m, log: log, done: make(chan struct{})}
	m.Capacity.Set(float64(cfg.QueueSize))
	return c
}

// Record — istek yolundan çağrılır ve ASLA bloklamaz.
//
// EN: The whole design rests on this one property. A blocking send would make the redirect wait for
//
//	the database again — the exact problem we are removing — and would do it invisibly, only under
//	load. When the queue is full we DROP and count the drop. A drop you can see is a decision;
//	a block you cannot see is an outage waiting for traffic.
//
// TR: Bütün tasarım bu tek özelliğe dayanıyor. Bloklayan bir gönderim, redirect'i yine veritabanını
//
//	beklemeye zorlardı — tam da kaldırdığımız sorun — üstelik bunu görünmez biçimde, yalnızca yük
//	altında yapardı. Kuyruk dolduğunda DÜŞÜRÜYORUZ ve düşürmeyi sayıyoruz. Gördüğün bir düşüş bir
//	karardır; göremediğin bir bloklama, trafiği bekleyen bir kesintidir.
//
// [Topic · Konu: Back pressure, bounded queue]
func (c *Collector) Record(code string) {
	e := Event{Code: code, At: time.Now()}
	if c.cfg.Unbounded {
		// TRAP_UNBOUNDED_QUEUE: sınırsız kuyruk bir emniyet ağı değil, ertelenmiş bir çöküştür.
		// Kuyruk belleği aşar, süreç OOM olur ve tampondaki HER ŞEY kaybolur — yani "hiç düşürme"
		// isteği, sonunda her şeyi düşürmekle sonuçlanır.
		c.mu.Lock()
		c.unbounded = append(c.unbounded, e)
		depth := len(c.unbounded)
		c.mu.Unlock()
		c.m.Events.WithLabelValues("enqueued").Inc()
		c.m.Depth.Set(float64(depth))
		return
	}
	select {
	case c.ch <- e:
		c.m.Events.WithLabelValues("enqueued").Inc()
		c.m.Depth.Set(float64(len(c.ch)))
	default:
		c.m.Events.WithLabelValues("dropped").Inc()
	}
}

func (c *Collector) Start() {
	c.wg.Add(1)
	go c.loop()
}

func (c *Collector) loop() {
	defer c.wg.Done()
	ticker := time.NewTicker(c.cfg.FlushInterval)
	defer ticker.Stop()

	// EN: Aggregate before writing. A thousand clicks on the same code become ONE row update, not a
	//     thousand. This is what turns the hot-row lock contention of P02-08 into a non-issue: the
	//     hotter the key, the better the aggregation ratio.
	// TR: Yazmadan önce topla. Aynı koda gelen bin tıklama, bin değil TEK satır güncellemesi olur.
	//     P02-08'deki sıcak satır kilidini sorun olmaktan çıkaran şey bu: anahtar ne kadar sıcaksa
	//     toplama oranı o kadar iyi.
	// Kapasite ipucu YOK: parti OLAY sayısıyla sınırlanır (BatchSize) ama harita KOD sayısı kadar büyür —
	// sıcak bir anahtarda bir avuç. Olay sayısı kadar yer ayırmak belleği boşa harcar; büyük bir parti
	// boyunda (ör. yazmayı fiilen durdurmak için 100 milyon, P05-03) pod'u ilk satırda OOM'a götürür.
	// EN: no capacity hint — the batch is bounded by EVENTS but the map grows with distinct CODES.
	batch := map[string]int64{}
	n := 0
	flush := func() {
		if n == 0 {
			return
		}
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), c.cfg.WriteTimeout)
		err := c.w.WriteClicks(ctx, batch)
		cancel()
		c.m.Batch.Observe(time.Since(start).Seconds())
		c.m.BatchSz.Observe(float64(n))
		if err != nil {
			c.m.Events.WithLabelValues("write_error").Add(float64(n))
			c.log.Warn("tıklama toplu yazımı başarısız", "err", err, "events", n)
		} else {
			c.m.Events.WithLabelValues("written").Add(float64(n))
		}
		batch = map[string]int64{}
		n = 0
	}

	for {
		select {
		case <-c.done:
			c.drain(&batch, &n, flush)
			return
		case e := <-c.ch:
			batch[e.Code]++
			n++
			c.m.Depth.Set(float64(len(c.ch)))
			if n >= c.cfg.BatchSize {
				flush()
			}
		case <-ticker.C:
			if c.cfg.Unbounded {
				c.mu.Lock()
				pending := c.unbounded
				c.unbounded = nil
				c.mu.Unlock()
				for _, e := range pending {
					batch[e.Code]++
					n++
				}
				c.m.Depth.Set(0)
			}
			flush()
		}
	}
}

// drain — kapanışta kuyrukta kalanları yaz.
// EN: This is the difference between "we lose a second of clicks on every deploy" and "we don't".
//
//	It only works if the process is actually given time to run it: see terminationGracePeriodSeconds
//	and the shutdown ORDER in main.go. A drain nobody waits for is decoration.
//
// TR: "Her dağıtımda bir saniyelik tıklama kaybediyoruz" ile "kaybetmiyoruz" arasındaki fark bu.
//
//	Yalnızca sürece bunu çalıştıracak zaman verilirse işe yarar: terminationGracePeriodSeconds ve
//	main.go'daki kapatma SIRASI. Kimsenin beklemediği bir drain, süstür.
func (c *Collector) drain(batch *map[string]int64, n *int, flush func()) {
	for {
		select {
		case e := <-c.ch:
			(*batch)[e.Code]++
			*n++
			if *n >= c.cfg.BatchSize {
				flush()
			}
		default:
			if c.cfg.Unbounded {
				c.mu.Lock()
				for _, e := range c.unbounded {
					(*batch)[e.Code]++
					*n++
				}
				c.unbounded = nil
				c.mu.Unlock()
			}
			flush()
			return
		}
	}
}

func (c *Collector) Stop() {
	close(c.done)
	c.wg.Wait()
}

func (c *Collector) Depth() int {
	if c.cfg.Unbounded {
		c.mu.Lock()
		defer c.mu.Unlock()
		return len(c.unbounded)
	}
	return len(c.ch)
}
