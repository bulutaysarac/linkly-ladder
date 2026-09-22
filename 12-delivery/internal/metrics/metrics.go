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
	Unsafe     *prometheus.CounterVec
	RateLimit  *prometheus.CounterVec // decision, key_type // reason
	trapByCode bool
	// TRAP_TENANT_LABEL: kiracıyı metrik label'ı yapmak (P11-06). Config'de VARDI ama hiçbir
	// yerde OKUNMUYORDU — yani deney tuzağı açıyor, hiçbir şey değişmiyor ve script yine
	// "REPRODUCED" diyordu (kararı Prometheus'un toplam seri sayısına bakarak veriyordu; o sayı
	// yoğun bir kümede zaten sürekli oynar). Ölçülen şey tuzak değil, gürültüydü.
	// EN: the trap existed in config and was read NOWHERE. The experiment flipped a flag that did
	// nothing, and the script still said REPRODUCED because it judged by Prometheus's TOTAL head
	// series — a number that drifts on its own in a busy cluster. It measured noise, not the trap.
	trapByTenant bool
}

func New(trapByCode, trapByTenant bool) *Metrics {
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))

	m := &Metrics{reg: reg, trapByCode: trapByCode, trapByTenant: trapByTenant}
	labels := []string{"route", "method", "code"}
	if trapByCode {
		// TRAP: kısa kodu label yapmak → her link yeni seri. README §7.
		labels = append(labels, "short_code")
	}
	if trapByTenant {
		// TRAP: kiracıyı label yapmak → her kiracı yeni seri. 10 kiracıda zararsız,
		// 10 bin kiracıda Prometheus'u dizlerinin üstüne çöktürür (P11-06).
		labels = append(labels, "tenant")
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
	// NOT: `ratelimit_decisions_total` AYNI ZAMANDA internal/ratelimit paketinin: 08'de limiter Redis'e
	// taşındı ve kendi Metrics'ini kuruyor. İkisi birden kaydedilince Prometheus
	// "duplicate metrics collector registration attempted" ile PANİKLİYOR ve api-svc hiç
	// açılmıyordu. Bir metriğin SAHİBİ tek bir paket olmalı; taşıdığın şeyin eski kaydını da taşı.

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

// ObserveDurationWithExemplar — histogram gözlemi + exemplar (trace_id).
//
// EN: An exemplar attaches a trace ID to a single bucket observation. It is the cheapest possible
//
//	bridge from "p99 is high" to "here is a request that was slow" — no extra cardinality,
//	because the trace ID is NOT a label: it rides alongside the sample. This is the answer to
//	P01-06/P11-06: you never need a high-cardinality label to find the one slow request.
//
// TR: Exemplar, tek bir bucket gözlemine bir trace kimliği iliştirir. "p99 yüksek"ten "işte yavaş
//
//	olan bir istek"e giden en ucuz köprüdür — ek kardinalite YOK, çünkü trace kimliği bir LABEL
//	DEĞİLDİR: örneğin yanında taşınır. P01-06/P11-06'nın cevabı budur: yavaş tek isteği bulmak
//	için asla yüksek kardinaliteli bir label'a ihtiyacın yok.
//
// [Topic · Konu: Exemplar, kardinalite]
func (m *Metrics) ObserveDurationWithExemplar(route string, seconds float64, traceID string) {
	obs, err := m.Duration.GetMetricWithLabelValues(route)
	if err != nil {
		return
	}
	if traceID == "" {
		obs.Observe(seconds)
		return
	}
	if eo, ok := obs.(prometheus.ExemplarObserver); ok {
		eo.ObserveWithExemplar(seconds, prometheus.Labels{"trace_id": traceID})
		return
	}
	obs.Observe(seconds)
}

func (m *Metrics) ObserveRequest(route, method, code, shortCode, tenant string) {
	// Değerler label sırasıyla AYNI mantıkla üretilir: iki yerde iki ayrı koşul yazmak,
	// er geç "inconsistent label cardinality" panic'i demektir.
	v := []string{route, method, code}
	if m.trapByCode {
		v = append(v, shortCode)
	}
	if m.trapByTenant {
		v = append(v, tenant)
	}
	m.Requests.WithLabelValues(v...).Inc()
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

// BindRedisStats — istemci havuzunun kendi sayaçları (sunucu tarafını redis_exporter veriyor).
func (m *Metrics) BindRedisStats(fn func() (hits, misses uint32)) {
	m.reg.MustRegister(prometheus.NewCounterFunc(prometheus.CounterOpts{
		Name: "redis_client_pool_hits_total", Help: "İstemci havuzunda hazır bağlantı bulundu"},
		func() float64 { h, _ := fn(); return float64(h) }))
	m.reg.MustRegister(prometheus.NewCounterFunc(prometheus.CounterOpts{
		Name: "redis_client_pool_misses_total", Help: "İstemci havuzunda yeni bağlantı açıldı"},
		func() float64 { _, ms := fn(); return float64(ms) }))
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
