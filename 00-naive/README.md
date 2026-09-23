# 00 — naive · "Tek dosya, tek pod, bellek"

## 1. Bu seviye ne?

Bir URL kısaltıcının akla gelen en kısa hali: tek `main.go`, bellekte bir `map`, korumasız. Kubernetes'te
1 replika olarak çalışır ve gerçekten link kısaltır. Burada hiçbir şeyi düzeltmiyoruz — amaç, "çalışan" bir
şeyin kaç farklı şekilde kırıldığını **kendi gözünle görmek** ve merdivenin geri kalanına gerekçe üretmek.

## 2. Mimari

```mermaid
flowchart LR
  C([client / tarayıcı]) --> I[ingress-nginx<br/>lvl00.localtest.me]
  I --> P["linkly pod × 1<br/>map[string]string<br/>(mutex yok)"]
  P -. "yok: probe, metrics,<br/>timeout, doğrulama, kalıcılık" .-> X[ ]
  style X fill:none,stroke:none
```

Tek bileşen, tek replika, durum süreç belleğinde. Prometheus uygulamayı **scrape edemez** (metrik ucu yok);
sadece cAdvisor/kube-state-metrics üzerinden konteyner seviyesinde görünür.

## 3. Önceki seviyeden çözülenler

Yok — bu ilk basamak. `problems/SOLVES` boş.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **yalnızca temel yığın (kind, ingress, Prometheus, Grafana)**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl00.localtest.me/$code   # 301 → https://example.com (01'den itibaren 302 — neden: P00-10)
make grafana       # Ladder klasörü, level=lvl00 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P00-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyenin farkları: `GET /{code}` **301** döner (01'den itibaren 302), `X-Tenant-ID` yok sayılır,
`/healthz`, `/readyz`, `/metrics` **yoktur**.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P00-01 | Eşzamanlı map yazımı → süreç çöker | `make repro P=P00-01` | Pods & Resources → Restart / Son sonlanma nedeni | 01 |
| P00-02 | Restart = tüm linkler kaybolur | `CONFIRM=1 make repro P=P00-02` | App Business → links_total (sıfırlanır) | 02 |
| P00-03 | `replicas>1` → rastgele 404 | `CONFIRM=1 make repro P=P00-03` | App Business → redirect 404 by pod | 02 |
| P00-04 | Rollout sırasında hata dalgası | `make repro P=P00-04` | k6 → failed rate; App RED → 5xx | 01 |
| P00-05 | 4 karakter kod, çakışma kontrolü yok | `make repro P=P00-05` | (görünmez — metrik yok) | 01 |
| P00-06 | Giriş doğrulaması yok | `make repro P=P00-06` | Security → unsafe reddi (hep 0) | 01 |
| P00-07 | Sunucu timeout'u yok (slowloris) | `make repro P=P00-07` | Pods & Resources → Goroutine (01'de) | 01 |
| P00-08 | Bellek sınırsız → OOMKilled | `make repro P=P00-08` | Pods & Resources → working set + OOMKilled | 01 (ölçüm) · 02 (asıl) |
| P00-09 | Gözlemlenebilirlik sıfır | `make repro P=P00-09` | App RED / App Business tamamen boş | 01 |
| P00-10 | 301 + Cache-Control yok | `make repro P=P00-10` | App Business → redirect ok/s (eksik sayar) | 01 |

---

### P00-01 · Eşzamanlı map yazımı → süreç çöker

**Belirti:** Yük altında pod aniden restart eder; loglarda `fatal error: concurrent map writes`.
**Neden:** `links`, `clicks`, `created` map'leri her istek goroutine'i tarafından kilitsiz yazılıyor
(`cmd/linkly/main.go` — `links[code] = req.URL` ve `clicks[code]++`). Go runtime'ı eşzamanlı map yazımını
tespit ederse süreci **tümden** öldürür: recover edilemez. [Topic · Konu: Eşzamanlılık, veri yarışı]

**Reproduce (adım adım):**
1. `make up`
2. `kubectl -n lvl00 get pods -w` (ikinci terminal)
3. `make load S=create K6_ARGS="--vus 50 --duration 30s"`
4. 5–20 sn içinde pod `RESTARTS` sayacı artar
5. `kubectl -n lvl00 logs -l app.kubernetes.io/name=linkly --previous | head -20` → `concurrent map writes`
6. Otomatik: `make repro P=P00-01`

**Grafana:** `01 · Pods & Resources` → "Restart sayısı", "Son sonlanma nedeni" (=`Error`).
PromQL: `kube_pod_container_status_restarts_total{namespace="lvl00"}`

**Ölçüm notu:** Script deneye **taze bir pod** ile başlar (`ensure_fresh_pod`). Sebep: pod bir kez
CrashLoopBackOff'a düştüğünde kubelet'in geri çekilme süresi 5 dakikaya kadar çıkar; o pencerede
restart sayacı **donar** ve "restart arttı mı?" ölçümü yanlış negatif verir. Bu yüzden asıl kanıt
sayaç değil, Go runtime'ın ölüm mesajıdır: `fatal error: concurrent map writes`.
**Nerede çözülüyor:** 01 (`sync.RWMutex` ile korunan store). Dikkat: mutex *doğru* çözüm değil, *yeterli*
çözüm — asıl çözüm durumu süreç dışına almak (02).

---

### P00-02 · Restart = tüm linkler kaybolur

**Belirti:** Pod yeniden başlayınca daha önce üretilmiş her kısa link 404 döner.
**Neden:** Tek gerçek kaynak süreç belleği. Konteyner ölünce (deploy, OOM, crash, node drain) veri gider.
[Topic · Konu: Durum yönetimi, kalıcılık]

**Reproduce (adım adım):**
1. `code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code)`
2. `curl -s -o /dev/null -w '%{http_code}\n' http://lvl00.localtest.me/$code` → `301`
3. `kubectl -n lvl00 delete pod -l app.kubernetes.io/name=linkly`
4. Pod hazır olunca aynı curl → `404`
5. Otomatik: `CONFIRM=1 make repro P=P00-02`

**Grafana:** `03 · App Business` → "links_total" — 00'da bu panel boş (metrik yok), yani **kaybı ölçemezsin
bile**. 01'de sayaç görünür ve restartta sıfıra düşer.
**Nerede çözülüyor:** 02 (Postgres). Not: P00-01 ve P00-08 bu sorunu *sürekli* tetikler — çökme ve OOM
zaten restart demek.

---

### P00-03 · `replicas>1` → rastgele 404

**Belirti:** İki replikaya çıkınca aynı kısa link bazen çalışır, bazen 404 verir.
**Neden:** Her pod'un kendi map'i var; Service istekleri rastgele dağıtır. N replikada bir linki bulma
olasılığı 1/N. [Topic · Konu: Yatay ölçekleme, stateless servis]

**Reproduce (adım adım):**
1. `kubectl -n lvl00 scale deploy/linkly --replicas=3`
2. Bir link oluştur (yalnızca bir pod'un belleğine yazılır)
3. `for i in $(seq 60); do curl -s -o /dev/null -w '%{http_code} ' http://lvl00.localtest.me/$code; done`
4. Yaklaşık üçte ikisi `404` — ölçülen tur: **60 okumadan 40'ı 404 (%66)**
5. Otomatik: `CONFIRM=1 make repro P=P00-03`

**Ölçüm notu:** Script ölçekledikten sonra Service endpoint'lerinin gerçekten 3'e çıkmasını bekler.
Beklemezsen ingress'in upstream listesi birkaç saniye geriden gelir, tüm istekler tek pod'a düşer ve
sonuç yanlış negatif olur (ilk denemede tam olarak bu oldu: 30 okumada 0 adet 404).

**Grafana:** `03 · App Business` → "redirect 404 by pod" (01+ dolu). 00'da yalnızca ingress'in gördüğü
404'ler üzerinden dolaylı bakabilirsin.
**Nerede çözülüyor:** 02. Bu, "ölçeklenebilirlik" sözünün neden **stateless** ile başladığının kanıtı.

---

### P00-04 · Rollout sırasında hata dalgası

**Belirti:** `kubectl rollout restart` sırasında client'lar 502/503 alır, bağlantılar yarıda kopar.
**Neden:** İki eksik: (a) readinessProbe yok → Kubernetes yeni pod'u hazır saymadan Endpoint'e ekler,
(b) graceful shutdown yok → SIGTERM gelince süreç işlenmekte olan istekleri bırakıp ölür. Ayrıca preStop
gecikmesi olmadığı için pod, ingress'in endpoint listesinden düşmeden önce ölmeye başlar.
[Topic · Konu: Kapatma sırası, hazır olma sinyali]

**Reproduce (adım adım):**
1. `make load S=redirect K6_ARGS="--vus 30 --duration 40s"` (ikinci terminal)
2. 10 sn sonra: `kubectl -n lvl00 rollout restart deploy/linkly`
3. k6 özetinde **5xx** sayısı > 0 (ölçülen tur: 142 adet)
4. Otomatik: `make repro P=P00-04`

**Ölçüm notu (önemli):** Yük **tek VU** ile verilir. Paralel istek P00-01'i tetikler, hata oranı %99'a
fırlar ve "rollout mu çökme mi kaybettirdi?" ayırt edilemez. Ayrıca k6'nın tek bir `http_req_failed`
oranına bakmak yanıltır: rollout'tan sonra gelen **404'ler P00-02'dir** (yeni pod'un belleği boş),
rollout penceresinin kendisi ise **5xx** üretir. Bu yüzden senaryolar 5xx ve 404'ü ayrı sayar.

**Grafana:** `15 · k6` → "failed rate" tepe yapar; `01 · Pods & Resources` → pod değişimi aynı anda.
**Nerede çözülüyor:** 01 (probe'lar + `preStop` + `Server.Shutdown` sırası).

---

### P00-05 · 4 karakterlik kod, çakışma kontrolü yok

**Belirti:** Yeterince link üretince iki farklı kullanıcı aynı kodu alır; ilkinin linki **sessizce** ikinciyle
değişir. Hata yok, log yok.
**Neden:** `newCode()` 4 karakter base62 üretiyor (62⁴ ≈ 14.8 M) ve `links[code] = url` mevcut kaydı kontrol
etmeden üzerine yazıyor. Doğum günü paradoksu: ~4.5 k linkte %50 çakışma olasılığı. Ayrıca `math/rand`
tahmin edilebilir. [Topic · Konu: Anahtar üretimi, doğum günü paradoksu]

**Reproduce (adım adım):**
1. `make repro P=P00-05` — 10.000 link üretir (sıralı, ~2 dk), kodların benzersizliğini sayar
2. Script "N üretim, M benzersiz → K çakışma" der ve çakışan kodun **şu an kime ait olduğunu** gösterir
3. Ölçülen tur: **10000 üretim, 9997 benzersiz → 3 çakışma** (beklenen n²/2N = 3.4 ile birebir)

**Ölçüm notu:** Üretim **sıralı** yapılır. Paralel denersen P00-01 devreye girer: süreç çöker, üretim
durur, map sıfırlanır ve çakışmayı ölçemezsin (ilk denemede 10.000 istekten yalnızca 362'si tamamlandı).
**Sorunlar birbirini maskeler** — bir katmandaki hata, alttakini görünmez yapar. Bu, merdivenin
tekrar tekrar karşına çıkacak dersi.

**Grafana:** Görünmez. `03 · App Business` → "create sonuçları" panelinde `collision` serisi olurdu ama
00'da böyle bir metrik yok — **sessiz veri kaybının en saf örneği**.
**Nerede çözülüyor:** 01 (`crypto/rand`, 7 karakter, `CreateUnique` + retry, `create_total{result="collision"}` sayacı).

---

### P00-06 · Giriş doğrulaması yok

**Belirti:** `javascript:alert(1)`, `http://169.254.169.254/...`, boş URL ve 5 MB'lık gövde kabul edilir.
**Neden:** Handler `json.Decode` dışında hiçbir kontrol yapmıyor: şema allowlist'i yok, host kontrolü yok,
`MaxBytesReader` yok. Kısaltıcı **güvenilir görünen** bir link üretip tarayıcıyı hedefe yolladığı için bu bir
open-redirect ve (kurum içi tarayıcılarda) iç ağa yönlendirme yüzeyidir. [Topic · Konu: Giriş doğrulama, open redirect]

**Reproduce (adım adım):**
1. `curl -s -XPOST .../api/links -d '{"url":"javascript:alert(1)"}'` → `201`
2. `curl -I .../<code>` → `Location: javascript:alert(1)`
3. `curl -s -XPOST .../api/links -d '{"url":"http://169.254.169.254/latest/meta-data/"}'` → `201`
4. 5 MB gövde **ingress üzerinden** → `413`; **doğrudan pod'a** (port-forward) → `201`
5. Otomatik: `make repro P=P00-06`

**Ölçüm notu:** Ingress'ten gelen 413'ü **uygulama vermiyor** — ingress-nginx'in varsayılan
`proxy-body-size: 1m` limiti veriyor. Yani koruma, senin tasarlamadığın bir katmandan tesadüfen geldi.
Bu yüzden script uygulamanın kendi davranışını görmek için ingress'i atlayıp doğrudan pod'a bağlanır:
uygulama 5 MB'ı sorunsuz belleğe alır. **Başkasının verdiği korumaya güvenemezsin** — o katman
yarın değişir, kaldırılır ya da atlanır (servis-içi çağrı, port-forward, service mesh bypass).

**Grafana:** `14 · Security` → "unsafe URL reddi by reason" — 00'da hep 0, çünkü hiçbir şey reddedilmiyor.
`01 · Pods & Resources` → büyük gövdede working set sıçraması.
**Nerede çözülüyor:** 01 (şema allowlist, host kontrolü, `MaxBytesReader`) · 13 (DNS çözümü ile özel IP reddi).
Not: Bu bir *azaltma*, eliminasyon değil — 13'te TOCTOU sınırı anlatılıyor.

---

### P00-07 · Sunucu timeout'u yok (slowloris)

**Belirti:** Birkaç yüz yavaş/yarım bağlantı normal istekleri yavaşlatır; pod CPU'su neredeyse boştur.
**Neden:** `http.ListenAndServe` varsayılanları: `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout`,
`IdleTimeout` **hiçbiri yok**. İsteğini bitirmeyen her bağlantı bir goroutine ve bir soket tutar; sunucu
kendini korumaz. [Topic · Konu: Timeout, kaynak tükenmesi]

**Reproduce (adım adım):**
1. `make repro P=P00-07` — doğrudan pod'a bağlanır (ingress'i atlar), yarım bir istek gönderir, 20 sn bekler
2. Soru: **sunucu bu boşta duran yarım bağlantıyı kapattı mı?** 00'da kapatmaz — açık tutar
3. Sonra 300 yarım bağlantı açar; hepsi kabul edilir ve tutulur (her biri bir goroutine + bir FD)
4. Ölçülen tur: `20 sn sonra AÇIK TUTUYOR, 300 bağlantı birikti`

**Ölçüm notu 1:** Ingress üzerinden ölçmek işe yaramaz — ingress-nginx yarım bağlantıları kendi
timeout'larıyla yutar (yine P00-06'daki ders: koruma senin değil).
**Ölçüm notu 2:** Go'da slowloris **yeni istekleri yavaşlatmaz** (her bağlantı kendi goroutine'inde,
Apache'deki gibi worker havuzu tükenmesi yok). Gerçek belirti birikmedir: goroutine, FD ve bellek.
Bu yüzden test "yavaşladı mı?" diye değil, **"sunucu hiç kapatıyor mu?"** diye sorar — `ReadHeaderTimeout`
olsaydı saniyeler içinde kapatırdı. Aynı script 01'de NOT-REPRODUCED verir.

**Grafana:** `01 · Pods & Resources` → "Goroutine" (01'den itibaren). 00'da **bu paneli dolduramıyorsun** —
yani sorunun varlığını sunucu tarafından kanıtlayamıyorsun; bu, P00-09'un pratik sonucu.
**Nerede çözülüyor:** 01 (`ReadHeaderTimeout`, `IdleTimeout`, istek başına timeout middleware).

---

### P00-08 · Bellek sınırsız büyür → OOMKilled

**Belirti:** Yük sürdükçe working set 128 Mi limitine tırmanır, konteyner `OOMKilled` olur, restart eder —
ve P00-02 gereği tüm linkler gider.
**Neden:** Store'da eviction yok, TTL yok, üst sınır yok. Bellek = sınırsız kuyruk: sonu ertelenmiş çöküş.
[Topic · Konu: Bounded resources, kapasite planlaması]

**Reproduce (adım adım):**
1. `kubectl -n lvl00 get pods -w` (ikinci terminal)
2. `make repro P=P00-08` — tek akışla 4 KB'lık URL'ler üretir (2 dk)
3. `kubectl -n lvl00 describe pod … | grep -A3 'Last State'` → `OOMKilled`, `Exit Code: 137`
4. Ölçülen tur: `restart 0 → 3 · son sonlanma: OOMKilled (exit 137)`

**Ölçüm notu 1 (ayrım):** Yine tek VU. Paralel denediğimizde `reason=Error` çıkıyordu — bu **OOM değil,
P00-01 çökmesi**. Script bu ikisini ayırır: `OOMKilled` → P00-08, `Error` → P00-01 (ve "ölçüm kirlendi" der).
**Ölçüm notu 2 (örnekleme):** Grafana'daki tepe bellek değeri limitin **altında** görünür (ölçülen turda
6 MB / 128Mi). Sebep: Prometheus 15 sn'de bir örnekliyor, konteyner iki örnek arasında dolup ölüyor.
Yani *metrik grafiği olayı kaçırabilir*; asıl kanıt `OOMKilled` + `exit 137`. Örnekleme çözünürlüğünün
gerçeği gizlemesi 11'de (sampling, exemplar) tekrar karşına çıkacak.

**Grafana:** `01 · Pods & Resources` → "Bellek working set" (limit çizgisiyle birlikte), "Son sonlanma nedeni".
PromQL: `container_memory_working_set_bytes{namespace="lvl00"}`
**Nerede çözülüyor:** 01 kısmen (ölçüm + `links_total`), asıl 02 (durum DB'de) · 03 (bounded LRU).

---

### P00-09 · Gözlemlenebilirlik sıfır

**Belirti:** "Son 5 dakikada kaç 404 döndük?", "p99 kaç ms?", "hangi endpoint yavaş?" — hiçbirini
cevaplayamazsın.
**Neden:** `/metrics` ucu yok, yapılandırılmış log yok, request-id yok. Prometheus'un gördüğü tek şey
cAdvisor ve kube-state-metrics: CPU, bellek, restart. Bunlar **altyapı** metrikleri; uygulama hakkında
hiçbir şey söylemezler. [Topic · Konu: Gözlemlenebilirlik, RED metrikleri]

**Reproduce (adım adım):**
1. `make repro P=P00-09` — 30 başarılı + 10 başarısız istek üretir, sonra ölçmeyi dener
2. `curl -s -o /dev/null -w '%{http_code}\n' http://lvl00.localtest.me/metrics` → `404`
3. Prometheus'ta `http_requests_total{namespace="lvl00"}` → boş sonuç
4. Grafana → `02 · App RED` ve `03 · App Business` → tüm paneller "No data"

**Grafana:** Boş olmasının **kendisi** kanıt. `01 · Pods & Resources` dolu (cAdvisor), diğerleri boş.
**Nerede çözülüyor:** 01 (Prometheus metrikleri sıfırla pre-register, slog JSON, request-id, ServiceMonitor).

---

### P00-10 · 301 + `Cache-Control` yok

**Belirti:** Chrome'da bir kısa linki açtıktan sonra linki silsen bile tarayıcı yönlendirmeye devam eder;
tıklamalar sayılmaz.
**Neden:** `http.Redirect(..., http.StatusMovedPermanently)` ve hiçbir önbellek başlığı yok. 301 "bu eşleme
kalıcıdır" demektir; tarayıcı bunu süresiz saklayabilir ve bir daha sunucuya sormaz. Kısa link eşlemesi
**iptal edilebilir** olduğu için 301 yanlış sözdür. [Topic · Konu: HTTP önbellekleme, semantik]

**Reproduce (adım adım):**
1. `make repro P=P00-10` — durum kodu ve `Cache-Control` başlığını gösterir
2. Elle (asıl ikna edici olan): Chrome'da `http://lvl00.localtest.me/<code>` aç
3. `curl -XDELETE http://lvl00.localtest.me/api/links/<code>`
4. Chrome'da aynı adresi tekrar aç → hâlâ yönlendirir (Network sekmesinde `(disk cache)`)
5. `curl -I` ile aynı adres → `404`

**Grafana:** `03 · App Business` → "redirect ok/s" gerçek tıklamanın altında kalır (tarayıcı sunucuya
uğramıyor). 05'te bu, analitiklerin neden eksik saydığının kökü olarak geri gelir (P05-06).
**Nerede çözülüyor:** 01 (`302` + `Cache-Control: no-store`).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

Bu seviyede TRAP bayrağı **yok**: 00'ın tamamı zaten bir tuzak. İlk `TRAP_*` bayrakları 01'de gelir
(`TRAP_METRIC_LABEL_CODE`, `TRAP_LIVENESS_STRICT`).

Elle denemeye değer:
- `kubectl -n lvl00 scale deploy/linkly --replicas=5` → P00-03'ü sertleştir, 404 oranını ölç.
- `make load S=scan` → var olmayan kodlara tarama; 00'da bunu metrikten göremezsin (P00-09).
- `make load S=hot-key` → tek koda yoğun trafik; 00'da `clicks[code]++` bir veri yarışı daha (P00-01).

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| `00 · Overview` | Kısmen | Pod/restart satırları dolu; availability/p99 boş (uygulama metriği yok) |
| `01 · Pods & Resources` | **Dolu** | cAdvisor + kube-state-metrics; Go runtime satırları boş (01'de gelir) |
| `15 · k6` | **Dolu** | Client tarafı; yükü buradan görürsün — sunucudan değil |
| `02 · App RED` | Boş | P00-09: `/metrics` yok |
| `03 · App Business` | Boş | P00-09 |
| `04 · Cache` … `14 · Security` | Boş | Bu seviyede o bileşenler yok |

Bu tablo merdivenin ana fikri: **panel boşsa, o sorunu göremezsin; göremediğin sorunu çözemezsin.**

## 9. Bilerek bırakılanlar

Her şey. Bu seviye çözüm üretmez, sorun kataloğu üretir. Özellikle:

- Kalıcılık yok, paylaşılan durum yok, ölçeklenemez (02'ye kadar).
- Kimlik/tenant yok — `X-Tenant-ID` gönderebilirsin, hiçbir etkisi yok (13).
- Rate limit yok: tek client tüm kapasiteyi alabilir (01 süreç içi, 08 dağıtık).
- Analitik yok: `clicks` sayacı bellekte, yarışlı ve restartta sıfırlanıyor (05).
- Testler yok: `go test ./...` boş geçer. 01'den itibaren her seviye kendi testleriyle gelir.

## 10. `make diff-prev` okuma rehberi

Önceki seviye olmadığı için `make diff-prev` bir şey göstermez. Bunun yerine **01'e geçtiğinde**
`cd ../01-hardened && make diff-prev` çalıştır ve şu üç şeye bak:

1. `cmd/linkly/main.go` küçülür, `internal/` doğar — tek dosya kaybolmaz, **katmanlara ayrılır**.
2. `deploy/deployment.yaml`: probe'lar, `terminationGracePeriodSeconds`, `preStop`, ServiceMonitor eklenir.
   Her satırın karşılığı yukarıdaki bir P00-XX sorunudur.
3. `problems/SOLVES`: 01'in hangi sorunları kapattığını **makine-okunur** biçimde ilan eder;
   `make verify-prev` bu listeyi doğrular.
