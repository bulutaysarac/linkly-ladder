package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"math/rand"
	"net/http"
	"regexp"
	"time"

	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/shortcode"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/store"
	"github.com/bulutaysarac/linkly-ladder/12-delivery/internal/tracing"
)

type createReq struct {
	URL string `json:"url"`
}

// dbCtx — her sorguya bir süre sınırı.
// EN: The client's context already carries the handler timeout, so why another one? Because they
//
//	answer different questions: the handler timeout protects the CALLER (stop waiting), the query
//	timeout protects the DEPENDENCY (stop asking). Without the second one a slow database keeps
//	accumulating work from clients who already gave up — see P02-06 and, in its full form, P10-03.
//
// TR: Client'ın context'i zaten handler timeout'unu taşıyor, o hâlde neden bir tane daha? Çünkü
//
//	farklı sorulara cevap veriyorlar: handler timeout ÇAĞIRANI korur (beklemeyi bırak), sorgu
//	timeout'u BAĞIMLILIĞI korur (sormayı bırak). İkincisi olmazsa yavaş bir veritabanı, çoktan
//	vazgeçmiş client'lardan iş biriktirmeye devam eder — bkz. P02-06 ve tam hâliyle P10-03.
//
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

// derlenmiş bir kez: doğru yol. TRAP_REGEX_PER_REQUEST bunu istek başına derlemeye çevirir.
var safeCodeRe = regexp.MustCompile(`^[A-Za-z0-9]{1,16}$`)

func (a *API) handleRedirect(w http.ResponseWriter, r *http.Request) {
	ctx0, span := tracing.Start(r.Context(), "redirect")
	defer span.End()
	r = r.WithContext(ctx0)
	code := r.PathValue("code")

	// "Kötü sürüm" simülasyonu (P12-01). Canary analizinin görevi bunu %10 trafikte YAKALAYIP
	// ilerlemeyi durdurmaktır — yani hatanın %100'e ulaşmasını engellemek.
	// Neden bir bayrak? Çünkü kasıtlı bir bug, yeniden üretilebilir bir bug'dır; ve dağıtım
	// güvenliğini test etmek için gerçekten bozuk bir sürüme ihtiyacın var.
	if a.cfg.BadVersionErrorPct > 0 && rand.Intn(100) < a.cfg.BadVersionErrorPct {
		a.met.Redirect.WithLabelValues("error").Inc()
		writeErr(w, r, http.StatusInternalServerError, "bad_version_simulated_error")
		return
	}

	// TRAP_REGEX_PER_REQUEST: istek başına regex DERLEMEK klasik bir CPU hot spot'tur.
	// Metriklerde görünmez (p99 hafif artar, CPU biraz yükselir), log'larda hiç görünmez —
	// yalnızca PROFİLDE görünür. Gözlemlenebilirliğin dördüncü ayağı budur (P11-08).
	if a.cfg.TrapRegexPerRequest {
		re := regexp.MustCompile(`^[A-Za-z0-9]{1,16}$`)
		if !re.MatchString(code) {
			a.met.Redirect.WithLabelValues("invalid").Inc()
			writeErr(w, r, http.StatusNotFound, "not_found")
			return
		}
	} else if !safeCodeRe.MatchString(code) {
		a.met.Redirect.WithLabelValues("invalid").Inc()
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
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

	// EN: This is the whole point of level 05. The redirect no longer writes to the database; it
	//     drops an event into a bounded in-process queue and returns. Record() never blocks and
	//     never fails — if the queue is full the click is DROPPED and counted as dropped.
	//     What used to be a row lock on the hottest row (P02-08) is now a channel send.
	// TR: 05'in bütün mesele bu. Redirect artık veritabanına yazmıyor; sınırlı bir süreç içi kuyruğa
	//     bir olay bırakıp dönüyor. Record() ne bloklar ne de hata döndürür — kuyruk doluysa tıklama
	//     DÜŞÜRÜLÜR ve düşürülmüş olarak sayılır. Eskiden en sıcak satırdaki bir satır kilidi olan
	//     şey (P02-08), artık bir kanal gönderimi.
	// [Topic · Konu: Okuma/yazma yolu ayrımı, asenkronizm]
	a.clicks.Record(code)

	a.met.Redirect.WithLabelValues("ok").Inc()
	// TRAP_REDIRECT_301: 01'de çözdüğümüz P00-10'u geri getirir. Burada tekrar karşımıza çıkmasının
	// sebebi YENİ: artık tıklamaları ciddi ciddi sayıyoruz ve tarayıcı önbelleği, sayılamayan
	// tıklamalar üretiyor. Aynı hata, farklı seviyede farklı bir zarar veriyor (P05-06).
	if a.cfg.TrapRedirect301 {
		http.Redirect(w, r, l.URL, http.StatusMovedPermanently)
		return
	}
	w.Header().Set("Cache-Control", "no-store, max-age=0")
	http.Redirect(w, r, l.URL, http.StatusFound)
}

// handleStats — GET /api/links/{code}/stats
func (a *API) handleStats(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := a.dbCtx(r)
	defer cancel()
	code := r.PathValue("code")
	st, err := a.store.Stats(ctx, code, a.cfg.StatsDays)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		writeErr(w, r, http.StatusServiceUnavailable, "store_error")
		return
	}
	// Dürüst ol: bu sayı BAYAT olabilir. Kuyruk henüz boşalmadıysa son saniyelerin tıklamaları
	// burada görünmez. Bir API'nin verdiği garantiyi söylemek, garantinin kendisi kadar önemlidir.
	w.Header().Set("X-Stats-Freshness", "eventual")
	writeJSON(w, http.StatusOK, st)
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
	// TRAP_UPDATE_DELAY_MS: DB yazımı ile önbellek geçersiz kılma arasındaki pencereyi BÜYÜT.
	// Cache-aside'ın klasik yarışı: bu pencerede gelen bir okuma, DB'den ESKİ değeri alıp önbelleğe
	// GERİ YAZAR ve bayat kayıt TTL boyunca yaşar. Pencere normalde mikrosaniyelerdir — küçük olması
	// yok olduğu anlamına gelmez (P04-05).
	if a.cfg.TrapUpdateDelayMs > 0 {
		defer time.Sleep(time.Duration(a.cfg.TrapUpdateDelayMs) * time.Millisecond)
	}
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

// handleDebugKeys — TRAP_DEBUG_KEYS (P04-07).
// EN: KEYS is O(N) and Redis is single threaded: while it walks a million keys, every redirect
//
//	waits. The safe equivalent is SCAN (cursor based, bounded per call) or simply a counter you
//	maintain yourself. "It is only a debug endpoint" is how this reaches production.
//
// TR: KEYS O(N)'dir ve Redis tek iş parçacıklıdır: bir milyon anahtarı gezerken HER redirect bekler.
//
//	Güvenli karşılığı SCAN'dir (imleç tabanlı, çağrı başına sınırlı) ya da kendi tuttuğun bir sayaç.
//	"Sadece debug ucu" cümlesi, bunun üretime nasıl ulaştığının tam açıklamasıdır.
func (a *API) handleDebugKeys(w http.ResponseWriter, r *http.Request) {
	if a.rdb == nil {
		writeErr(w, r, http.StatusNotFound, "not_found")
		return
	}
	start := time.Now()
	keys, err := a.rdb.Keys(r.Context(), "linkly:link:*").Result()
	if err != nil {
		writeErr(w, r, http.StatusServiceUnavailable, "redis_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"count": len(keys), "took_ms": time.Since(start).Milliseconds(),
		"warning": "KEYS Redis'i bloklar; üretimde SCAN kullan",
	})
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
	// TRAP_LIST_N_PLUS_ONE: liste 100 link döndürüyorsa, her biri için AYRI bir stats sorgusu.
	// Tek isteğin maliyeti sabit değil, sonuç kümesiyle DOĞRU ORANTILI olur — ve bu, sayfa
	// boyutunu artırdığın gün ortaya çıkar. Doğrusu tek bir toplu sorgudur (P07-06).
	if a.cfg.TrapListNPlusOne {
		enriched := make([]map[string]any, 0, len(links))
		for _, l := range links {
			st, err := a.store.Stats(ctx, l.Code, a.cfg.StatsDays)
			clicks := int64(0)
			if err == nil {
				clicks = st.Clicks
			}
			enriched = append(enriched, map[string]any{
				"code": l.Code, "url": l.URL, "tenant": l.Tenant,
				"clicks": clicks, "created_at": l.CreatedAt,
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{"links": enriched})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"links": links})
}
