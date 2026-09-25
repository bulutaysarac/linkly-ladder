# 01 — hardened · "Tek süreç ama düzgün"

> **Bu seviyede ne yaşayacaksın?**
> - 00'ın çöküşünün, dağıtım hatalarının ve slowloris'in kapanması — `make verify-prev` 00'ın sorunlarını burada koşup gösterir
> - Restart'ta linklerin hâlâ gitmesi, ama artık panelde görünmesi (P01-01); ölçeklenememenin pod bazında görünmesi (P01-02)
> - Tek replika + PodDisruptionBudget'ın koruma sağlamaması (P01-03); belleğin OOM'dan önce görünmesi (P01-04)
> - Süreç içi hız sınırının N replikada N katına çıkması (P01-05); tıklama sayacının hâlâ istek yolunda olması (P01-08)
> - Tuzaklar: kısa kodu metrik etiketi yapmak (P01-06); sağlık uçlarını iş zincirinin arkasına koymak (P01-07)
>
> **Bu seviye olmasa ne olur?** 00'ın çöküşleri ve dağıtım hataları sürer; sonraki seviyelerin her sorunu 01'in eklediği metriklerle ölçülür — metrik yoksa "sorun var mı?" sorusunun cevabı tahmindir.
>
> **Yeni gelen teknolojiler:** `sync.RWMutex`, readiness/liveness probe, graceful shutdown, `log/slog` (JSON log), `/metrics` (client_golang), ServiceMonitor, PodDisruptionBudget ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

00 ile aynı tek süreç ve aynı bellek içi depo, ama disiplinle: kilit, probe, düzgün kapanma, timeout'lar, giriş
doğrulama, hız sınırı, metrikler ve JSON log. Kalıcılık ve ölçek hâlâ yok; o sorunlar burada ilk kez ölçülebilir
hale gelir, çözümü 02'de.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress-nginx<br/>lvl01.localtest.me]
  I --> M

  subgraph P["linkly pod × 1"]
    direction TB
    M["middleware zinciri<br/>recover → requestID → accessLog<br/>→ timeout → rateLimit"]
    H["handlers<br/>create · redirect · get · delete"]
    S["store.Memory<br/>RWMutex + CreateUnique"]
    M --> H --> S
  end

  P -.->|/metrics| PR[(Prometheus)]
  P -.->|stdout JSON| LK[(Loki)]
  K[kubelet] -.->|/readyz /healthz<br/>zincirin DIŞINDA| P
```

Her istek sırayla ara katmanlardan (middleware) geçer: panik yakalama en dışta, hız sınırı en sonda. Sağlık ve
metrik uçları bu zincirin **dışında**, yük altında probe düşmesin diye (bozmak bir alıştırma: P01-07).

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P00-01 | Aynı anda gelen yazmalar uygulamayı çökertir | Link tablosuna yazmadan önce kilit alınır, yazmalar sıraya girer (`sync.RWMutex`) |
| P00-04 | Yeni sürüm dağıtılırken istekler hata alır | Pod hazır olunca sinyal verir (readiness/liveness probe); yenisi hazır olmadan eskisi kapatılmaz (`maxUnavailable: 0`); eski pod önce trafikten çıkar, bekler (`preStop`), elindeki istekleri bitirip kapanır (`Shutdown`) |
| P00-05 | İki kullanıcı aynı kısa kodu alıp birbirinin linkini ezebilir | Kod 7 karakter ve tahmin edilemez rastgelelikle üretilir (`crypto/rand`); kod zaten varsa yenisi denenir |
| P00-06 | Zararlı URL'ler (`javascript:`, iç ağ adresi) ve dev istekler kabul edilir | Yalnızca `http`/`https` kabul edilir, iç ağ adresleri reddedilir, istek gövdesi 8 KB ile sınırlı |
| P00-07 | İsteğini bitirmeyen istemciler bağlantıyı sonsuza kadar tutar | Sunucuya zaman aşımları eklenir (başlık 3 sn, okuma 10 sn, boşta bağlantı 60 sn) ve her istek en fazla 5 sn sürebilir |
| P00-09 | Uygulamanın ne yaptığını gösteren hiçbir sayı yok | Uygulama metrik yayınlar (`/metrics`), her isteği istek kimliğiyle bir JSON log satırı olarak yazar; Prometheus bunları toplar (ServiceMonitor) |
| P00-10 | Silinen link tarayıcıda çalışmaya devam eder | Yönlendirme geçici (`302`) ve "saklama" başlığıyla (`Cache-Control: no-store`) döner |

Açık kalanlar: linklerin yeniden başlamada kaybolması (P00-02), uygulamanın büyütülememesi (P00-03) ve sınırsız bellek (P00-08) burada da var — ama artık ölçülebiliyorlar (P01-01, P01-02, P01-04); çözümleri 02 ve 03'te.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana)**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/01-hardened"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl01.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl01 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P01-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl01 ayakta` yazar:
```bash
cd "$LADDER/00-naive"
make down
cd "$LADDER/01-hardened"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/01-hardened"
make up
```
2. 00'ın sorunlarını burada koş (~15 dk; koşarken başka komut çalıştırma). `BEKLENEN` sütunu `NOT-REPRODUCED` olan
   satırlar bu seviyenin çözdüğünü iddia ettikleri; sonuç uymazsa satır `✘` alır:
```bash
cd "$LADDER/01-hardened"
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P01-01 → P01-08): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç.
4. Bitince ayarları geri al ve seviyeyi kapat:
```bash
cd "$LADDER/01-hardened"
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyede yeni: `GET /{code}` **302** + `Cache-Control: no-store`; `/healthz`, `/readyz`, `/metrics` var; güvensiz
hedef `400 unsafe_url:<sebep>`, büyük gövde `413`, limit aşımı `429 + Retry-After`.

## 6. Reproduce edilebilir sorunlar

Bu seviyede yaşayacağın 8 sorun. Her birini iki yoldan görebilirsin: **Otomatik** — `make repro P=<ID>` deneyi
kendisi yapar, ölçer ve hükmünü basar (`REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` =
ölçülemedi); **Elle** — adımları sırayla yapıştırıp sonucu kendi gözünle görürsün. Her sorunun bölümü aynı
düzende: **Ne oluyor** → **Neden oluyor** → **Bu deney** → adımlar → **Terminalde ne görmelisin** →
**Grafana'da gör** (giriş: admin / ladder) → **Nasıl çözülüyor**.

| ID | Ne olur? | Neden olur? | Nasıl çözülür? |
|---|---|---|---|
| P01-01 | Uygulama yeniden başlayınca bütün linkler yine kaybolur — ama kayıp artık bir grafikte görünür | Kilit çökmeyi durdurdu ama linkler hâlâ yalnızca programın belleğinde | **02:** linkler veritabanında tutulur |
| P01-02 | 3 kopyaya çıkınca aynı link yine bazen 404 verir — artık hangi kopyanın 404 verdiği görünür | Her kopyanın kendi belleği var; istek linki bilmeyen kopyaya düşerse link bulunamaz | **02:** bütün kopyalar aynı veritabanını okur |
| P01-03 | Tek kopyalı servisi korumak için konan kural (PDB) düğüm bakımını kilitler; bakım zorlanırsa servis kesilir | PDB "en az 1 kopya ayakta kalsın" der; tek kopya varken hiçbir kapatmaya izin verilmez. PDB yedek kopya üretmez | **02:** farklı makinelere yayılmış 3 kopya |
| P01-04 | Link eklendikçe bellek yine sınırsız büyür — ama artık çarpmadan önce grafikte görünür | Bellekteki link sayısının üst sınırı yok | **02** veriyi veritabanına taşır · **03** önbellek sınırlı boyutta |
| P01-05 | "Saniyede 50 istek" sınırı 3 kopyada saniyede 150'ye çıkar | Her kopya sınırı kendi belleğinde ayrı sayar; toplamı kimse bilmez | **08:** sınır sayacı bütün kopyaların ortak kullandığı Redis'te |
| P01-06 | **Tuzak:** kısa kod metriğe etiket olarak eklenince Prometheus'taki seri sayısı link sayısıyla birlikte patlar | Prometheus her farklı etiket değerini ayrı bir zaman serisi olarak saklar | **Bu seviyenin ayarı:** tuzağı kapat; tekil kimlikler loga ve trace'e gider (11) |
| P01-07 | **Tuzak:** yük artınca sağlıklı pod trafikten çıkarılır, sonunda yeniden başlatılır | Sağlık kontrolleri de hız sınırına takılıp "429" alır; Kubernetes pod'u hasta sanır | **Bu seviyenin ayarı:** tuzağı kapat; sağlık kontrolleri hız sınırının dışında |
| P01-08 | Her tıklama yönlendirmeyi bir kilitte bekletir; uygulama yeniden başlayınca tıklama sayıları sıfırlanır | Tıklama sayacı yönlendirme isteğinin içinde ve programın belleğinde | **05:** tıklamalar kuyruğa alınıp toplu yazılır · **06:** dayanıklı olay akışı |

---

### P01-01 · Restart = tüm linkler gider — ama artık görünür

**Ne oluyor:** Uygulama yeniden başlayınca (yeni sürüm, çökme, bellek dolması) bütün kısa linkler 00'daki gibi
kaybolur ve 404 döner. Fark şu: 01'de uygulama kaç link tuttuğunu bir metrikle (`links_total`) yayınlıyor; kayıp
artık grafikte dikey bir düşüş olarak görünür.
**Neden oluyor:** Kilit (mutex) aynı anda yazmaların çökertmesini durdurdu ama kalıcılık getirmedi: linklerin tek
kopyası hâlâ programın belleğinde. Program yeniden başladığında bellek boş başlar.
**Bu deney:** Bir "kanarya" link ve 25 link daha oluşturur, pod'un kaç link bildiğini okur; pod'u siler ve yeni
pod'da aynı linki ve sayacı tekrar okur.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P01-01` (25 link oluşturur, pod'u siler, sayacı ve
kanarya kodu yeniden okur). Elle:

1. Temiz başla; bir kanarya link ve 25 link daha oluştur, pod'un kaç link bildiğine bak:
```bash
cd "$LADDER/01-hardened"
make fresh
code=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0101"}' | jq -r .code); echo "kanarya kodu: $code"
for i in $(seq 1 25); do curl -s -o /dev/null -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d "{\"url\":\"https://example.com/$i\"}"; done
curl -s http://lvl01.localtest.me/metrics | grep '^links_total'
curl -s -o /dev/null -w 'restart öncesi: %{http_code}\n' http://lvl01.localtest.me/$code
```
2. Pod'u yenile, aynı kodu ve sayacı tekrar oku:
```bash
cd "$LADDER/01-hardened"
kubectl -n lvl01 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl01 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
curl -s -o /dev/null -w 'restart sonrası: %{http_code}\n' http://lvl01.localtest.me/$code
curl -s http://lvl01.localtest.me/metrics | grep '^links_total'
```

**Terminalde ne görmelisin:** önce `links_total 26` (önceki denemelerden kalanlarla daha fazla olabilir) ve
`restart öncesi: 302`; sonra `restart sonrası: 404` ve `links_total 0`: yeni pod boş başladı.

**Grafana'da gör:** [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) — pod'u sildikten sonra aç
- "Kayıtlı link sayısı (pod'a göre)" → eski pod'un çizgisi 25+ seviyesinde biter, yeni pod adıyla 0'dan bir çizgi başlar: dikey düşüş kaybın büyüklüğüdür.
- "Kayıtlı link sayısı" → restarttan sonra `0`.
- "Yönlendirme sonuçları" → restarttan sonra `not_found` serisinde küçük bir tümsek (kanarya kodu bulunamadı).

**Nasıl çözülüyor:** 02'de linkler Postgres veritabanında tutulur; pod'lar gelip gider, veri kalır. 01'in kazancı kaybı ölçebilmek: sayaç sıfıra düştüğünde alarm yazılabilir.

---

### P01-02 · Ölçeklenemez — ama artık pod bazında görünür

**Ne oluyor:** Uygulama 3 kopyaya (replika) çıkınca aynı kısa link isteklerin yaklaşık üçte ikisinde 404 verir;
uygulama hâlâ büyütülemez. 01'de her kopya kendi 404 sayısını yayınladığı için artık hangi kopyaların linki
bilmediği grafikte görünür.
**Neden oluyor:** Her kopyanın kendi belleği, dolayısıyla kendi link tablosu var. Link yalnızca onu oluşturan
kopyada; istekler kopyalara dağıtıldığı için çoğu, linki bilmeyen bir kopyaya düşer.
**Bu deney:** Tek kopya varken bir link oluşturur, 3 kopyaya çıkar, aynı linki 30 kez ister ve 404'leri sayar;
sonunda tek kopyaya döner.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P01-02` (3 replikaya çıkar, 60 kez okur, hangi pod'un
kaç 404 saydığını basar, geri alır). Elle:

1. Temiz başla; tek pod varken bir link oluştur:
```bash
cd "$LADDER/01-hardened"
make fresh
code=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0102"}' | jq -r .code); echo "kod: $code"
```
2. 3 replikaya çık, ingress'in yeni pod'ları görmesini bekle (beklemezsen hepsi tek pod'a gider), kodu 30 kez iste:
```bash
cd "$LADDER/01-hardened"
kubectl -n lvl01 scale deploy/linkly --replicas=3
kubectl -n lvl01 rollout status deploy/linkly
sleep 10
for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code} ' http://lvl01.localtest.me/$code; done; echo
```
3. Geri al:
```bash
cd "$LADDER/01-hardened"
kubectl -n lvl01 scale deploy/linkly --replicas=1
```

**Terminalde ne görmelisin:** 30 cevabın ~1/3'ü `302`, ~2/3'ü `404`: diğer iki pod linki hiç görmedi.

**Grafana'da gör:** [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s) — deney sırasında ya da hemen sonra aç
- "404 (pod'a göre)" → linkin yazıldığı pod'un çizgisi 0'da kalır, **diğer ikisi** yükselir: 404'ü linki hiç görmemiş pod'lar veriyor.
- "Yönlendirme sonuçları" → `ok` ile `not_found` yan yana; `not_found` kabaca iki katı.
- "Hazır pod adresi (endpoint) sayısı" → 1'den **3**'e çıkar, geri alınca 1'e döner: 404'ler pod sayısı arttığı an başlar.

**Nasıl çözülüyor:** 02'de bütün kopyalar aynı veritabanını okur; kopya sayısı artık doğruluğu etkilemez.

---

### P01-03 · Tek replika + PDB = güvenlik yanılsaması

**Ne oluyor:** Servisi korumak için bir PodDisruptionBudget (PDB — "bakım sırasında en az şu kadar kopya ayakta
kalsın" kuralı) tanımlı; ama tek kopya olduğu için iki kötü sonuçtan biri kaçınılmaz: düğüm bakımı (`kubectl drain`)
hiç ilerlemez ve zaman aşımına düşer, ya da bakımı zorlarsan servis kesilir.
**Neden oluyor:** PDB "en az 1 kopya ayakta kalsın" der. Tek kopya kapatılırsa kural bozulacağı için hiçbir
kapatmaya izin verilmez (`ALLOWED DISRUPTIONS 0`). PDB yedek kopya üretmez, yalnızca var olan yedekliliği korur;
yedek yoksa koruyacak bir şey de yoktur.
**Bu deney:** Önce kibar yolu dener (`kubectl drain`'in gönderdiği tahliye isteği) ve reddedildiğini gösterir; sonra
yük altında pod'u zorla silip kesintiyi ölçer.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P01-03` (yük altında iki ucu gösterir: normal
`kubectl drain` reddedilip timeout'a düşer; zorla silme 5xx üretir; sonunda düğümü `uncordon` eder). Elle (yalnızca
uygulama pod'una dokunan sürüm):

1. Temiz başla; PDB'nin neye izin verdiğine bak ve trafiği alan (hazır) pod'u seç:
```bash
cd "$LADDER/01-hardened"
make fresh
kubectl -n lvl01 rollout status deploy/linkly
kubectl -n lvl01 get pdb linkly
pod=$(kubectl -n lvl01 get endpointslice -l kubernetes.io/service-name=linkly -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].targetRef.name}'); echo "pod: $pod"
```
2. Kibar yol: `kubectl drain`'in her pod için gönderdiği tahliye isteğini bu pod için gönder:
```bash
cd "$LADDER/01-hardened"
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"lvl01"}}' "$pod" | kubectl create --raw "/api/v1/namespaces/lvl01/pods/$pod/eviction" -f -
```
3. Zorla yol, önce yük: ikinci bir terminalde 90 sn'lik yükü başlat:
```bash
cd "$LADDER/01-hardened"
make load S=redirect K6_ARGS="--vus 5 --duration 90s"
```
4. Yük başladıktan ~20 sn sonra ilk terminalde pod'u zorla sil ve yenisini bekle:
```bash
cd "$LADDER/01-hardened"
kubectl -n lvl01 delete pod "$pod" --force --grace-period=0
kubectl -n lvl01 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
```

**Terminalde ne görmelisin:** `get pdb`'de `MIN AVAILABLE 1 · ALLOWED DISRUPTIONS 0`. Tahliye
`Cannot evict pod as it would violate the pod's disruption budget.` ile reddedilir (`kubectl drain` tekrar dener ve
timeout'a düşer: bakım kilitli). Zorla silmede k6 bir süre donar, sonunda `request timeout` uyarıları çıkar; özet
(ölçülen) `k6 lvl01: reqs=188628 failed=43.03% 5xx=5 404=62109 429=19054 …`: `5xx` asılı kalan istekler, `404`'ler
yeni pod'un boş belleği (P01-01), `429`'lar hızlı dönen 404'lerin pod'un IP başına sınırını aşması.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s), [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; ~2 dk sürer
- "Hazır pod adresi (endpoint) sayısı" → kibar yolda 1'de kalır (kimse ölmüyor); zorla silmede **0'a iner**, yeni pod hazır olunca 1'e döner.
- "Pod durumları" → zorla silmeden hemen sonra kısa bir sarı `Pending`: yeni pod açılıyor (kısa sürerse örneklemeye yakalanmayabilir).
- "Dönen durum kodları" → boşluk anında `503` (ingress: gönderilecek pod yok); ardından `302`'nin yerini `404` alır.
- "İstek / saniye (durum koduna göre)" → `503` görmezsin: kesintiyi uygulama değil ingress yaşadı; iki panel arasındaki fark aradaki katmandır.

**Nasıl çözülüyor:** 02'de uygulama 3 kopya çalışır ve kopyalar farklı düğümlere yayılır; bir kopya bakıma alınırken diğerleri trafiği taşır. PDB orada gerçekten işe yarar.

---

### P01-04 · Bellek hâlâ sınırsız — ama artık önceden görülür

**Ne oluyor:** Link eklendikçe uygulamanın belleği sınırsız büyür ve sonunda bellek sınırına çarpıp öldürülür
(OOMKilled) — 00'daki gibi. Fark şu: 01 bellek kullanımını (Go heap) ve link sayısını yayınlıyor; büyüme artık
çarpmadan önce grafikte görünür ve bunun için bir alarm yazılabilir.
**Neden oluyor:** Bellekte tutulan linklerin üst sınırı, süresi (TTL) ya da eskileri atma kuralı yok; her yeni link
belleğe eklenir ve orada kalır.
**Bu deney:** Tek kullanıcıyla 90 sn boyunca büyük (2 KB) linkler üretir, öncesinde ve sonrasında link sayısını ve
bellek kullanımını okur; istersen 4 dk boyunca sınıra kadar götürür.

**Reproduce (adım adım):** Otomatik: `make repro P=P01-04` (90 sn link üretir; tepe heap, tepe `links_total` ve tepe
bellek okur; uzun sürüm `DURATION=240s URL_SIZE=8000 make repro P=P01-04` OOMKilled üretir). Elle:

1. Temiz başla; başlangıç değerlerini oku:
```bash
cd "$LADDER/01-hardened"
make fresh
curl -s http://lvl01.localtest.me/metrics | grep -E '^(links_total|go_memstats_heap_alloc_bytes) '
```
2. Tek kullanıcıyla (çökme yok, yalnızca büyüme) 90 sn boyunca 2 KB'lık linkler üret, tekrar oku:
```bash
cd "$LADDER/01-hardened"
URL_SIZE=2000 make load S=create K6_ARGS="--vus 1 --duration 90s"
curl -s http://lvl01.localtest.me/metrics | grep -E '^(links_total|go_memstats_heap_alloc_bytes) '
kubectl -n lvl01 top pod
```
3. İstersen sınıra kadar götür (4 dk), sonra pod'un neden öldüğüne bak:
```bash
cd "$LADDER/01-hardened"
URL_SIZE=8000 make load S=create K6_ARGS="--vus 1 --duration 240s"
kubectl -n lvl01 get pod -l app.kubernetes.io/name=linkly -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}'; echo
```

**Terminalde ne görmelisin:** 1. adımda `links_total 0`, heap ~3 MB. 2. adımdan sonra (ölçülen) `links_total 64474`
ve heap `1.51e+08` (~150 MB); `top pod` ~143Mi — 256Mi sınırın yarısından fazlası, ve geri düşmez. 3. adımın sonunda
`OOMKilled`: konteyner sınıra çarptı, linklerle birlikte öldü.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) — yük başlayınca aç; 90 sn sürer
- "Heap bellek (Go)" → yük boyunca tırmanır, yük bitince inmez: depo hiçbir şeyi bırakmıyor. Eğriyi çarpmadan önce görmek 01'in kazancı.
- "Bellek: sınırın yüzde kaçı" → aynı büyüme 256 MiB sınırın yüzdesi olarak %100'e gider; uzun sürümde "Son sonlanma nedeni" panelinde `OOMKilled` belirir.
- "Kayıtlı link sayısı (pod'a göre)" → heap ile aynı biçimde tırmanır: bellek = link sayısı × link boyutu.

**Nasıl çözülüyor:** 02 veriyi veritabanına taşır, uygulamanın belleği link sayısıyla büyümez; 03'teki önbellek sabit bir üst sınırla tutulur. 01'in kazancı: çarpmadan önce görüp alarm yazabilmek.

---

### P01-05 · Süreç içi hız sınırı N replikada N katına çıkar

**Ne oluyor:** Uygulamada "saniyede 50 istek" gibi bir hız sınırı var; ama uygulama 3 kopyaya çıkınca aynı istemci
saniyede 150 istek geçirebilir. Sınır kopya sayısıyla çarpılır; dağılım eşit değilse aynı istemci bazı kopyalarda
reddedilir, bazılarında geçer.
**Neden oluyor:** Sınır sayacı (token bucket — "her saniye yeniden dolan jeton kovası") her kopyanın kendi
belleğinde. Her kopya yalnızca kendisine gelen istekleri sayar; toplamı bilen yok.
**Bu deney:** Sınırı kopya başına saniyede 50 yapar, aynı yükü önce 1 sonra 3 kopyaya verir ve kabul edilen istek
sayılarını karşılaştırır; sonunda ayarları geri alır.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P01-05` (sınırı pod başına 50/s yapar, aynı yükü önce 1
sonra 3 pod'a verir, kabul edilen istekleri karşılaştırır, geri alır). Elle:

1. Temiz başla; sınırı pod başına saniyede 50'ye çek, eski pod trafikten çıkana kadar bekle (kendi sayacıyla ölçümü
   şişirmesin):
```bash
cd "$LADDER/01-hardened"
make fresh
make set E="RATE_LIMIT_PER_SEC=50 RATE_LIMIT_BURST=50"
sleep 20
```
2. Tek pod'a 20 sn yük ver:
```bash
cd "$LADDER/01-hardened"
make load S=redirect K6_ARGS="--vus 20 --duration 20s"
```
3. 3 pod'a çık, aynı yükü ver:
```bash
cd "$LADDER/01-hardened"
kubectl -n lvl01 scale deploy/linkly --replicas=3
kubectl -n lvl01 rollout status deploy/linkly
sleep 10
make load S=redirect K6_ARGS="--vus 20 --duration 20s"
```
4. Geri al:
```bash
cd "$LADDER/01-hardened"
kubectl -n lvl01 scale deploy/linkly --replicas=1
make reset
```

**Terminalde ne görmelisin:** her yükün sonunda `k6 lvl01: reqs=… 404=… 429=…`; kabul edilen = `reqs − 429`. Tek pod'da
~1000 (ölçülen 1059 = 50/s × 20 sn), 3 pod'da ~3000 (ölçülen 3171): "50" yazdın, sistem 150 geçirdi. (3 pod'daki
404'ler P01-02'dendir.)

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl01&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; iki faz 20'şer sn
- "İzin verilen (pod'a göre)" → ilk fazda tek çizgi (~50/s), ikinci fazda **üç ayrı** çizgi, her biri ~50/s: üç ayrı sayaç, toplam 3 katı.
- "Kararlar (anahtar türüne göre)" → `ip allow` ikinci fazda ~3 katına çıkar; yük aynı, değişen yalnızca pod sayısı.

**Nasıl çözülüyor:** 08'de sınır sayacı bütün kopyaların ortak kullandığı Redis'te tutulur; kopya sayısı ne olursa olsun sınır tek bir yerde sayılır.

---

### P01-06 · TRAP · Kısa kodu metrik label'ı yapmak

**Ne oluyor:** Metriğe kısa kodu etiket (label) olarak eklemek zararsız bir ayrıntı gibi görünür. Ama her yeni link
Prometheus'ta yeni bir veri serisi açar; seri sayısı link sayısıyla birlikte büyür, Prometheus'un belleği dolar ve
sorgular yavaşlar (kardinalite patlaması).
**Neden oluyor:** Prometheus her farklı etiket değerini ayrı bir zaman serisi olarak saklar. Sınırsız sayıda değer
alabilen alanlar (kısa kod, URL, IP, kullanıcı kimliği) etiket olursa seri sayısının da sınırı kalmaz.
**Bu deney:** Bu seviyenin tuzak ayarını (`TRAP_METRIC_LABEL_CODE`) açar, 200 link oluşturup her birini bir kez açar ve
uygulamanın kaç ayrı seri ürettiğini sayar; sonra tuzağı kapatıp tekrar sayar.

**Reproduce (adım adım):** Otomatik: `make repro P=P01-06` (`TRAP_METRIC_LABEL_CODE=true` açar, 400 kodu ziyaret eder,
`short_code` seri sayısını ve Prometheus'un toplam seri farkını basar, tuzağı kapatır). Elle:

1. Temiz başla; tuzağı aç (pod yeniden başlar):
```bash
cd "$LADDER/01-hardened"
make fresh
make set E="TRAP_METRIC_LABEL_CODE=true"
```
2. 200 link oluşturup her birini bir kez aç, pod'un kaç ayrı seri ürettiğini say:
```bash
cd "$LADDER/01-hardened"
for i in $(seq 1 200); do c=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d "{\"url\":\"https://example.com/card/$i\"}" | jq -r .code); curl -s -o /dev/null http://lvl01.localtest.me/$c; done
curl -s http://lvl01.localtest.me/metrics | grep -c 'short_code='
```
3. Tuzağı kapat, eski pod trafikten çıkınca tekrar say:
```bash
cd "$LADDER/01-hardened"
make reset
sleep 10
curl -s http://lvl01.localtest.me/metrics | grep -c 'short_code='
```

**Terminalde ne görmelisin:** tuzak açıkken `201` (ölçülen): her kod ayrı bir seri — 1 milyon linkte 1 milyon seri.
Kapanınca `0`, ama Prometheus eski serileri bir süre daha bellekte taşır.

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now&refresh=10s) — ziyaretler sürerken aç
- "İstek / saniye (uç noktaya göre)" → yine birkaç çizgi: panel uç noktaya göre topladığı için patlama ekranda görünmez. Kardinaliteyi dashboard'dan göremezsin.
- Explore'da: `count(count by (short_code) (http_requests_total{namespace="lvl01"}))` → tuzak açıkken ziyaret edilen kod sayısı kadar (yüzlerce).
- Explore'da: `prometheus_tsdb_head_series` → yüzlerce serilik bir basamak yapar ve tuzak kapansa da hemen inmez.

**Nasıl çözülüyor:** Bu seviyenin kendi tuzağı: bayrak açıkken sorun var, kapalıyken yok. Kural: tekil kimlikler (kod, kullanıcı) metriğe değil loga ve trace'e yazılır (11).

---

### P01-07 · TRAP · Sağlık uçlarını iş zincirinin arkasına koymak

**Ne oluyor:** Trafik arttığında uygulama aslında sağlıklıyken Kubernetes onu trafikten çıkarır, yeterince uzun
sürerse yeniden başlatır. Yük artışı kendi kendine bir kesintiye dönüşür; birden çok kopya varsa yük kalanlara biner
ve onlar da düşer.
**Neden oluyor:** Kubernetes pod'un sağlığını düzenli aralıklarla `/readyz` ve `/healthz` adreslerine sorarak anlar
(probe). Tuzakta bu adresler de hız sınırının arkasında: yük altında sınır dolunca sağlık sorusu da "429 — çok fazla
istek" cevabı alır ve Kubernetes pod'u hasta sanır. Sınır tek bir ortak kova olduğu için istemcinin yükü sağlık
kontrolünün payını da tüketir.
**Bu deney:** Tuzağı (`TRAP_LIVENESS_STRICT`) açıp hız sınırını düşürür, 150 sn boyunca sınırın çok üstünde yük
verir ve Kubernetes'in "sağlıksız" olaylarını ve yeniden başlatmaları sayar.

**Reproduce (adım adım):** Otomatik: `make repro P=P01-07` (`TRAP_LIVENESS_STRICT=true` + 30/s sınır, 150 sn yük;
`Unhealthy` olaylarını ve restart'ları sayar, tuzağı kapatır). Elle:

1. Temiz başla; tuzağı aç ve sınırı düşür (pod yeniden başlar):
```bash
cd "$LADDER/01-hardened"
make fresh
make set E="TRAP_LIVENESS_STRICT=true RATE_LIMIT_PER_SEC=30 RATE_LIMIT_BURST=30"
```
2. İkinci bir terminalde probe hatalarını canlı izle:
```bash
cd "$LADDER/01-hardened"
kubectl -n lvl01 get events -w --field-selector reason=Unhealthy
```
3. İlk terminalde sınırın çok üstünde 150 sn yük ver (liveness'ın 60 sn toleransından uzun olmalı), sonucu oku:
```bash
cd "$LADDER/01-hardened"
make load S=redirect K6_ARGS="--vus 10 --duration 150s"
kubectl -n lvl01 get events --field-selector reason=Unhealthy
kubectl -n lvl01 get pods
```
4. Tuzağı kapat (ikinci terminali Ctrl+C ile kapat):
```bash
cd "$LADDER/01-hardened"
make reset
```

**Terminalde ne görmelisin:** ~8 sn'de bir `Readiness probe failed: … statuscode: 429`, arada `Liveness probe failed:
… 429`. Ölçülen: 21 readiness ve 3 liveness hatası, restart 0; k6 `reqs=959985 … 5xx=564313 … 429=392232` — `5xx`'in
tamamı pod trafikten düştüğü anlarda ingress'in 503'ü. Baskın etki restart değil readiness: pod ölmeden trafikten
çıkar; birden çok replikada yük diğerlerine biner ve onlar da düşer. (Tuzağı açan rollout'taki `connection refused`
olayları ilgisiz.)

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s), [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl01&from=now-15m&to=now&refresh=10s) — yük başlayınca aç; 150 sn sürer
- "Hazır pod adresi (endpoint) sayısı" → 1 ile 0 arasında gidip gelir: her 0 tek replikada bir kesinti.
- "Yeniden başlatma sayısı" → çoğu turda kıpırdamaz: en görünür belirti en geç gelendir; "restart yok" sorun yok demek değil.
- "Reddedilen / sn" → yük boyunca yüksek: sınırın üstü reddediliyor.
- "Dönen durum kodları" → `429` baskın; pod trafikten düştüğü anlarda `503`.

**Nasıl çözülüyor:** Bu seviyenin kendi tuzağı: varsayılan kurulumda sağlık adresleri hız sınırının ve diğer ara katmanların dışında, liveness de dış bağımlılıklara bakmaz. Aynı tuzağın büyüğü 10'da (P10-02).

---

### P01-08 · Tıklama sayacı hâlâ istek yolunda ve bellekte

**Ne oluyor:** Her yönlendirme, cevabı dönmeden önce ortak bir tıklama sayacını kilit altında artırır; popüler bir
linkte bütün yönlendirmeler aynı kilidi bekler. Sayaç bellekte olduğu için uygulama yeniden başlayınca bütün
tıklamalar da sıfırlanır.
**Neden oluyor:** Tıklama sayımı (analitik) okuma yolunun içinde ve programın belleğinde. Bu ölçekte ucuz (kilit +
bellek), ama sayaç veritabanına taşındığında her tıklama bir veritabanı yazması ve satır kilidi olur.
**Bu deney:** Bir linki 300 kez açıp sayacı okur, aynı linke 50 kullanıcıyla 30 sn yük verip gecikmeye bakar, sonra
pod'u yenileyip sayacın ve linkin gittiğini gösterir.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P01-08` (300 tıklama yapar, sayacı okur, sıcak linkte
p99'u ölçer, pod'u yenileyip sayacın gittiğini gösterir). Elle:

1. Temiz başla; bir link oluştur, 300 kez aç, sayacı oku:
```bash
cd "$LADDER/01-hardened"
make fresh
code=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0108"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 300); do curl -s -o /dev/null http://lvl01.localtest.me/$code; done
curl -s http://lvl01.localtest.me/api/links/$code | jq .clicks
```
2. Aynı sıcak linke 50 kullanıcıyla 30 sn yük ver (her yönlendirme aynı kilidi bekler):
```bash
cd "$LADDER/01-hardened"
make load S=hot-key K6_ARGS="--vus 50 --duration 30s"
```
3. Pod'u yenile, linke tekrar bak:
```bash
cd "$LADDER/01-hardened"
kubectl -n lvl01 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl01 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
curl -s -o /dev/null -w '%{http_code}\n' http://lvl01.localtest.me/api/links/$code
```

**Terminalde ne görmelisin:** önce `300`. k6 özetinde `p99` düşük (bu ölçekte kilit ucuz; bedeli 02'de satır kilidine
dönüşünce görünür). Restart sonrası `404`: link de 300 tıklama da gitti.

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; sıcak link yükü 30 sn sürer
- "p99 süre (uç noktaya göre)" → sıcak link yükünde `/{code}` çizgisi yükselir: her yönlendirme aynı sayaç kilidini bekliyor.
- "Başarılı yönlendirme / sn" → tıklamalar burada görünür: Prometheus onları hatırlıyor, uygulamanın kendi sayacı restartta yok oluyor.
- "Kayıtlı link sayısı (pod'a göre)" → restartta eski pod'un çizgisi biter, yenisi 0'dan başlar.

**Nasıl çözülüyor:** 05'te tıklamalar istek yolundan çıkar: sınırlı bir kuyruğa atılır ve arka planda toplu yazılır. 06'da bir olay akışına (Redpanda) yazılarak kalıcı olur. 02'de bu kilit bir veritabanı satır kilidine dönüşür (P02-08).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_METRIC_LABEL_CODE` | Kısa kodu `http_requests_total`'a label olarak ekler | `make repro P=P01-06` | Bayrağı kapat; tekil kimlik log/trace'e |
| `TRAP_LIVENESS_STRICT` | `/healthz` ve `/readyz`'i iş zincirine (limit + timeout) sokar | `make repro P=P01-07` | Bayrağı kapat; sağlık uçları zincirin dışında |

Elle denemeye değer:
- `make set E="SHUTDOWN_GRACE=1s"` sonra `make repro P=P00-04` → kapanmadaki bekleme gidince 5xx geri gelir.
- `make set E="HANDLER_TIMEOUT=1ms"` → her istek 503; istek timeout'unun nerede devreye girdiğini logda izle.
- `make load S=abuser` → tek kötü istemcinin normal istemcinin p99'una etkisi (08'in ön provası).

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`00 · Overview`](http://grafana.localtest.me/d/ladder-overview?var-level=lvl01&from=now-15m&to=now) | **Dolu** | Erişilebilirlik ve p99 artık hesaplanıyor |
| [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now) | **Dolu** | Konteyner + Go runtime (goroutine, heap, GC) |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now) · [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now) | **Dolu** | Uygulama artık `/metrics` yayınlıyor |
| [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl01&from=now-15m&to=now) | Kısmen | Süreç içi sınır; tek anahtar türü (`ip`) |
| [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl01&from=now-15m&to=now) | Kısmen | Güvensiz URL reddi dolu; 401/403 yok (13) |
| [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl01&from=now-15m&to=now) | Dolu | İstemci tarafı |
| Diğerleri (04–09, 11–13) | Boş | Önbellek, DB, Redis, kuyruk, ölçekleyici, SLO, rollout yok |

## 9. Bilerek bırakılanlar

- Depo hâlâ bellekte ve tek pod'da: kalıcılık, ölçek, yedeklilik yok (P01-01/02/03 → 02).
- Hız sınırı süreç içi ve IP kayıtları sınırsız birikir (08).
- URL güvenliği bir azaltma: özel bir adrese çözülen alan adı geçer (13).
- Kiracı yok; `X-Tenant-ID` etkisiz (13).
- Analitik istek yolunda ve kalıcı değil (P01-08 → 05/06).
- İstemci IP'si `X-Forwarded-For`'dan körü körüne alınır, taklit edilebilir (08).
- Log seviyesi sabit `info`, örnekleme yok (11).

## 10. `make diff-prev` okuma rehberi

1. `cmd/linkly/main.go`: iş mantığı `internal/`'a taşındı; son satırlardaki kapanma sırasına bak (önce readiness düşer,
   sonra `Shutdown`).
2. `internal/store/memory.go`: kilitli depo ve `CreateUnique` (02'de SQL `UNIQUE`'e dönüşür).
3. `internal/httpapi/middleware.go`: zincirin sırası ve gerekçesi.
4. `deploy/deployment.yaml`: probe'lar, `maxUnavailable: 0`, `preStop` — her satır bir P00 sorununa cevap.
5. `deploy/servicemonitor.yaml` ve `deploy/pdb.yaml` (yeni): metriğin toplanması; bilerek işe yaramayan PDB (P01-03).
