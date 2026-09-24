package httpapi

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/bulutaysarac/linkly-ladder/03-local-cache/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/03-local-cache/internal/ratelimit"
)

type ctxKey string

const ctxRequestID ctxKey = "request_id"

// EN: The chain order is the design. recover must be outermost (it must catch panics from every
//
//	layer below, including the logger); requestID must come before accessLog (so the log line has
//	it); timeout must come before the handler but after logging (so a timed-out request is still
//	logged); rateLimit sits last so rejected requests are cheap — they never reach business logic.
//
// TR: Zincirin SIRASI tasarımın kendisi. recover en dışta olmalı (altındaki her katmanın panic'ini
//
//	yakalamalı, logger dahil); requestID accessLog'dan önce gelmeli (log satırında görünsün diye);
//	timeout handler'dan önce ama log'dan sonra olmalı (zaman aşımına uğrayan istek yine loglansın);
//	rateLimit en sonda ki reddedilen istek ucuz olsun — iş mantığına hiç ulaşmasın.
//
// [Topic · Konu: Katmanlı koruma, middleware sırası]
func Chain(h http.Handler, log *slog.Logger, m *metrics.Metrics, rl *ratelimit.Limiter, handlerTimeout time.Duration) http.Handler {
	h = rateLimit(h, m, rl)
	h = timeout(h, handlerTimeout)
	h = accessLog(h, log, m)
	h = requestID(h)
	h = recoverPanic(h, log, m)
	return h
}

// TrapChain — TRAP_LIVENESS_STRICT'in zinciri: Chain ile aynı sıra, tek farkla — hız sınırı pod başına
// TEK kovadır. "Her şey tek zincirden geçsin" diyen kestirme, limiti de çoğu zaman böyle yazar ve iki
// hata birbirini büyütür: IP başına bir kova probe'ları korurdu (kubelet düğümün IP'sinden gelir, kendi
// kovası olur), tek kovada ise istemcinin yükü probe'un payını da tüketir → probe 429 → pod trafikten
// düşer, uzun sürerse yeniden başlatılır (P01-07).
func TrapChain(h http.Handler, log *slog.Logger, m *metrics.Metrics, rl *ratelimit.Limiter, handlerTimeout time.Duration) http.Handler {
	h = rateLimitBy(h, m, rl, "pod", podBucket)
	h = timeout(h, handlerTimeout)
	h = accessLog(h, log, m)
	h = requestID(h)
	h = recoverPanic(h, log, m)
	return h
}

func recoverPanic(next http.Handler, log *slog.Logger, m *metrics.Metrics) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				m.Panics.Inc()
				log.Error("panic", "err", rec, "path", r.URL.Path, "request_id", RequestID(r.Context()))
				http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func requestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-ID")
		if id == "" {
			id = strconv.FormatInt(time.Now().UnixNano(), 36)
		}
		w.Header().Set("X-Request-ID", id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxRequestID, id)))
	})
}

func RequestID(ctx context.Context) string {
	if v, ok := ctx.Value(ctxRequestID).(string); ok {
		return v
	}
	return ""
}

type recorder struct {
	http.ResponseWriter
	status int
}

func (r *recorder) WriteHeader(c int) {
	r.status = c
	r.ResponseWriter.WriteHeader(c)
}

func (r *recorder) Write(b []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(b)
}

func accessLog(next http.Handler, log *slog.Logger, m *metrics.Metrics) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		m.InFlight.Inc()
		defer m.InFlight.Dec()
		rec := &recorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		d := time.Since(start)
		// route = ŞABLON, gerçek yol değil. "/{code}" yerine "/abc123" yazsaydık her link yeni bir
		// zaman serisi olurdu — kardinalite patlaması (bkz. TRAP_METRIC_LABEL_CODE).
		route := routeOf(r)
		m.Duration.WithLabelValues(route).Observe(d.Seconds())
		m.ObserveRequest(route, r.Method, strconv.Itoa(rec.status), shortCodeOf(r))
		log.Info("http",
			"method", r.Method, "route", route, "path", r.URL.Path, "status", rec.status,
			"dur_ms", d.Milliseconds(), "ip", clientIP(r), "request_id", RequestID(r.Context()))
	})
}

func timeout(next http.Handler, d time.Duration) http.Handler {
	// EN: A server-side deadline is not the same as the client's patience. Without it, a slow
	//     handler holds a goroutine, a connection and memory for as long as it likes.
	// TR: Sunucu tarafı süre sınırı, client'ın sabrıyla aynı şey değil. Olmazsa yavaş bir handler
	//     goroutine'i, bağlantıyı ve belleği istediği kadar tutar.
	return http.TimeoutHandler(next, d, `{"error":"timeout"}`)
}

func rateLimit(next http.Handler, m *metrics.Metrics, rl *ratelimit.Limiter) http.Handler {
	return rateLimitBy(next, m, rl, "ip", clientIP)
}

// podBucket — bütün istekler tek kova: sınır istemci başına değil pod başına uygulanır.
func podBucket(*http.Request) string { return "pod" }

func rateLimitBy(next http.Handler, m *metrics.Metrics, rl *ratelimit.Limiter, scope string, key func(*http.Request) string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !rl.Allow(key(r)) {
			m.RateLimit.WithLabelValues("reject", scope).Inc()
			w.Header().Set("Retry-After", "1")
			http.Error(w, `{"error":"rate_limited"}`, http.StatusTooManyRequests)
			return
		}
		m.RateLimit.WithLabelValues("allow", scope).Inc()
		next.ServeHTTP(w, r)
	})
}

// clientIP — X-Forwarded-For'un SON hop'una değil, ingress'in eklediği ilk değere bakıyoruz.
// UYARI: bu haliyle header spoof edilebilir; 08'de sadece güvenilen proxy hop'undan alınacak.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		for i := 0; i < len(xff); i++ {
			if xff[i] == ',' {
				return xff[:i]
			}
		}
		return xff
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
