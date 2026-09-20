package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/shortcode"
	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/store"
)

type createReq struct {
	URL string `json:"url"`
}

func (a *API) handleCreate(w http.ResponseWriter, r *http.Request) {
	// EN: MaxBytesReader is the only thing standing between a 5 MB request body and the heap.
	//     Level 00 accepted it (measured: HTTP 201 for a 5 MB body straight to the pod). The 413
	//     that came back through the ingress was the INGRESS's default, not ours — a protection you
	//     did not design is a protection you cannot rely on.
	// TR: MaxBytesReader, 5 MB'lık bir gövde ile heap arasındaki tek şey. 00 bunu kabul ediyordu
	//     (ölçüldü: pod'a doğrudan 5 MB gövde → HTTP 201). Ingress'ten dönen 413 bizim değil
	//     INGRESS'in varsayılanıydı — tasarlamadığın koruma, güvenemeyeceğin korumadır.
	// [Topic · Konu: Kaynak sınırlama, katmanlı savunma]
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

	// EN: Generate, then insert conditionally, and retry on collision. Never "generate and hope".
	//     Level 00 overwrote silently: 3 users out of 10k lost their link with no error anywhere.
	// TR: Üret, koşullu ekle, çakışırsa tekrar dene. Asla "üret ve umut et" değil. 00 sessizce
	//     üzerine yazıyordu: 10 binde 3 kullanıcı, hiçbir yerde hata olmadan linkini kaybetti.
	for attempt := 0; attempt < a.cfg.CodeMaxAttempts; attempt++ {
		code, err := shortcode.New(a.cfg.CodeLength)
		if err != nil {
			writeErr(w, r, http.StatusInternalServerError, "rand_failed")
			return
		}
		l := &store.Link{Code: code, URL: target, CreatedAt: time.Now().UTC()}
		switch err := a.store.CreateUnique(l); {
		case err == nil:
			a.met.Create.WithLabelValues("ok").Inc()
			a.met.Links.Set(float64(a.store.Len()))
			writeJSON(w, http.StatusCreated, map[string]any{
				"code": code, "url": target, "short_url": "http://" + r.Host + "/" + code,
			})
			return
		case errors.Is(err, store.ErrExists):
			// Çakışma bir HATA değil, beklenen bir olay — ama GÖRÜNÜR olmalı: bu sayaç tırmanmaya
			// başlarsa kod uzayı doluyor demektir (00'da böyle bir sayaç yoktu, bu yüzden görünmezdi).
			a.met.Create.WithLabelValues("collision").Inc()
			continue
		default:
			writeErr(w, r, http.StatusInternalServerError, "store_error")
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
	l, ok := a.store.Get(code)
	if !ok {
		a.met.Redirect.WithLabelValues("not_found").Inc()
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
	a.store.IncrementClicks(code)
	a.met.Redirect.WithLabelValues("ok").Inc()

	// EN: 302 + no-store, not 301. A short link is REVOCABLE, so "moved permanently" is a lie the
	//     browser will hold you to: level 00 could not undo a redirect once Chrome had cached it,
	//     and every cached hit was a click that never reached the server.
	// TR: 301 değil, 302 + no-store. Kısa link GERİ ALINABİLİR, yani "kalıcı olarak taşındı" tarayıcının
	//     seni bağlayacağı bir yalan: 00'da Chrome bir kez önbelleğe aldıktan sonra yönlendirmeyi geri
	//     alamıyordun ve önbellekten dönen her tıklama sunucuya hiç ulaşmıyordu.
	// [Topic · Konu: HTTP önbellekleme, semantik]
	w.Header().Set("Cache-Control", "no-store, max-age=0")
	http.Redirect(w, r, l.URL, http.StatusFound)
}

func (a *API) handleGet(w http.ResponseWriter, r *http.Request) {
	l, ok := a.store.Get(r.PathValue("code"))
	if !ok {
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
	writeJSON(w, http.StatusOK, l)
}

func (a *API) handleDelete(w http.ResponseWriter, r *http.Request) {
	a.store.Delete(r.PathValue("code"))
	a.met.Links.Set(float64(a.store.Len()))
	w.WriteHeader(http.StatusNoContent)
}
