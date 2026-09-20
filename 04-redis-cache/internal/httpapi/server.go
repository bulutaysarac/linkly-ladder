// Package httpapi — HTTP taşıma katmanı: yönlendirme, middleware, sunucu ayarları.
package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/bulutaysarac/linkly-ladder/04-redis-cache/internal/config"
	"github.com/bulutaysarac/linkly-ladder/04-redis-cache/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/04-redis-cache/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/04-redis-cache/internal/store"
	"github.com/redis/go-redis/v9"
)

type API struct {
	cfg     config.Config
	log     *slog.Logger
	met     *metrics.Metrics
	store   store.Store
	ready   atomic.Bool
	version string
	rdb     *redis.Client // yalnızca TRAP_DEBUG_KEYS ucu için
}

// SetRedis — debug ucunun Redis'e doğrudan erişmesi için. Üretimde böyle bir uç OLMAMALI;
// burada bir tuzağı (P04-07) somut kılmak için var ve varsayılan olarak KAPALI.
func (a *API) SetRedis(rdb *redis.Client) { a.rdb = rdb }

func New(cfg config.Config, log *slog.Logger, met *metrics.Metrics, st store.Store, version string) *API {
	return &API{cfg: cfg, log: log, met: met, store: st, version: version}
}

func (a *API) SetReady(v bool) { a.ready.Store(v) }

// Handler — /metrics, /healthz, /readyz middleware zincirinin DIŞINDA kalır.
// EN: Health and metrics endpoints must not be rate limited, must not be timed out by the business
//     timeout, and must not pollute business metrics. If your readiness probe can be rate limited,
//     a traffic spike will take every pod out of the load balancer at the worst possible moment.
// TR: Sağlık ve metrik uçları hız sınırına takılmamalı, iş timeout'una tabi olmamalı ve iş
//     metriklerini kirletmemeli. Readiness probe'un hız sınırına takılabiliyorsa, bir trafik
//     dalgası tam en kötü anda bütün pod'ları load balancer'dan düşürür.
func (a *API) Handler(rl *ratelimit.Limiter) http.Handler {
	business := http.NewServeMux()
	business.HandleFunc("POST /api/links", a.handleCreate)
	business.HandleFunc("GET /api/links/{code}", a.handleGet)
	business.HandleFunc("DELETE /api/links/{code}", a.handleDelete)
	business.HandleFunc("GET /api/links", a.handleList)
	if a.cfg.TrapDebugKeys {
		// TRAP: "sadece debug için" eklenen bir uç. KEYS * Redis'i TEK İŞ PARÇACIKLI olarak
		// tarar ve tarama bitene kadar BAŞKA HİÇBİR KOMUT çalışmaz — yani tüm redirect'ler bekler.
		business.HandleFunc("GET /debug/keys", a.handleDebugKeys)
	}
	business.HandleFunc("GET /{code}", a.handleRedirect)

	root := http.NewServeMux()
	if a.cfg.TrapLivenessStrict {
		// TRAP: sağlık uçlarını iş zincirinin ARKASINA koy — hız sınırına ve iş timeout'una tabi olsunlar.
		// Gerçek hayatta çok yaygın bir hata: "tek bir middleware zinciri var, hepsi oradan geçsin".
		// Sonuç: trafik dalgası → probe 429/timeout → kubelet pod'u öldürür → kalan pod'a daha çok
		// yük → o da ölür. Yük artışı kendini KESİNTİYE çevirir. README §7.
		business.HandleFunc("GET /healthz", a.handleHealthz)
		business.HandleFunc("GET /readyz", a.handleReadyz)
		root.Handle("/", Chain(business, a.log, a.met, rl, a.cfg.HandlerTimeout))
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
	// TRAP_READYZ_CHECKS_DB: "readiness bağımlılıkları kontrol etsin" çok makul görünen bir fikirdir
	// ve yanlıştır. DB 10 saniye kesilirse TÜM pod'lar aynı anda Endpoints'ten düşer; ingress'in
	// yönlendirecek hiçbir hedefi kalmaz ve kısmi bir arıza TAM kesintiye dönüşür. Üstelik DB geri
	// geldiğinde pod'lar aynı anda geri gelip onu ikinci kez devirir. Readiness "BEN hazır mıyım?"
	// sorusudur; "bağımlılığım iyi mi?" sorusunun cevabı METRİKTİR. (P02-10 · aynı tuzağın büyüğü P10-02)
	if a.cfg.TrapReadyzChecksDB {
		ctx, cancel := context.WithTimeout(r.Context(), 1*time.Second)
		defer cancel()
		if err := a.store.Ping(ctx); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db_down", "error": err.Error()})
			return
		}
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
		return strings.TrimPrefix(p, "api/links/")
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

// tenantOf — X-Tenant-ID header'ı.
// EN: THIS IS NOT AUTHENTICATION. Anyone can send this header with curl. It exists so the
//     tenant-boundary logic can be built and tested without dragging an identity provider into a
//     teaching project. In production the tenant must come from a validated token or be injected by
//     a gateway that already authenticated the caller. Level 13 does that and measures what this costs.
// TR: BU KİMLİK DOĞRULAMA DEĞİLDİR. Bu header'ı curl ile herkes gönderebilir. Amacı, kiracı sınırı
//     mantığının bir kimlik sağlayıcı sürüklemeden kurulabilmesi ve test edilebilmesi. Üretimde
//     kiracı, doğrulanmış bir token'dan gelmeli ya da çağıranı zaten doğrulamış bir ağ geçidi
//     tarafından enjekte edilmeli. 13 bunu yapıyor ve bunun bedelini ölçüyor.
// [Topic · Konu: Çok kiracılılık, kimlik]
func tenantOf(r *http.Request) string {
	if t := r.Header.Get("X-Tenant-ID"); t != "" {
		return t
	}
	return "default"
}
