package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/bulutaysarac/linkly-ladder/02-postgres/internal/shortcode"
	"github.com/bulutaysarac/linkly-ladder/02-postgres/internal/store"
)

type createReq struct {
	URL string `json:"url"`
}

// dbCtx — her sorguya bir süre sınırı.
// EN: The client's context already carries the handler timeout, so why another one? Because they
//     answer different questions: the handler timeout protects the CALLER (stop waiting), the query
//     timeout protects the DEPENDENCY (stop asking). Without the second one a slow database keeps
//     accumulating work from clients who already gave up — see P02-06 and, in its full form, P10-03.
// TR: Client'ın context'i zaten handler timeout'unu taşıyor, o hâlde neden bir tane daha? Çünkü
//     farklı sorulara cevap veriyorlar: handler timeout ÇAĞIRANI korur (beklemeyi bırak), sorgu
//     timeout'u BAĞIMLILIĞI korur (sormayı bırak). İkincisi olmazsa yavaş bir veritabanı, çoktan
//     vazgeçmiş client'lardan iş biriktirmeye devam eder — bkz. P02-06 ve tam hâliyle P10-03.
// [Topic · Konu: Timeout bütçesi]
func (a *API) dbCtx(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), a.cfg.DBQueryTimeout)
}

func (a *API) handleCreate(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, a.cfg.MaxBodyBytes)

	var req createReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			a.met.Create.WithLabelValues("too_large").Inc()
			writeErr(w, r, http.StatusRequestEntityTooLarge, "body_too_large")
			return
		}
		a.met.Create.WithLabelValues("invalid").Inc()
		writeErr(w, r, http.StatusBadRequest, "invalid_json")
		return
	}

	target, reason := checkURL(req.URL)
	if reason != "" {
		a.met.Create.WithLabelValues("invalid").Inc()
		a.met.Unsafe.WithLabelValues(reason).Inc()
		writeErr(w, r, http.StatusBadRequest, "unsafe_url:"+reason)
		return
	}

	ctx, cancel := a.dbCtx(r)
	defer cancel()
	tenant := tenantOf(r)

	for attempt := 0; attempt < a.cfg.CodeMaxAttempts; attempt++ {
		code, err := shortcode.New(a.cfg.CodeLength)
		if err != nil {
			writeErr(w, r, http.StatusInternalServerError, "rand_failed")
			return
		}
		l := &store.Link{Code: code, URL: target, Tenant: tenant, CreatedAt: time.Now().UTC()}
		switch err := a.store.CreateUnique(ctx, l); {
		case err == nil:
			a.met.Create.WithLabelValues("ok").Inc()
			writeJSON(w, http.StatusCreated, map[string]any{
				"code": code, "url": target, "short_url": "http://" + r.Host + "/" + code,
			})
			return
		case errors.Is(err, store.ErrExists):
			a.met.Create.WithLabelValues("collision").Inc()
			continue
		default:
			a.log.Error("create başarısız", "err", err, "request_id", RequestID(r.Context()))
			a.met.Create.WithLabelValues("error").Inc()
			writeErr(w, r, http.StatusServiceUnavailable, "store_error")
			return
		}
	}
	a.met.Create.WithLabelValues("exhausted").Inc()
	writeErr(w, r, http.StatusServiceUnavailable, "code_space_exhausted")
}

func (a *API) handleRedirect(w http.ResponseWriter, r *http.Request) {
	code := r.PathValue("code")
	if !shortcode.Valid(code, a.cfg.CodeLength) {
		a.met.Redirect.WithLabelValues("invalid").Inc()
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
	ctx, cancel := a.dbCtx(r)
	defer cancel()

	// EN: Every single redirect is now a network round trip to the database. At level 01 this was a
	//     map lookup measured in nanoseconds; now it is a query measured in milliseconds, and it is
	//     on the hot path of a read-heavy system. That is the trade this level makes — and P02-01
	//     measures exactly what it costs. Levels 03 and 04 buy it back with caching.
	// TR: Artık HER redirect veritabanına bir ağ gidiş-gelişi. 01'de bu nanosaniyelerle ölçülen bir
	//     map aramasıydı; şimdi milisaniyelerle ölçülen bir sorgu ve okuma ağırlıklı bir sistemin
	//     sıcak yolunda duruyor. Bu seviyenin yaptığı takas bu — P02-01 tam olarak bedelini ölçüyor.
	//     03 ve 04 önbellekle geri satın alıyor.
	// [Topic · Konu: Okuma yolu, cache-aside gerekçesi]
	l, err := a.store.Get(ctx, code)
	if errors.Is(err, store.ErrNotFound) {
		a.met.Redirect.WithLabelValues("not_found").Inc()
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		a.log.Error("redirect başarısız", "err", err, "code", code, "request_id", RequestID(r.Context()))
		a.met.Redirect.WithLabelValues("error").Inc()
		writeErr(w, r, http.StatusServiceUnavailable, "store_error")
		return
	}

	// Tıklama sayacı hâlâ istek yolunda ve artık bir SATIR KİLİDİ (P02-08 · çözüm 05).
	if err := a.store.IncrementClicks(ctx, code); err != nil {
		a.log.Warn("tıklama sayılamadı", "err", err, "code", code)
	}

	a.met.Redirect.WithLabelValues("ok").Inc()
	w.Header().Set("Cache-Control", "no-store, max-age=0")
	http.Redirect(w, r, l.URL, http.StatusFound)
}

func (a *API) handleGet(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := a.dbCtx(r)
	defer cancel()
	l, err := a.store.Get(ctx, r.PathValue("code"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		writeErr(w, r, http.StatusServiceUnavailable, "store_error")
		return
	}
	writeJSON(w, http.StatusOK, l)
}

func (a *API) handleDelete(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := a.dbCtx(r)
	defer cancel()
	// Kiracı sınırı: silme yalnızca KENDİ linkini silebilmeli. Filtreyi WHERE'e koymak,
	// uygulamada kontrol etmekten üstündür — unutulan bir kontrol sessizce veri sızdırır,
	// unutulan bir WHERE ise 0 satır etkiler. (13'te RLS ile veritabanına da öğreteceğiz.)
	err := a.store.Delete(ctx, tenantOf(r), r.PathValue("code"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		writeErr(w, r, http.StatusServiceUnavailable, "store_error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) handleList(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := a.dbCtx(r)
	defer cancel()
	// BİLEREK index'siz: tenant üzerinde index yok, bu sorgu tüm tabloyu tarar (P02-05).
	links, err := a.store.ListByTenant(ctx, tenantOf(r), a.cfg.ListLimit)
	if err != nil {
		a.log.Error("list başarısız", "err", err, "request_id", RequestID(r.Context()))
		writeErr(w, r, http.StatusServiceUnavailable, "store_error")
		return
	}
	if links == nil {
		links = []store.Link{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"links": links})
}
