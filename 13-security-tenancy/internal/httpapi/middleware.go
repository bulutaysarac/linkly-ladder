package httpapi

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/config"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/tracing"
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
		traceID, spanID := tracing.SpanIDs(r.Context())
		// route = ŞABLON, gerçek yol değil. "/{code}" yerine "/abc123" yazsaydık her link yeni bir
		// zaman serisi olurdu — kardinalite patlaması (bkz. TRAP_METRIC_LABEL_CODE).
		route := routeOf(r)
		// Exemplar: metrikten trace'e köprü. Kardinalite ödemeden tekil isteğe ulaşmanın yolu.
		m.ObserveDurationWithExemplar(route, d.Seconds(), traceID)
		m.ObserveRequest(route, r.Method, strconv.Itoa(rec.status), shortCodeOf(r))
		// trace_id ve span_id HER log satırında. Grafana'nın Loki datasource'unda tanımlı
		// derived field bunu yakalayıp Tempo'ya link veriyor — log'dan trace'e tek tıkla geçiş.
		log.Info("http",
			"method", r.Method, "route", route, "path", r.URL.Path, "status", rec.status,
			"dur_ms", d.Milliseconds(), "ip", clientIP(r), "request_id", RequestID(r.Context()),
			"trace_id", traceID, "span_id", spanID)
	})
}

func timeout(next http.Handler, d time.Duration) http.Handler {
	// EN: A server-side deadline is not the same as the client's patience. Without it, a slow
	//     handler holds a goroutine, a connection and memory for as long as it likes.
	// TR: Sunucu tarafı süre sınırı, client'ın sabrıyla aynı şey değil. Olmazsa yavaş bir handler
	//     goroutine'i, bağlantıyı ve belleği istediği kadar tutar.
	return http.TimeoutHandler(next, d, `{"error":"timeout"}`)
}

// rateLimit — artık PAYLAŞILAN bir limiter kullanıyor.
//
// EN: Two keys, checked in order: tenant first (the expensive, coarse limit) and IP second (the
//
//	cheap, fine one). Order matters for cost: rejecting a whole tenant early saves the per-IP
//	round trip. Both are checked against Redis, so the limit holds across every replica of
//	every service — which is what P02-04/P01-05 asked for.
//
// TR: İki anahtar, sırayla: önce kiracı (pahalı, kaba limit), sonra IP (ucuz, ince). Sıra maliyet
//
//	açısından önemli: bir kiracıyı erken reddetmek IP kontrolünün gidiş-gelişinden tasarruf
//	ettirir. İkisi de Redis'e sorulur, yani limit her servisin her replikasında GEÇERLİDİR —
//	P02-04/P01-05'in istediği tam olarak buydu.
func rateLimitDistributed(next http.Handler, cfg config.Config, d *ratelimit.Distributed) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 250*time.Millisecond)
		defer cancel()

		if cfg.TrapGlobalLimit {
			// TRAP: tek bir global anahtar → HER istek aynı Redis anahtarına yazar (P08-05).
			if dec := d.Allow(ctx, "global", "all", cfg.RateLimitPerTenant); !dec.Allowed {
				reject(w, dec)
				return
			}
		}
		tenant := tenantOf(r)
		if dec := d.Allow(ctx, "tenant", tenant, cfg.RateLimitPerTenant); !dec.Allowed {
			reject(w, dec)
			return
		}
		ip := clientIPFrom(r, cfg.TrustedProxyHops, cfg.TrapTrustAnyXFF, cfg.TrapIgnoreXFF)
		if dec := d.Allow(ctx, "ip", ip, cfg.RateLimitPerIP); !dec.Allowed {
			reject(w, dec)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// reject — 429 + Retry-After. Bir client'a "ne zaman tekrar dene" demeyen bir limit,
// onu daha agresif denemeye iter: sınırlama, iletişim kurmayı gerektirir.
func reject(w http.ResponseWriter, dec ratelimit.Decision) {
	secs := int(dec.RetryAfter.Seconds())
	if secs < 1 {
		secs = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	w.Header().Set("X-RateLimit-Limit", strconv.Itoa(dec.Limit))
	w.Header().Set("X-RateLimit-Scope", dec.KeyType)
	http.Error(w, `{"error":"rate_limited","scope":"`+dec.KeyType+`"}`, http.StatusTooManyRequests)
}

func rateLimit(next http.Handler, m *metrics.Metrics, rl *ratelimit.Limiter) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if !rl.Allow(ip) {
			m.RateLimit.WithLabelValues("reject", "ip").Inc()
			w.Header().Set("Retry-After", "1")
			http.Error(w, `{"error":"rate_limited"}`, http.StatusTooManyRequests)
			return
		}
		m.RateLimit.WithLabelValues("allow", "ip").Inc()
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
