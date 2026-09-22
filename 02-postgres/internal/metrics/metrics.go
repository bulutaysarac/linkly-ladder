// Package metrics — Prometheus metrikleri.
//
// EN: Every counter is registered at zero on startup. This is not cosmetic: a counter that only
//
//	appears the first time it fires CANNOT be alerted on, because the monitoring system cannot
//	tell "this never happened" from "this endpoint is not reporting".
//
// TR: Her sayaç açılışta SIFIRLA kaydedilir. Kozmetik değil: yalnızca ilk kez tetiklendiğinde
//
//	ortaya çıkan bir sayaca alarm yazamazsın, çünkü izleme sistemi "hiç olmadı" ile
//	"bu uç raporlamıyor"u ayırt edemez.
//
// [Topic · Konu: Gözlemlenebilirlik, alarm yazılabilirliği]
//
// Label kuralı: SINIRSIZ değerler (kısa kod, URL, IP, tenant id) asla label olmaz — her yeni değer
// yeni bir zaman serisi demektir ve Prometheus'un belleği seri sayısıyla büyür. Bkz. TRAP_METRIC_LABEL_CODE.
package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Metrics struct {
	reg *prometheus.Registry

	Requests   *prometheus.CounterVec   // route, method, code
	Duration   *prometheus.HistogramVec // route
	InFlight   prometheus.Gauge
	Panics     prometheus.Counter
	Redirect   *prometheus.CounterVec // result
	Create     *prometheus.CounterVec // result
	Unsafe     *prometheus.CounterVec // reason
	RateLimit  *prometheus.CounterVec // decision, key_type
	trapByCode bool
}

func New(trapByCode bool) *Metrics {
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))

	m := &Metrics{reg: reg, trapByCode: trapByCode}
	labels := []string{"route", "method", "code"}
	if trapByCode {
		// TRAP: kısa kodu label yapmak → her link yeni seri. README §7.
		labels = append(labels, "short_code")
	}
	m.Requests = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total", Help: "Toplam HTTP isteği",
	}, labels)
	m.Duration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name: "http_request_duration_seconds", Help: "İstek süresi",
		Buckets: []float64{.001, .0025, .005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5},
	}, []string{"route"})
	m.InFlight = prometheus.NewGauge(prometheus.GaugeOpts{Name: "http_in_flight_requests", Help: "İşlenmekte olan istek"})
	m.Panics = prometheus.NewCounter(prometheus.CounterOpts{Name: "http_panics_total", Help: "Recover edilen panic"})
	m.Redirect = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "redirect_total", Help: "Yönlendirme sonucu"}, []string{"result"})
	m.Create = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "create_total", Help: "Link oluşturma sonucu"}, []string{"result"})
	m.Unsafe = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "create_rejected_unsafe_total", Help: "Güvenlik nedeniyle reddedilen hedef"}, []string{"reason"})
	m.RateLimit = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "ratelimit_decisions_total", Help: "Hız sınırı kararı"}, []string{"decision", "key_type"})

	reg.MustRegister(m.Requests, m.Duration, m.InFlight, m.Panics, m.Redirect, m.Create, m.Unsafe, m.RateLimit)
	m.preRegisterZero()
	return m
}

// preRegisterZero — bilinen tüm label kombinasyonlarını sıfırda yayınla.
func (m *Metrics) preRegisterZero() {
	for _, r := range []string{"ok", "not_found", "invalid", "error"} {
		m.Redirect.WithLabelValues(r)
	}
	for _, r := range []string{"ok", "collision", "exhausted", "invalid", "too_large", "error"} {
		m.Create.WithLabelValues(r)
	}
	for _, r := range []string{"scheme", "host", "private_address", "parse"} {
		m.Unsafe.WithLabelValues(r)
	}
	for _, d := range []string{"allow", "reject"} {
		m.RateLimit.WithLabelValues(d, "ip")
	}
}

func (m *Metrics) ObserveRequest(route, method, code, shortCode string) {
	if m.trapByCode {
		m.Requests.WithLabelValues(route, method, code, shortCode).Inc()
		return
	}
	m.Requests.WithLabelValues(route, method, code).Inc()
}

// Registry — başka paketlerin (store gibi) kendi metriklerini kaydedebilmesi için.
func (m *Metrics) Registry() prometheus.Registerer { return m.reg }

// BindPoolStats — bağlantı havuzunun anlık durumunu her scrape'te oku.
// EN: A gauge you must remember to update is a gauge that will be stale. Deriving it from the pool
//
//	at collection time means it cannot lie.
//
// TR: Güncellemeyi hatırlaman gereken bir gauge, bayat kalacak bir gauge'dır. Toplama anında
//
//	havuzdan türetmek yalan söylemesini imkânsız kılar.
func (m *Metrics) BindPoolStats(fn func() (acquired, idle, total, max int32)) {
	m.reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "db_pool_acquired_conns", Help: "Kullanımdaki bağlantı"},
		func() float64 { a, _, _, _ := fn(); return float64(a) }))
	m.reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "db_pool_idle_conns", Help: "Boştaki bağlantı"},
		func() float64 { _, i, _, _ := fn(); return float64(i) }))
	m.reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "db_pool_total_conns", Help: "Toplam bağlantı"},
		func() float64 { _, _, t, _ := fn(); return float64(t) }))
	m.reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "db_pool_max_conns", Help: "Havuz üst sınırı"},
		func() float64 { _, _, _, mx := fn(); return float64(mx) }))
}

func (m *Metrics) Handler() http.Handler {
	// EnableOpenMetrics: EXEMPLAR'LARIN TEK KAPISI.
	// EN: The code above carefully attaches a trace_id exemplar to every histogram observation.
	//     With this flag false — the default — promhttp serves the classic text format, which has
	//     no place to put an exemplar, so every one of them is silently dropped at the door.
	//     Prometheus then stores no exemplars, /api/v1/query_exemplars returns nothing, and
	//     P11-01's "jump from the metric to the trace" step reported "no exemplar found" while
	//     both sides of the bridge were fully implemented. A feature that is built, wired and
	//     then dropped by a serialization default is indistinguishable from a feature nobody wrote.
	// TR: Yukarıdaki kod her histogram gözlemine özenle bir trace_id exemplar'ı iliştiriyor.
	//     Bu bayrak false iken — ki VARSAYILAN budur — promhttp klasik metin formatını servis
	//     eder; o formatta exemplar'ı koyacak yer YOKTUR, yani hepsi kapıda sessizce düşer.
	//     Prometheus hiç exemplar saklamaz, /api/v1/query_exemplars boş döner ve P11-01'in
	//     "metrikten trace'e atla" adımı, köprünün İKİ UCU DA yazılmışken "exemplar bulunamadı"
	//     der. Yazılmış, bağlanmış ve bir serileştirme varsayılanı yüzünden düşen bir özellik,
	//     hiç yazılmamış bir özellikten ayırt edilemez.
	// [Topic · Konu: Exemplar, OpenMetrics, sessiz varsayılanlar]
	return promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{Registry: m.reg, EnableOpenMetrics: true})
}
