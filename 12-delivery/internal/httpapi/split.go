package httpapi

import (
	"net/http"

	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/ratelimit"
)

// Bu seviyede tek uygulama ikiye ayrılıyor: redirect-svc ve api-svc.
//
// EN: Why split at all? Because the two paths have nothing in common except the data:
//   - redirect: ~1000x the traffic, sub-millisecond budget, read-only, cache-dominated
//   - api:      low traffic, writes, list queries, tolerant of 100ms
//     Sharing one deployment means one CPU limit, one replica count and one HPA target for two
//     completely different load shapes — you end up over-provisioning the write path to protect
//     the read path. Splitting is not about microservices; it is about giving each load shape
//     its own knob.
// TR: Neden ayırıyoruz? Çünkü iki yolun veri dışında ortak hiçbir yanı yok:
//   - redirect: ~1000 kat trafik, milisaniye altı bütçe, salt okuma, önbellek ağırlıklı
//   - api:      düşük trafik, yazma, liste sorguları, 100 ms'ye toleranslı
//     Tek deployment demek, iki tamamen farklı yük şekli için tek CPU limiti, tek replika sayısı
//     ve tek HPA hedefi demek — okuma yolunu korumak için yazma yolunu gereğinden fazla
//     büyütürsün. Bu bir "mikroservis" meselesi değil; her yük şekline kendi düğmesini vermek.
// [Topic · Konu: Servis sınırı, yük profili]

// RedirectHandler — yalnızca GET /{code} ve sağlık uçları.
func (a *API) RedirectHandler(rl *ratelimit.Limiter) http.Handler {
	business := http.NewServeMux()
	business.HandleFunc("GET /{code}", a.handleRedirect)

	root := http.NewServeMux()
	root.Handle("/", a.chain(business, rl))
	root.HandleFunc("GET /healthz", a.handleHealthz)
	root.HandleFunc("GET /readyz", a.handleReadyz)
	root.Handle("GET /metrics", a.met.Handler())
	return root
}

// APIHandler — yönetim uçları; redirect YOK.
func (a *API) APIHandler(rl *ratelimit.Limiter) http.Handler {
	business := http.NewServeMux()
	business.HandleFunc("POST /api/links", a.handleCreate)
	business.HandleFunc("GET /api/links/{code}", a.handleGet)
	business.HandleFunc("DELETE /api/links/{code}", a.handleDelete)
	business.HandleFunc("GET /api/links", a.handleList)
	business.HandleFunc("GET /api/links/{code}/stats", a.handleStats)

	root := http.NewServeMux()
	root.Handle("/", a.chain(business, rl))
	root.HandleFunc("GET /healthz", a.handleHealthz)
	root.HandleFunc("GET /readyz", a.handleReadyz)
	root.Handle("GET /metrics", a.met.Handler())
	return root
}
