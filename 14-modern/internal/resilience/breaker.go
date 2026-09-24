// Package resilience — devre kesici, bulkhead, retry ve yük atma.
//
// EN: Everything in this package answers one question: when a dependency is partially broken,
//
//	how does the system stay PARTIALLY working instead of fully broken? Each mechanism has a
//	different job and none substitutes for another:
//	  timeout   — stop waiting          (bounds one request)
//	  retry     — try again, carefully  (recovers from transient loss)
//	  breaker   — stop asking           (protects the dependency and yourself from waiting)
//	  bulkhead  — limit how many ask    (stops one dependency from eating all your goroutines)
//	  shedding  — refuse early, cheaply (keeps accepted requests fast)
//
// TR: Bu paketteki her şey tek bir soruya cevap veriyor: bir bağımlılık KISMEN bozulduğunda,
//
//	sistem tamamen bozulmak yerine nasıl KISMEN çalışır kalır? Her mekanizmanın işi farklı ve
//	hiçbiri diğerinin yerine geçmez:
//	  timeout   — beklemeyi bırak        (tek isteği sınırlar)
//	  retry     — dikkatlice tekrar dene (geçici kayıptan kurtarır)
//	  breaker   — sormayı bırak          (hem bağımlılığı hem seni beklemekten korur)
//	  bulkhead  — kaç kişi sorsun        (bir bağımlılığın tüm goroutine'lerini yemesini engeller)
//	  shedding  — erken ve ucuz reddet   (kabul edilenleri hızlı tutar)
//
// [Topic · Konu: Dayanıklılık desenleri]
package resilience

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"

	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/tracing"
	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/otel/attribute"
)

var (
	ErrOpen     = errors.New("devre açık: bağımlılığa istek gönderilmiyor")
	ErrBulkhead = errors.New("bulkhead dolu: bu bağımlılık için eşzamanlılık sınırına ulaşıldı")
	ErrShed     = errors.New("yük atıldı: sunucu kapasitesinin üzerinde")
)

type State int

const (
	Closed State = iota
	Open
	HalfOpen
)

func (s State) String() string {
	switch s {
	case Open:
		return "open"
	case HalfOpen:
		return "half_open"
	default:
		return "closed"
	}
}

type Metrics struct {
	BreakerState *prometheus.GaugeVec   // dep
	Requests     *prometheus.CounterVec // dep, result
	Duration     *prometheus.HistogramVec
	Retries      *prometheus.CounterVec // dep
	Shed         prometheus.Counter
	Degraded     *prometheus.GaugeVec // mode
}

func NewMetrics(reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		BreakerState: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "breaker_state", Help: "0 kapalı · 1 yarı açık · 2 açık"}, []string{"dep"}),
		Requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "dependency_requests_total", Help: "Bağımlılık çağrısı"}, []string{"dep", "result"}),
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "dependency_request_duration_seconds", Help: "Bağımlılık çağrı süresi",
			Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5}}, []string{"dep"}),
		Retries: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "retry_total", Help: "Yeniden deneme"}, []string{"dep"}),
		Shed: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "load_shed_total", Help: "Erken reddedilen istek"}),
		Degraded: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "degraded_mode", Help: "1 = bu degrade modu aktif"}, []string{"mode"}),
	}
	reg.MustRegister(m.BreakerState, m.Requests, m.Duration, m.Retries, m.Shed, m.Degraded)
	for _, d := range []string{"postgres", "redis", "kafka"} {
		m.BreakerState.WithLabelValues(d)
		for _, r := range []string{"ok", "error", "open", "bulkhead", "timeout"} {
			m.Requests.WithLabelValues(d, r)
		}
		m.Retries.WithLabelValues(d)
	}
	// cache_only: Postgres devresi açık → yalnızca önbellek isabetleri cevaplanır.
	// no_cache:   Redis devresi açık → önbellek atlanır, okumalar doğrudan veritabanından.
	for _, mode := range []string{"cache_only", "no_cache", "no_analytics", "read_only"} {
		m.Degraded.WithLabelValues(mode)
	}
	return m
}

type Config struct {
	Name             string
	FailureThreshold int           // ardışık hata sayısı → aç
	OpenDuration     time.Duration // açık kalma süresi
	HalfOpenProbes   int           // yarı açıkken kaç deneme
	MaxConcurrent    int           // bulkhead
	Timeout          time.Duration
	MaxRetries       int
	RetryBudget      float64 // toplam isteğin en fazla bu oranı retry olabilir
}

// Guard — tek bir bağımlılığı koruyan kombinasyon.
type Guard struct {
	cfg Config
	m   *Metrics

	mu          sync.Mutex
	state       State
	failures    int
	openedAt    time.Time
	halfOpenCnt int

	sem chan struct{}

	// retry bütçesi: son pencerede kaç istek, kaç retry
	rmu      sync.Mutex
	reqCount int64
	retCount int64
	winStart time.Time
}

func NewGuard(cfg Config, m *Metrics) *Guard {
	if cfg.MaxConcurrent <= 0 {
		cfg.MaxConcurrent = 32
	}
	if cfg.FailureThreshold <= 0 {
		cfg.FailureThreshold = 5
	}
	if cfg.OpenDuration <= 0 {
		cfg.OpenDuration = 5 * time.Second
	}
	if cfg.HalfOpenProbes <= 0 {
		cfg.HalfOpenProbes = 2
	}
	if cfg.RetryBudget <= 0 {
		cfg.RetryBudget = 0.1
	}
	g := &Guard{cfg: cfg, m: m, sem: make(chan struct{}, cfg.MaxConcurrent), winStart: time.Now()}
	m.BreakerState.WithLabelValues(cfg.Name).Set(0)
	return g
}

// Do — korumalı çağrı.
//
// 11: her çağrı bir "guard.<dep>" span'i açar; bağımlılığa giden her deneme (retry dahil) onun
// ÇOCUĞU olur. Reddedilen çağrıda (devre açık / bulkhead dolu) span'in çocuğu yoktur ve
// `guard.attempts=0` taşır: "bağımlılık yavaş" ile "biz sormadık" trace'te ayrılır.
// EN: retries and refusals become visible per request — the question P10-01/P10-03 could only
// answer in aggregate.
func (g *Guard) Do(ctx context.Context, fn func(context.Context) error) error {
	ctx, span := tracing.Start(ctx, "guard."+g.cfg.Name, attribute.String("dep", g.cfg.Name))
	attempts := 0
	err := g.do(ctx, func(ctx context.Context) error { attempts++; return fn(ctx) })
	span.SetAttributes(attribute.Int("guard.attempts", attempts))
	tracing.EndErr(span, err)
	return err
}

func (g *Guard) do(ctx context.Context, fn func(context.Context) error) error {
	if !g.allowRequest() {
		g.m.Requests.WithLabelValues(g.cfg.Name, "open").Inc()
		return ErrOpen
	}

	// Bulkhead: bu bağımlılık için eşzamanlı çağrı sayısını sınırla.
	// EN: Without this, a slow dependency converts every incoming request into a blocked goroutine
	//     until memory runs out — the failure mode measured at P10-05. A bulkhead makes the damage
	//     bounded and, crucially, LOCAL: Redis being slow must not consume the capacity that
	//     Postgres calls need.
	// TR: Bu olmadan yavaş bir bağımlılık, gelen her isteği bellek bitene kadar bloke bir
	//     goroutine'e çevirir — P10-05'te ölçülen arıza biçimi. Bulkhead hasarı SINIRLI ve daha
	//     önemlisi YEREL yapar: Redis'in yavaşlaması, Postgres çağrılarının ihtiyaç duyduğu
	//     kapasiteyi tüketmemeli.
	select {
	case g.sem <- struct{}{}:
		defer func() { <-g.sem }()
	default:
		g.m.Requests.WithLabelValues(g.cfg.Name, "bulkhead").Inc()
		return ErrBulkhead
	}

	var lastErr error
	attempts := g.cfg.MaxRetries + 1
	for i := 0; i < attempts; i++ {
		if i > 0 {
			if !g.retryAllowed() {
				break
			}
			g.m.Retries.WithLabelValues(g.cfg.Name).Inc()
			// EN: Exponential backoff WITH jitter. Without jitter, every client that failed at the
			//     same moment retries at the same moment: a synchronised second wave that is often
			//     worse than the first. Same de-correlation idea as cache TTL jitter (P03-07).
			// TR: Üstel geri çekilme VE jitter. Jitter olmadan aynı anda hata alan her client aynı
			//     anda tekrar dener: ilkinden beter, senkronize bir ikinci dalga. Önbellek TTL
			//     jitter'ıyla (P03-07) aynı korelasyon kırma fikri.
			if !sleepCtx(ctx, backoff(i, g.cfg.Timeout)) {
				return ctx.Err()
			}
		}
		callCtx, cancel := context.WithTimeout(ctx, g.cfg.Timeout)
		start := time.Now()
		err := fn(callCtx)
		cancel()
		g.m.Duration.WithLabelValues(g.cfg.Name).Observe(time.Since(start).Seconds())
		g.countRequest()

		if err == nil {
			g.onSuccess()
			g.m.Requests.WithLabelValues(g.cfg.Name, "ok").Inc()
			return nil
		}
		lastErr = err
		if isTimeout(err) {
			g.m.Requests.WithLabelValues(g.cfg.Name, "timeout").Inc()
		} else {
			g.m.Requests.WithLabelValues(g.cfg.Name, "error").Inc()
		}
		if ctx.Err() != nil {
			break
		}
	}
	g.onFailure()
	return lastErr
}

// isTimeout — bağlamın süresi doldu YA DA istemcinin kendi soket süre sınırı aşıldı.
// EN: go-redis enforces its timeout as a socket deadline and returns a net.Error, not
//
//	context.DeadlineExceeded; without this check every Redis timeout would count as a plain
//	"error" and the timeout series would stay at zero exactly while timeouts are happening.
//
// TR: go-redis timeout'unu soket süre sınırı olarak uygular ve context.DeadlineExceeded değil bir
//
//	net.Error döndürür; bu kontrol olmadan her Redis timeout'u düz "error" sayılır ve timeout
//	serisi, tam da timeout'lar olurken sıfırda kalırdı.
func isTimeout(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

func (g *Guard) allowRequest() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	switch g.state {
	case Open:
		if time.Since(g.openedAt) >= g.cfg.OpenDuration {
			g.state = HalfOpen
			g.halfOpenCnt = 0
			g.m.BreakerState.WithLabelValues(g.cfg.Name).Set(1)
			return true
		}
		return false
	case HalfOpen:
		if g.halfOpenCnt >= g.cfg.HalfOpenProbes {
			return false
		}
		g.halfOpenCnt++
		return true
	default:
		return true
	}
}

func (g *Guard) onSuccess() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.failures = 0
	if g.state != Closed {
		g.state = Closed
		g.m.BreakerState.WithLabelValues(g.cfg.Name).Set(0)
	}
}

func (g *Guard) onFailure() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.failures++
	if g.state == HalfOpen || g.failures >= g.cfg.FailureThreshold {
		g.state = Open
		g.openedAt = time.Now()
		g.m.BreakerState.WithLabelValues(g.cfg.Name).Set(2)
	}
}

// retryAllowed — retry BÜTÇESİ.
// EN: A retry policy without a budget is an amplifier: at 30% error rate, "3 attempts" turns one
//
//	user request into three dependency calls exactly when the dependency is already failing.
//	The budget caps retries as a FRACTION of traffic, so retries stay a rescue for the few and
//	never become a second load source. P10-01 measures the version without it.
//
// TR: Bütçesiz bir retry politikası bir YÜKSELTEÇTİR: %30 hata oranında "3 deneme", bağımlılık
//
//	zaten hata verirken bir kullanıcı isteğini üç bağımlılık çağrısına çevirir. Bütçe,
//	retry'ları trafiğin bir ORANI ile sınırlar; böylece retry azınlık için bir kurtarma olarak
//	kalır, ikinci bir yük kaynağına dönüşmez. P10-01 bütçesiz hâlini ölçüyor.
func (g *Guard) retryAllowed() bool {
	g.rmu.Lock()
	defer g.rmu.Unlock()
	if time.Since(g.winStart) > 10*time.Second {
		g.winStart = time.Now()
		g.reqCount, g.retCount = 0, 0
	}
	if g.reqCount < 20 {
		g.retCount++ // ısınma: az trafikte bütçe anlamsız — ama SAYMAYI unutma
		return true
	}
	if float64(g.retCount) >= float64(g.reqCount)*g.cfg.RetryBudget {
		return false
	}
	// Bütçeyi harcadığını KAYDET. Bu satır olmadan sayaç hiç artmaz, bütçe her zaman "boş"
	// görünür ve retry'lar sınırsız kalır. Birim test bunu sınar — bir korumanın var olması ile
	// ÇALIŞIYOR olması ayrı şeylerdir.
	g.retCount++
	return true
}

func (g *Guard) countRequest() {
	g.rmu.Lock()
	g.reqCount++
	g.rmu.Unlock()
}

func (g *Guard) State() State {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.state
}

func backoff(attempt int, base time.Duration) time.Duration {
	d := base / 4
	for i := 1; i < attempt; i++ {
		d *= 2
	}
	if d > 2*time.Second {
		d = 2 * time.Second
	}
	return d + jitter(d)
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}
