package resilience

import (
	"net/http"
	"sync/atomic"
)

// Shedder — in-flight istek sayısına göre erken reddetme.
//
// EN: The counter-intuitive part: shedding makes the system FASTER for the requests it accepts.
//
//	Without it, an overloaded server accepts everything and serves everything slowly — every
//	client times out and retries, and nobody gets an answer. With it, a portion gets a fast,
//	honest 503 and the rest get normal latency. Partial service beats uniform failure.
//
// TR: Sezgiye aykırı kısım: yük atma, kabul ettiği istekler için sistemi HIZLANDIRIR. Onsuz,
//
//	aşırı yüklü bir sunucu her şeyi kabul eder ve her şeyi yavaş servis eder — her client
//	zaman aşımına uğrar, tekrar dener ve kimse cevap alamaz. Onunla bir kısım hızlı ve dürüst
//	bir 503 alır, geri kalanı normal gecikmeyi görür. Kısmi hizmet, tekdüze başarısızlıktan iyidir.
//
// [Topic · Konu: Load shedding, admission control]
type Shedder struct {
	max      int64
	inFlight atomic.Int64
	m        *Metrics
	enabled  bool
}

func NewShedder(max int, enabled bool, m *Metrics) *Shedder {
	if max <= 0 {
		max = 256
	}
	return &Shedder{max: int64(max), m: m, enabled: enabled}
}

func (s *Shedder) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Sağlık uçları asla atılmaz: yük altında probe düşerse pod öldürülür (P01-07'nin dersi).
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" || r.URL.Path == "/metrics" {
			next.ServeHTTP(w, r)
			return
		}
		cur := s.inFlight.Add(1)
		defer s.inFlight.Add(-1)
		if s.enabled && cur > s.max {
			s.m.Shed.Inc()
			w.Header().Set("Retry-After", "1")
			http.Error(w, `{"error":"overloaded"}`, http.StatusServiceUnavailable)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Shedder) InFlight() int64 { return s.inFlight.Load() }
