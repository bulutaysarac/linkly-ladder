// Command linkly — seviye 00, "en ilkel hal". Tek dosya, bellek içi map, hiçbir koruma yok.
//
// EN: Everything wrong here is wrong on purpose. Each of the ten problems in the README is
//
//	caused by a line in this file; the README says which. Do not fix anything in this level —
//	the next level exists for that.
//
// TR: Buradaki her yanlış bilerek yanlış. README'deki on sorunun her biri bu dosyadaki bir
//
//	satırdan doğuyor; hangisi olduğunu README söylüyor. Bu seviyede hiçbir şeyi düzeltme —
//	bir sonraki seviye bunun için var.
package main

import (
	"encoding/json"
	"log"
	"math/rand"
	"net/http"
	"os"
	"time"
)

var version = "dev"

// EN: A plain map shared by every request goroutine, no mutex. Go's runtime detects
//
//	concurrent writes and aborts the whole process: "fatal error: concurrent map writes".
//
// TR: Her istek goroutine'inin paylaştığı düz map, mutex yok. Go runtime'ı eşzamanlı yazımı
//
//	yakalayıp süreci tümden çökertir. [Topic · Konu: Eşzamanlılık] → P00-01
var links = map[string]string{}
var clicks = map[string]int{}
var created = map[string]time.Time{}

const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

// EN: 4 chars of base62 = 14.8M codes. Birthday paradox: ~50% chance of a collision by 4.5k links,
//
//	and a collision silently overwrites someone else's link.
//
// TR: 4 karakter base62 = 14,8 M kod. Doğum günü paradoksu: ~4,5 k linkte %50 çakışma ve çakışma
//
//	başkasının linkini sessizce ezer. [Topic · Konu: Anahtar üretimi] → P00-05
func newCode() string {
	b := make([]byte, 4)
	for i := range b {
		b[i] = alphabet[rand.Intn(len(alphabet))]
	}
	return string(b)
}

type createReq struct {
	URL string `json:"url"`
}

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("POST /api/links", func(w http.ResponseWriter, r *http.Request) {
		var req createReq
		// EN: No body limit, no URL validation. A 100 MB body is decoded into memory; "javascript:"
		//     and "http://10.0.0.1" are accepted as targets.
		// TR: Body limiti yok, URL doğrulaması yok. 100 MB body belleğe açılır; "javascript:" ve
		//     "http://10.0.0.1" hedef olarak kabul edilir. [Topic · Konu: Güvenlik, giriş doğrulama] → P00-06
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		code := newCode()
		links[code] = req.URL // → P00-01, P00-05
		created[code] = time.Now()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(map[string]string{
			"code": code, "url": req.URL, "short_url": "http://" + r.Host + "/" + code,
		})
	})

	mux.HandleFunc("GET /api/links/{code}", func(w http.ResponseWriter, r *http.Request) {
		code := r.PathValue("code")
		url, ok := links[code]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"code": code, "url": url, "clicks": clicks[code], "created_at": created[code],
		})
	})

	mux.HandleFunc("DELETE /api/links/{code}", func(w http.ResponseWriter, r *http.Request) {
		delete(links, r.PathValue("code"))
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("GET /{code}", func(w http.ResponseWriter, r *http.Request) {
		code := r.PathValue("code")
		url, ok := links[code]
		if !ok {
			http.NotFound(w, r)
			return
		}
		clicks[code]++ // → P00-01 (okuma yolunda da yazım var)
		// EN: 301 with no Cache-Control: browsers cache it permanently. Delete the link, the browser
		//     still redirects; every later click never reaches the server.
		// TR: Cache-Control'süz 301: tarayıcı kalıcı önbellekler. Linki sil, tarayıcı hâlâ yönlendirir;
		//     sonraki hiçbir tıklama sunucuya ulaşmaz. [Topic · Konu: HTTP önbellekleme] → P00-10
		http.Redirect(w, r, url, http.StatusMovedPermanently)
	})

	// EN: No /healthz, no /readyz, no /metrics. Kubernetes cannot tell "running" from "serving";
	//     Prometheus sees only what cAdvisor reports about the container.
	// TR: /healthz, /readyz, /metrics yok. Kubernetes "çalışıyor" ile "hizmet veriyor"u ayıramaz;
	//     Prometheus sadece cAdvisor'ın konteyner hakkında söylediğini görür. → P00-04, P00-09

	addr := ":8080"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}
	log.Printf("linkly %s listening on %s", version, addr)
	// EN: Default server: no ReadHeaderTimeout, no IdleTimeout, no graceful shutdown. A client that
	//     opens a connection and never finishes its request holds a goroutine forever; SIGTERM kills
	//     in-flight requests mid-response.
	// TR: Varsayılan sunucu: ReadHeaderTimeout yok, IdleTimeout yok, graceful shutdown yok. Bağlantı
	//     açıp isteğini hiç bitirmeyen client bir goroutine'i sonsuza dek tutar; SIGTERM işlenmekte
	//     olan istekleri yarıda keser. [Topic · Konu: Timeout, kapatma sırası] → P00-04, P00-07
	log.Fatal(http.ListenAndServe(addr, mux))
}
