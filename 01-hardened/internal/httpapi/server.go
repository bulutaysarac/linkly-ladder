// Package httpapi — HTTP taşıma katmanı: yönlendirme, middleware, sunucu ayarları.
package httpapi

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/config"
	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/store"
)

type API struct {
	cfg     config.Config
	log     *slog.Logger
	met     *metrics.Metrics
	store   *store.Memory
	ready   atomic.Bool
	version string
}

func New(cfg config.Config, log *slog.Logger, met *metrics.Metrics, st *store.Memory, version string) *API {
	return &API{cfg: cfg, log: log, met: met, store: st, version: version}
}

func (a *API) SetReady(v bool) { a.ready.Store(v) }

// Handler — /metrics, /healthz, /readyz middleware zincirinin DIŞINDA kalır.
// EN: Health and metrics endpoints must not be rate limited, must not be timed out by the business
//
//	timeout, and must not pollute business metrics. If your readiness probe can be rate limited,
//	a traffic spike will take every pod out of the load balancer at the worst possible moment.
//
// TR: Sağlık ve metrik uçları hız sınırına takılmamalı, iş timeout'una tabi olmamalı ve iş
//
//	metriklerini kirletmemeli. Readiness probe'un hız sınırına takılabiliyorsa, bir trafik
//	dalgası tam en kötü anda bütün pod'ları load balancer'dan düşürür.
func (a *API) Handler(rl *ratelimit.Limiter) http.Handler {
	business := http.NewServeMux()
	business.HandleFunc("POST /api/links", a.handleCreate)
	business.HandleFunc("GET /api/links/{code}", a.handleGet)
	business.HandleFunc("DELETE /api/links/{code}", a.handleDelete)
	business.HandleFunc("GET /{code}", a.handleRedirect)

	root := http.NewServeMux()
	if a.cfg.TrapLivenessStrict {
		// TRAP: sağlık uçlarını iş zincirinin ARKASINA koy — hız sınırına ve iş timeout'una tabi olsunlar.
		// Gerçek hayatta çok yaygın bir hata: "tek bir middleware zinciri var, hepsi oradan geçsin".
		// Sonuç: trafik dalgası → probe 429/timeout → kubelet pod'u öldürür → kalan pod'a daha çok
		// yük → o da ölür. Yük artışı kendini KESİNTİYE çevirir. README §7.
		business.HandleFunc("GET /healthz", a.handleHealthz)
		business.HandleFunc("GET /readyz", a.handleReadyz)
		root.Handle("/", TrapChain(business, a.log, a.met, rl, a.cfg.HandlerTimeout))
		root.Handle("GET /metrics", a.met.Handler())
		return root
	}
	root.Handle("/", Chain(business, a.log, a.met, rl, a.cfg.HandlerTimeout))
	root.HandleFunc("GET /healthz", a.handleHealthz)
	root.HandleFunc("GET /readyz", a.handleReadyz)
	root.Handle("GET /metrics", a.met.Handler())
	return root
}

func (a *API) Server(h http.Handler) *http.Server {
	// EN: Every timeout here exists because level 00 lacked it. ReadHeaderTimeout is the slowloris
	//     guard measured in P00-07: without it the server holds a half-open connection forever.
	// TR: Buradaki her timeout, 00'da yok olduğu için var. ReadHeaderTimeout, P00-07'de ölçülen
	//     slowloris korumasıdır: olmazsa sunucu yarım bağlantıyı sonsuza kadar tutar.
	return &http.Server{
		Addr:              a.cfg.Addr,
		Handler:           h,
		ReadHeaderTimeout: a.cfg.ReadHeaderTimeout,
		ReadTimeout:       a.cfg.ReadTimeout,
		WriteTimeout:      a.cfg.WriteTimeout,
		IdleTimeout:       a.cfg.IdleTimeout,
		ErrorLog:          slog.NewLogLogger(a.log.Handler(), slog.LevelWarn),
	}
}

func (a *API) handleHealthz(w http.ResponseWriter, r *http.Request) {
	// EN: Liveness answers exactly one question: is this process wedged beyond recovery? Anything
	//     more (dependencies, readiness state) turns a dependency blip into a restart storm.
	// TR: Liveness tek bir soruya cevap verir: bu süreç kurtarılamaz biçimde kilitlendi mi?
	//     Fazlası (bağımlılıklar, hazır olma durumu) bir bağımlılık kesintisini restart fırtınasına
	//     çevirir. TRAP_LIVENESS_STRICT bunu bilerek bozuyor — README §7.
	writeJSON(w, http.StatusOK, map[string]string{"status": "alive", "version": a.version})
}

func (a *API) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if !a.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func routeOf(r *http.Request) string {
	p := r.URL.Path
	switch {
	case p == "/api/links":
		return "/api/links"
	case strings.HasPrefix(p, "/api/links/"):
		return "/api/links/{code}"
	case p == "/":
		return "/"
	default:
		return "/{code}"
	}
}

func shortCodeOf(r *http.Request) string {
	// Yalnızca TRAP_METRIC_LABEL_CODE açıkken kullanılır.
	p := strings.TrimPrefix(r.URL.Path, "/")
	if strings.HasPrefix(p, "api/links/") {
		return strings.TrimSuffix(strings.TrimPrefix(p, "api/links/"), "/stats")
	}
	return p
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, r *http.Request, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code, "request_id": RequestID(r.Context())})
}

var _ = time.Second
