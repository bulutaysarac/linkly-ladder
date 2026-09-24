# 01 — hardened · "Tek süreç ama düzgün"

> **Bu seviyede ne yaşayacaksın?**
> - Aynı 50 kullanıcının artık süreci çökertmemesi (kilit), dağıtımın hatasız geçmesi (readiness + graceful shutdown), slowloris'in timeout'a takılması — `make verify-prev` 00'ın sorunlarını burada koşup kapandıklarını gösterir
> - Restart'ta linklerin hâlâ kaybolması — ama artık panelde görünmesi (P01-01); tek pod'un tavanını pod bazında ölçmek (P01-02)
> - Tek replika + PodDisruptionBudget'ın düğüm boşaltmada neden koruma sağlamadığı (P01-03); belleğin OOM'dan önce görünür olması (P01-04)
> - Süreç içi hız sınırının N replikada N katına çıkması (P01-05); tıklama sayacının hâlâ istek yolunda olması (P01-08)
> - Tuzaklar: kısa kodu metrik etiketi yapınca Prometheus'un şişmesi (P01-06); sağlık uçlarını iş zincirinin arkasına koyunca pod'ların trafikten düşmesi (P01-07)
>
> **Bu seviye olmasa ne olur?** 00'ın çöküşleri ve dağıtım hataları sürer. Daha önemlisi: sonraki 13 seviyenin her sorunu 01'in eklediği metriklerle ölçülür — metrik yoksa "sorun var mı?" sorusunun cevabı tahmindir.
>
> **Yeni gelen teknolojiler:** `sync.RWMutex`, readiness/liveness probe, graceful shutdown, `log/slog` (JSON log), `/metrics` (client_golang), ServiceMonitor, PodDisruptionBudget ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

00 ile **aynı** tek süreç ve **aynı** bellek içi store — ama çökmesini, yalan söylemesini ve istek
kaybetmesini engelleyen disiplinlerle: kilit, probe, graceful shutdown, timeout'lar, giriş doğrulama,
hız sınırı, metrikler ve yapılandırılmış log. Kalıcılık ve ölçeklenebilirlik hâlâ **yok** — çünkü
onları zorlayan sorunları (P01-01, P01-02) burada ilk kez *ölçebilir* hale getiriyoruz; çözümü 02'de.

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

Zincirin **sırası** tasarımın kendisi: `recover` en dışta (altındaki her katmanın panic'ini yakalar),
`requestID` log'dan önce, `timeout` handler'dan önce ama log'dan sonra, `rateLimit` en sonda
(reddedilen istek iş mantığına hiç ulaşmaz). Sağlık ve metrik uçları **zincirin dışında** — bir trafik
dalgası probe'u düşürüp pod'u öldürmesin diye (bunu bozmak bir alıştırma: `TRAP_LIVENESS_STRICT`).

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P00-01 | Eşzamanlı map yazımı → çökme | `store.Memory` + `sync.RWMutex`; `-race` ile test edilen eşzamanlılık testi |
| P00-04 | Rollout'ta hata dalgası | readiness/liveness probe, `maxUnavailable: 0`, `preStop: sleep 5`, `terminationGracePeriodSeconds: 40` ve **kapatma sırası**: önce readiness düşür → yayılmayı bekle → `Shutdown` |
| P00-05 | 4 karakter kod, sessiz üzerine yazma | `crypto/rand` + 7 karakter + `CreateUnique` (koşullu ekleme) + çakışmada retry + `create_total{result="collision"}` |
| P00-06 | Doğrulama yok | Şema allowlist (`http`/`https`), özel/loopback/link-local adres reddi, `MaxBytesReader` (8 KB) |
| P00-07 | Sunucu timeout'u yok | `ReadHeaderTimeout 3s`, `ReadTimeout 10s`, `WriteTimeout 15s`, `IdleTimeout 60s` + istek başına `TimeoutHandler 5s` |
| P00-09 | Gözlemlenebilirlik sıfır | `/metrics` (sayaçlar **sıfırla** pre-register), `slog` JSON + request-id, ServiceMonitor |
| P00-10 | 301 + önbellek kontrolü yok | `302` + `Cache-Control: no-store` |

`problems/SOLVES` aynı listeyi makine-okunur tutar; `make verify-prev` bu iddiayı **00'ın kendi
scriptlerini burada koşarak** doğrular.

**Çözülmeyenler (bilerek):** P00-02 (kalıcılık → 02), P00-03 (ölçeklenebilirlik → 02), P00-08 (bellek
tavanı → 02/03). Bunlar burada P01-01, P01-02 ve P01-04 olarak, artık **ölçülebilir** biçimde duruyor.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **yalnızca temel yığın (kind, ingress, Prometheus, Grafana)**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl01.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl01 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P01-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Önceki seviye açıksa kapat (aynı anda tek seviye çalışır), bu seviyeyi kur. `make up` Grafana'yı da temizler:
```bash
make -C ../00-naive down
make up
```
2. 00'ın sorunlarını bu seviyede koş (~15 dk). Koşarken başka komut çalıştırma: aynı pod'lara dokunurlar.
   Çıktıdaki `BEKLENEN` sütunu `NOT-REPRODUCED` diyorsa 01 o sorunu çözmüş olmalı:
```bash
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P01-01 → P01-08). Her sorunda aynı düzen:
   **Elle** bloklarını sırayla yapıştır (ilk komut `make fresh`: Grafana bu deneye boş başlar) →
   **Terminalde ne görmelisin** ile karşılaştır → **Grafana'da gör** linklerini aç, her madde hangi panelde neyi
   göreceğini söyler. İstersen aynı deneyi `make repro P=…` ile otomatik koş: ölçer ve hükmünü basar.
4. Bitince açık kalan ayarları geri al ve seviyeyi kapat:
```bash
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyede yeni: `GET /{code}` artık **302** + `Cache-Control: no-store`; `/healthz`, `/readyz`,
`/metrics` uçları var; geçersiz hedefler `400 unsafe_url:<reason>`, büyük gövde `413`, limit aşımı
`429 + Retry-After`.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P01-01 | Restart = tüm linkler gider (artık görünür) | `CONFIRM=1 make repro P=P01-01` | [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) → "Kayıtlı link sayısı (pod'a göre)" | 02 |
| P01-02 | Ölçeklenemez (artık pod bazında görünür) | `CONFIRM=1 make repro P=P01-02` | [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) · [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s) → "404 (pod'a göre)" | 02 |
| P01-03 | Tek replika + PDB = güvenlik yanılsaması | `CONFIRM=1 make repro P=P01-03` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl01&from=now-15m&to=now&refresh=10s) → "Hazır pod adresi (endpoint) sayısı" | 02 |
| P01-04 | Bellek sınırsız (artık önceden görülür) | `make repro P=P01-04` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s) · [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) → "Heap bellek (Go)" | 02 · 03 |
| P01-05 | Süreç içi limit N replikada N katı | `CONFIRM=1 make repro P=P01-05` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl01&from=now-15m&to=now&refresh=10s) → "İzin verilen (pod'a göre)" | 08 |
| P01-06 | **TRAP** kısa kod label → kardinalite patlaması | `make repro P=P01-06` | [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now&refresh=10s) → "İstek / saniye (uç noktaya göre)" | seviye içi |
| P01-07 | **TRAP** sağlık ucu zincirin arkasında → restart fırtınası | `make repro P=P01-07` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s) · [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl01&from=now-15m&to=now&refresh=10s) → "Hazır pod adresi (endpoint) sayısı" | seviye içi |
| P01-08 | Tıklama sayacı istek yolunda ve bellekte | `CONFIRM=1 make repro P=P01-08` | [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now&refresh=10s) · [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) → "p99 süre (uç noktaya göre)" | 05 · 06 |

---

### P01-01 · Restart = tüm linkler gider — ama artık görünür

**Belirti:** Pod yeniden başlayınca her kısa link 404. 00 ile aynı; fark, artık `links_total`
grafiğinde **dikey bir düşüş** olarak görünmesi.
**Neden:** Mutex çökmeyi durdurdu, kalıcılığı getirmedi. Tek gerçek kaynak hâlâ süreç belleği.
[Topic · Konu: Durum yönetimi, kalıcılık]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `CONFIRM=1 make repro P=P01-01` (25 link oluşturur, pod'u siler, sayacı ve kanarya kodu yeniden okur).

Elle — `01-hardened` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, bir kanarya link ve 25 link daha oluştur, pod'un kaç link bildiğine bak:
```bash
make fresh
code=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0101"}' | jq -r .code); echo "kanarya kodu: $code"
for i in $(seq 1 25); do curl -s -o /dev/null -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d "{\"url\":\"https://example.com/$i\"}"; done
curl -s http://lvl01.localtest.me/metrics | grep '^links_total'
curl -s -o /dev/null -w 'restart öncesi: %{http_code}\n' http://lvl01.localtest.me/$code
```
2. Pod'u yeniden başlat, aynı kodu tekrar iste:
```bash
kubectl -n lvl01 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl01 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
curl -s -o /dev/null -w 'restart sonrası: %{http_code}\n' http://lvl01.localtest.me/$code
curl -s http://lvl01.localtest.me/metrics | grep '^links_total'
```

**Terminalde ne görmelisin:** önce `links_total 26` (önceki denemelerden kalan linklerle daha fazla olabilir) ve
`restart öncesi: 302`; pod silinip yenisi hazır olunca `restart sonrası: 404` ve `links_total 0`. Bütün linkler
pod'un belleğindeydi; yeni pod boş başladı.

**Grafana'da gör:** [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) — script pod'u sildikten sonra aç (giriş: admin / ladder)
- "Kayıtlı link sayısı (pod'a göre)" → eski pod'un çizgisi scriptin oluşturduğu 25+ linkin seviyesinde biter, yeni pod adıyla **0**'dan başlayan bir çizgi belirir: dikey düşüş, yani kaybın büyüklüğü.
- "Kayıtlı link sayısı" → büyük sayı restarttan sonra `0`; arkadaki küçük eğri aynı düşüşü çizer.
- "Yönlendirme sonuçları" → restarttan sonra `not_found` serisinde küçük bir tümsek: script kanarya kodunu yalnızca bir kez ister; aynı kodu elle birkaç kez istersen belirginleşir.

**Nerede çözülüyor:** 02 (Postgres). 01'in kazancı kaybı **ölçebilmek**: 00'da bu grafik yoktu, kaybın
büyüklüğünü söyleyemiyordun bile.

---

### P01-02 · Ölçeklenemez — ama artık pod bazında görünür

**Belirti:** `replicas=3` → aynı link isteklerin ~%66'sında 404.
**Neden:** Her pod'un kendi map'i; Service istekleri dağıtıyor. [Topic · Konu: Stateless servis]

**Reproduce (adım adım):**

Otomatik: `CONFIRM=1 make repro P=P01-02` (3 replikaya çıkar, 60 kez okur, hangi pod'un kaç 404 saydığını metrikten basar, sonra geri alır).

Elle — sırayla yapıştır:

1. Grafana'yı temizle, tek pod varken bir link oluştur:
```bash
make fresh
code=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0102"}' | jq -r .code); echo "kod: $code"
```
2. 3 replikaya çık, ingress yeni pod'ları görene kadar bekle, aynı kodu 30 kez iste:
```bash
kubectl -n lvl01 scale deploy/linkly --replicas=3
kubectl -n lvl01 rollout status deploy/linkly
sleep 10
for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code} ' http://lvl01.localtest.me/$code; done; echo
```
3. Geri al:
```bash
kubectl -n lvl01 scale deploy/linkly --replicas=1
```

**Terminalde ne görmelisin:** 30 cevabın yaklaşık üçte biri `302`, üçte ikisi `404`. Link yalnızca onu oluşturan
pod'un belleğinde; ingress istekleri üç pod'a dağıtıyor ve diğer ikisi linki hiç görmedi.

**Grafana'da gör:** [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s) — script çalışırken ya da hemen sonra aç (giriş: admin / ladder)
- "404 (pod'a göre)" → her pod kendi sayacını çizer: linkin yazıldığı pod'un çizgisi 0'da kalır, **diğer ikisi** yükselir — 404'ü linki hiç görmemiş pod'lar veriyor. 00'da bu panel boştu.
- "Yönlendirme sonuçları" → aynı pencerede `ok` ile `not_found` yan yana; `not_found` kabaca iki katı (60 okumanın ~%66'sı).
- "Hazır pod adresi (endpoint) sayısı" → deney boyunca 1'den **3**'e çıkar, script bitince 1'e döner: 404'lerin başladığı an, pod sayısının arttığı an.

**Nerede çözülüyor:** 02. Not: ölçekledikten sonra Service endpoint'lerinin gerçekten artmasını
beklemek şart; beklemezsen tüm istekler tek pod'a düşer ve yanlış negatif alırsın.

---

### P01-03 · Tek replika + PDB = güvenlik yanılsaması

**Belirti:** İki uçlu açmaz. Normal `kubectl drain` **bloke olur** (`error when evicting pods ...:
global timeout reached`), yani node bakımı yapamazsın. Zorlarsan servis kesintiye uğrar.
**Neden:** PDB *gönüllü* kesintilerde en az N pod'un ayakta kalmasını ister. Tek replikada
`disruptionsAllowed=0`: ayakta kalacak başka pod yok, o yüzden her tahliye reddedilir.
PDB erişilebilirlik **üretmez**; yalnızca var olan yedekliliği korur. Yedeklilik yoksa koruyacak
bir şey de yoktur — sadece bakımı kilitler. [Topic · Konu: HA, PDB, yedeklilik]

**Reproduce (adım adım):**

Otomatik: `CONFIRM=1 make repro P=P01-03` — yük altında iki ucu da gösterir: **(a)** normal `kubectl drain`
`disruptionsAllowed=0` yüzünden reddedilir ve timeout'a düşer; **(b)** zorla silme → pod ölür, yedeği yok → 5xx.
Script düğümün tamamını boşaltmayı dener (o düğümdeki platform pod'ları da taşınır) ve sonunda `uncordon` eder.

Elle — yalnızca uygulama pod'una dokunan sürüm, sırayla yapıştır:

1. Grafana'yı temizle, PDB'nin ne izin verdiğine bak ve trafiği alan (hazır) pod'u seç — kapanmakta olan bir pod'un
   tahliyesine PDB izin verir, deney onu değil çalışan pod'u sınamalı:
```bash
make fresh
kubectl -n lvl01 rollout status deploy/linkly
kubectl -n lvl01 get pdb linkly
pod=$(kubectl -n lvl01 get endpointslice -l kubernetes.io/service-name=linkly -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].targetRef.name}'); echo "pod: $pod"
```
2. **(a) Kibar yol:** `kubectl drain`'in her pod için yaptığı tahliye isteğini tek pod için gönder:
```bash
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"lvl01"}}' "$pod" | kubectl create --raw "/api/v1/namespaces/lvl01/pods/$pod/eviction" -f -
```
3. **(b) Zorla yol:** İKİNCİ bir terminalde `01-hardened` klasöründe 90 sn'lik yükü başlat:
```bash
make load S=redirect K6_ARGS="--vus 5 --duration 90s"
```
   Yük başladıktan ~20 sn sonra İLK terminalde pod'u zorla sil ve yenisini bekle:
```bash
kubectl -n lvl01 delete pod "$pod" --force --grace-period=0
kubectl -n lvl01 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
```

**Terminalde ne görmelisin:** `kubectl get pdb` satırında `MIN AVAILABLE 1 · ALLOWED DISRUPTIONS 0`. Tahliye isteği
`Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.` ile
reddedilir — `kubectl drain` bu cevabı alıp tekrar dener ve timeout'a düşer: düğüm bakımı kilitlenir. Zorla silmede
ikinci terminalde k6'nın `complete` sayacı bir süre donar ve sonunda her kullanıcı için bir
`Request Failed … request timeout` uyarısı çıkar: ölen pod'a giden istekler 60 sn cevapsız bekledi. k6 çıktısının
sonundaki özet satırı (ölçülen): `k6 lvl01: reqs=188628 failed=43.03% 5xx=5 404=62109 429=19054 …` —
`5xx` kullanıcı sayısı kadar (asılı kalan istekler), `404` on binlerce (yeni pod'un belleği boş, P01-01). `429`'lar
da gelir: yeni pod'un 404'leri çok hızlı döner, istek hızı pod'un IP başına saniyede 5000'lik sınırını aşar.

**Ölçülen çıktı:** `minAvailable=1 · izin verilen kesinti=0` →
`error when evicting pods/"linkly-…" -n "lvl01": global timeout reached: 45s`. Yani PDB sözünü
tuttu: kimse ölmedi — ama node'a da dokunamadın.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s), [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; deney ~2 dk sürer (giriş: admin / ladder)
- "Hazır pod adresi (endpoint) sayısı" → uç (a) boyunca **1'de kalır**: PDB tahliyeyi reddediyor, kimse ölmüyor. Uç (b)'de pod zorla silinince hazır adres kalmaz — çizgi **0'a iner** ve yeni pod hazır olunca 1'e döner.
- "Pod durumları" → zorla silmeden hemen sonra kısa bir sarı `Pending` basamağı: yeni pod başka bir node'da açılıyor. Birkaç saniye sürerse örneklemeye yakalanmayabilir; o zaman yukarıdaki panelin 0'a indiği ana bak.
- "Dönen durum kodları" (k6) → boşluğun olduğu anda `503` (ingress: gönderilecek pod yok); ardından `302`'nin yerini `404` alır — yeni pod'un belleği boş (P01-01).
- "İstek / saniye (durum koduna göre)" (App RED) → `503` **görmezsin**: kesintiyi uygulama değil ingress yaşadı, uygulama yalnızca sonrasındaki `404`'leri sayar. İki panel arasındaki fark aradaki katmandır; bkz. [Grafana'yı okumak](../README.md#grafanayı-okumak).

**Nerede çözülüyor:** 02 (3 replika + anti-affinity). PDB'nin kendisi 02'de anlam kazanır.

---

### P01-04 · Bellek hâlâ sınırsız — ama artık önceden görülür

**Belirti:** Link üretimi sürdükçe heap ve working set monoton tırmanır; sonu OOM.
**Neden:** Store'da eviction yok, TTL yok, üst sınır yok. [Topic · Konu: Bounded resources]

**Reproduce (adım adım):**

Otomatik: `make repro P=P01-04` — 90 sn link üretir; **tepe** heap, tepe `links_total` ve tepe working set okur.
Uzun sürüm: `DURATION=240s URL_SIZE=8000 make repro P=P01-04` → OOMKilled (P00-08'in aynısı, 256Mi limitte).

Elle — sırayla yapıştır:

1. Grafana'yı temizle, başlangıç değerlerini oku:
```bash
make fresh
curl -s http://lvl01.localtest.me/metrics | grep -E '^(links_total|go_memstats_heap_alloc_bytes) '
```
2. Tek kullanıcıyla 90 sn boyunca 2 KB'lık linkler üret (tek kullanıcı: çökme yok, yalnızca büyüme), sonra tekrar oku:
```bash
URL_SIZE=2000 make load S=create K6_ARGS="--vus 1 --duration 90s"
curl -s http://lvl01.localtest.me/metrics | grep -E '^(links_total|go_memstats_heap_alloc_bytes) '
kubectl -n lvl01 top pod
```
3. İstersen sınıra kadar götür (4 dk), sonra pod'un neden öldüğüne bak:
```bash
URL_SIZE=8000 make load S=create K6_ARGS="--vus 1 --duration 240s"
kubectl -n lvl01 get pod -l app.kubernetes.io/name=linkly -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}'; echo
```

**Terminalde ne görmelisin:** 1. adımda `links_total 0` ve heap ~3 MB (`3.1e+06`). 2. adımdan sonra (ölçülen)
`links_total 64474` ve `go_memstats_heap_alloc_bytes 1.51e+08` — yani ~150 MB; `kubectl top pod` ~143Mi gösterir,
256Mi sınırın yarısından fazlası. Hiçbiri geri düşmez (eviction, TTL, üst sınır yok). 3. adımın sonunda `OOMKilled` yazar: konteyner 256 MiB sınırına çarptı ve bütün linklerle birlikte öldü.

**Ölçüm notu:** "Öncesi/sonrası heap" ölçmek yanıltır — süreç test sırasında OOM olup yeniden
doğarsa son ölçüm sıfırdan başlar, *büyüme yok* gibi görünür ve hüküm yanlış negatif olur. Bu yüzden
pencere içindeki **tepe** değere ve `OOMKilled` kanıtına bakıyoruz. P00-08'deki örnekleme dersiyle aynı
kök: **anlık ölçüm, ölüp dirilen bir süreci göremez.**

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; yük 90 sn sürer (giriş: admin / ladder)
- "Heap bellek (Go)" → yük boyunca **monoton** tırmanır, yük bitince de inmez: store hiçbir şeyi bırakmıyor. 00'da bu panel boştu — eğriyi çarpmadan önce görmek 01'in kazancı.
- "Bellek kullanımı" → heap'i izleyerek tırmanır; "Bellek: sınırın yüzde kaçı" → aynı büyüme sınırın (256 MiB) yüzdesi olarak %100'e doğru gider. Uzun sürümde (`DURATION=240s URL_SIZE=8000`) konteyner sınıra çarpar ve aynı dashboard'daki "Son sonlanma nedeni" panelinde `OOMKilled` belirir (örnekleme yüzünden çizgi %100'e değmeden kesilebilir — P00-08).
- "Kayıtlı link sayısı (pod'a göre)" → heap ile aynı biçimde tırmanır: bellek = link sayısı × link boyutu.

**Nerede çözülüyor:** 02 (durum DB'de) · 03 (bounded LRU). 01'in kazancı: eğriyi görüp **alarm
yazabilmek** — tavan aynı yerde ama artık çarpmadan önce haberin oluyor.

---

### P01-05 · Süreç içi hız sınırı N replikada N katına çıkar

**Belirti:** "200 rps" yazdın; 3 pod ile client 600 rps geçiriyor. Üstelik dağılım eşit değilse
aynı client bazı pod'larda limitlenip bazılarında geçiyor.
**Neden:** Token bucket her pod'un belleğinde. Limit bir **söz**dür; süreç içinde tutulan söz,
replika sayısıyla çarpılır. [Topic · Konu: Dağıtık durum, hız sınırlama]

**Reproduce (adım adım):**

Otomatik: `CONFIRM=1 make repro P=P01-05` — limiti pod başına 50 rps'e çeker, önce 1 pod sonra 3 pod ile aynı yükü
verir, kabul edilen istek sayısını karşılaştırır (beklenen: ~3 kat), sonra her şeyi geri alır.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, limiti pod başına saniyede 50 isteğe çek. Pod yeniden başlar; eski pod birkaç saniye daha
   trafik alır ve kendi kovasıyla ölçümü şişirir, bu yüzden trafikten çıkmasını bekle:
```bash
make fresh
make set E="RATE_LIMIT_PER_SEC=50 RATE_LIMIT_BURST=50"
sleep 20
```
2. Tek pod ile 20 sn yük ver:
```bash
make load S=redirect K6_ARGS="--vus 20 --duration 20s"
```
3. 3 pod'a çık, aynı yükü ver:
```bash
kubectl -n lvl01 scale deploy/linkly --replicas=3
kubectl -n lvl01 rollout status deploy/linkly
sleep 10
make load S=redirect K6_ARGS="--vus 20 --duration 20s"
```
4. Geri al:
```bash
kubectl -n lvl01 scale deploy/linkly --replicas=1
make reset
```

**Terminalde ne görmelisin:** her yükün çıktısının sonunda bir özet satırı: `k6 lvl01: reqs=… 404=… 429=…`.
Kabul edilen istek = `reqs − 429`. Tek pod'da ~1000 (ölçülen 1059: 50 rps × 20 sn); 3 pod'da ~3000 (ölçülen 3171).
"Saniyede 50" yazdın, sistem 150 geçirdi: her pod kendi kovasını tutuyor. (3 pod'daki 404'ler P01-02'dendir: link
onu oluşturan pod'da; hız sınırıyla ilgisi yok.)

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl01&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; iki faz 20'şer sn, panellerin 1 dk'lık ortalaması yüzünden geçiş yumuşak görünür (giriş: admin / ladder)
- "İzin verilen (pod'a göre)" → ilk fazda (1 pod) **tek** çizgi, limit civarında (~50/s); ikinci fazda (3 pod) **üç ayrı** çizgi, her biri yine limit civarında: üç ayrı kova, üç ayrı sayaç, toplam ~3 katı.
- "Kararlar (anahtar türüne göre)" → `ip allow` ikinci fazda yaklaşık üç katına çıkar; yük aynı, değişen yalnızca pod sayısı.

**Nerede çözülüyor:** 08 (Redis'te Lua ile atomik, paylaşılan limiter). Orada da yeni bir sorun
doğacak: limiter'ın kendi bağımlılığı düşerse fail-open mı fail-closed mı (P08-01)?

---

### P01-06 · TRAP · Kısa kodu metrik label'ı yapmak

**Belirti:** Metrik eklemek "ücretsiz" sanılır. `short_code` label'ı açıldığında Prometheus'un seri
sayısı link sayısıyla birlikte büyür; sorgular ve Prometheus'un kendisi yavaşlar.
**Neden:** Her farklı label değeri **yeni bir zaman serisi**. Sınırsız değerli alanlar (kısa kod, URL,
IP, tenant id, user id) label olamaz. [Topic · Konu: Kardinalite]

**Reproduce (adım adım):**

Otomatik: `make repro P=P01-06` — `TRAP_METRIC_LABEL_CODE=true` açar, 400 farklı kodu ziyaret eder,
`count(count by (short_code) (http_requests_total{namespace="lvl01"}))` ve `prometheus_tsdb_head_series` farkını
basar, sonra tuzağı kapatır. Route şablonunun (`/{code}`) neden tek bir seri ürettiğini
`internal/httpapi/middleware.go:routeOf`'ta gör.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, tuzağı aç (pod yeniden başlar):
```bash
make fresh
make set E="TRAP_METRIC_LABEL_CODE=true"
```
2. 200 link oluşturup her birini bir kez aç, sonra pod'un kaç ayrı seri ürettiğini say:
```bash
for i in $(seq 1 200); do c=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d "{\"url\":\"https://example.com/card/$i\"}" | jq -r .code); curl -s -o /dev/null http://lvl01.localtest.me/$c; done
curl -s http://lvl01.localtest.me/metrics | grep -c 'short_code='
```
3. Tuzağı kapat, eski pod trafikten çıkana kadar bekle, tekrar say:
```bash
make reset
sleep 10
curl -s http://lvl01.localtest.me/metrics | grep -c 'short_code='
```

**Terminalde ne görmelisin:** tuzak açıkken `201` (ölçülen): ziyaret ettiğin her kısa kod istek sayacında ayrı bir
zaman serisi açtı — 200 linkte 200 seri, 1 milyon linkte 1 milyon. Tuzak kapanınca `0` — ama Prometheus o serileri
bir süre daha belleğinde taşır (Grafana linkindeki `prometheus_tsdb_head_series`).

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now&refresh=10s) — script 400 kodu ziyaret ederken aç (giriş: admin / ladder)
- "İstek / saniye (uç noktaya göre)" → **yine birkaç çizgi** (`/{code}`, `/api/links` …): panel `sum by (route)` ile topladığı için `short_code` label'ı ekranda eriyip gider. Patlama panelde değil, altındaki seri sayısında — dashboard'a bakarak kardinaliteyi göremezsin.
- Explore'da: `count(count by (short_code) (http_requests_total{namespace="lvl01"}))` → tuzak açıkken ziyaret edilen kod sayısı kadar (yüzlerce) çıkar; tuzak kapanıp pod yenilenince düşer.
- Explore'da: `prometheus_tsdb_head_series` → aynı anda yüzlerce seri **basamak** yapar ve tuzak kapansa da hemen inmez: Prometheus bu serileri belleğinde bir süre daha taşır.

**Düzeltme:** Tekil kimlikler metriğe değil **log'a** ve **trace'e** gider (11'de exemplar ile
metrikten trace'e atlayacağız — kardinalite ödemeden).

---

### P01-07 · TRAP · Sağlık uçlarını iş zincirinin arkasına koymak

**Belirti:** Trafik dalgasında pod **kendi yükü yüzünden** load balancer'dan düşer, yeterince
uzun sürerse restart eder. Uygulama aslında sağlıklıdır; onu devre dışı bırakan **probe'un kendisidir**.
**Neden:** `/healthz` ve `/readyz` iş zincirine (hız sınırı + timeout) dahil edilirse, yük arttığında
probe 429/timeout alır → kubelet konteyneri öldürür → yük kalan pod'lara biner → onlar da ölür.
Yük artışı kendi kendine bir **kesintiye** dönüşür. Tuzak, bu kestirmenin genelde yanında gelen ikinci
hatayı da yapar: zincirin hız sınırı istemci başına değil **pod başına tek kova**dır. İkisi birlikte
gerekir: IP başına bir kova probe'ları korurdu — kubelet düğümün IP'sinden gelir, kendi kovası olur;
tek kovada ise istemcinin yükü probe'un payını da tüketir. `internal/httpapi/middleware.go:TrapChain`,
birim testi `TestTrapLivenessStrictProbeFromOtherIPShares`. [Topic · Konu: Probe semantiği, kaskad]

**Reproduce (adım adım):**

Otomatik: `make repro P=P01-07` — `TRAP_LIVENESS_STRICT=true` + limiti 30 rps yapar, **150 sn** yük verir,
`Unhealthy` olaylarını (liveness ve readiness ayrı ayrı) ve restart sayısını sayar, sonra tuzağı kapatır.
Birim test karşılığı: `internal/httpapi/trap_test.go` — tuzak kapalıyken `/healthz` 200, açıkken 429.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, tuzağı aç ve limiti düşür (pod yeniden başlar):
```bash
make fresh
make set E="TRAP_LIVENESS_STRICT=true RATE_LIMIT_PER_SEC=30 RATE_LIMIT_BURST=30"
```
2. İKİNCİ bir terminalde probe hatalarını canlı izle:
```bash
kubectl -n lvl01 get events -w --field-selector reason=Unhealthy
```
3. İLK terminalde limitin çok üstünde 150 sn yük ver, sonra sonucu oku:
```bash
make load S=redirect K6_ARGS="--vus 10 --duration 150s"
kubectl -n lvl01 get events --field-selector reason=Unhealthy
kubectl -n lvl01 get pods
```
4. Tuzağı kapat (ikinci terminaldeki izlemeyi Ctrl+C ile durdur):
```bash
make reset
```

**Terminalde ne görmelisin:** ikinci terminalde yük başladıktan kısa süre sonra her ~8 sn'de bir
`Readiness probe failed: HTTP probe failed with statuscode: 429`; arada `Liveness probe failed: … 429`. Pod
Endpoints'ten düşer ve ingress, uygulama sağlıklıyken **503** döner. Ölçülen: 21 readiness ve 3 liveness 429'u,
restart 0; k6 özet satırı `k6 lvl01: reqs=959985 … 5xx=564313 404=0 429=392232` — `5xx`'in tamamı pod trafikten
düştüğü anlarda ingress'in 503'ü. (Tuzağı açan rollout'ta yeni pod'un açılış anındaki `connection refused` ve
`statuscode: 503` olayları tuzakla ilgisizdir.) Liveness'ın öldürmesi için 6 ardışık hata (60 sn) gerekir; en
görünür belirti (restart) en geç gelendir.

**Ölçüm notu:** Yük, probe'un **toleransından uzun** sürmeli. Bu deployment'ta liveness
`failureThreshold: 6 × periodSeconds: 10` = 60 sn tolerans; tam 60 sn'lik bir yük restart üretmez ve
hüküm yanlış negatif olur, bu yüzden yük 150 sn sürer. Tolerans, tasarımın parçasıdır: probe'un ne
kadar sabırlı olduğunu bilmeden "probe çalışıyor mu?" sorusuna cevap veremezsin.
Ayrıca readiness de aynı kovadan içer: pod daha restart olmadan **Endpoints'ten düşer**.

**Ölçülen (150 sn yük, 30 rps limit):** `Unhealthy(readiness) 21 · Unhealthy(liveness) 3 · restart 0` ve
k6'da 564 313 adet 503. Baskın etki **restart değil, readiness**: pod daha ölmeden Endpoints'ten düşer, ingress
ona trafik göndermeyi bırakır. Tek replikada bu doğrudan **kesinti**; N replikada düşen pod'un yükü diğerlerine
biner, onların da probe'ları düşer: **kaskad**. "Restart yok, demek ki sorun yok" demek bu yüzden yanlış.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now&refresh=10s), [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl01&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; yük 150 sn sürer (giriş: admin / ladder)
- "Hazır pod adresi (endpoint) sayısı" → yük boyunca 1 ile 0 arasında **basamak basamak** gider: readiness düştükçe pod Endpoints'ten çıkıyor (ölçülen: 21 readiness olayı). Tek replikada her 0 bir kesinti.
- "Yeniden başlatma sayısı" → çoğu turda **kıpırdamaz** (ölçülen tur: restart 0): liveness'ın 60 sn toleransı var. En görünür belirti en geç gelen belirtidir — "restart yok" sorun yok demek değil.
- "Reddedilen / sn" → yük boyunca yüksek: limit 30 rps'e çekildi, üstü reddediliyor.
- "Dönen durum kodları" (k6) → `429` baskın; pod Endpoints'ten düştüğü anlarda `503` (ingress: hazır pod yok). Kodların anlamı: [Grafana'yı okumak](../README.md#grafanayı-okumak).

**Düzeltme (varsayılan):** Sağlık uçları zincirin dışında. Liveness yalnızca "süreç kurtarılamaz mı?"
sorusunu sorar; **bağımlılık kontrolü liveness'a girmez** — aynı tuzağın büyük hâli 10'da (P10-02).

---

### P01-08 · Tıklama sayacı hâlâ istek yolunda ve bellekte

**Belirti:** Her redirect, yanıtı döndürmeden önce paylaşılan bir sayacı kilit altında artırıyor;
pod restart olunca tüm tıklamalar sıfırlanıyor.
**Neden:** Analitik, okuma yolunun içinde ve süreç belleğinde. Bugün ucuz (mutex + RAM), yarın değil.
[Topic · Konu: Asenkronizm, okuma/yazma yolu ayrımı]

**Reproduce (adım adım):**

Otomatik: `CONFIRM=1 make repro P=P01-08` — 300 tıklama yapar, sayacı okur, hot-key yükünde p99'u ölçer,
pod'u yeniden başlatır ve sayacın sıfırlandığını gösterir.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, bir link oluştur, 300 kez aç, sayacı oku:
```bash
make fresh
code=$(curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0108"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 300); do curl -s -o /dev/null http://lvl01.localtest.me/$code; done
curl -s http://lvl01.localtest.me/api/links/$code | jq .clicks
```
2. Aynı sıcak linke 50 kullanıcıyla 30 sn yük ver (her redirect aynı sayacı kilitleyip artırır):
```bash
make load S=hot-key K6_ARGS="--vus 50 --duration 30s"
```
3. Pod'u yeniden başlat, sayaca tekrar bak:
```bash
kubectl -n lvl01 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl01 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
curl -s -o /dev/null -w '%{http_code}\n' http://lvl01.localtest.me/api/links/$code
```

**Terminalde ne görmelisin:** önce `300`. Hot-key yükünün sonundaki `k6 lvl01: …` özet satırında `p99` düşüktür (bu ölçekte mutex ucuz,
bedeli 02'de satır kilidine dönüşünce görünür). Restart sonrası `404`: link de, 300 tıklama da gitti.

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; hot-key yükü 30 sn sürer (giriş: admin / ladder)
- "p99 süre (uç noktaya göre)" → hot-key yükü sırasında `/{code}` çizgisi yükselir: her redirect, yanıt dönmeden önce aynı sayaç kilidini bekliyor.
- "Başarılı yönlendirme / sn" → 300 tıklama ve hot-key yükü burada görünür — Prometheus bu tıklamaları hatırlıyor; uygulamanın kendi `clicks` alanı ise restartta link ile birlikte yok oluyor (script sonunda `restart sonrası tıklama: link yok`).
- "Kayıtlı link sayısı (pod'a göre)" → restartta eski pod'un çizgisi biter, yenisi 0'dan başlar: sayaç da link de aynı bellekteydi.

**Nerede çözülüyor:** 05 (bounded kuyruk + batch writer ile istek yolundan çıkar) · 06 (olay akışı
ile dayanıklı olur). Uyarı: 02'de bu mutex bir **DB satır kilidine** dönüşecek ve hot link'te
redirect gecikmesini doğrudan belirleyecek (P02-08).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_METRIC_LABEL_CODE` | Kısa kodu `http_requests_total`'a label olarak ekler | `make repro P=P01-06` | Bayrağı kapat; tekil kimlik log/trace'e |
| `TRAP_LIVENESS_STRICT` | `/healthz` ve `/readyz`'i iş zincirine (limit + timeout) sokar | `make repro P=P01-07` | Bayrağı kapat; sağlık uçları zincirin dışında |

Elle denemeye değer:
- `kubectl -n lvl01 set env deploy/linkly SHUTDOWN_GRACE=1s` → kapatma sırasındaki bekleme penceresini
  yok et, sonra `make repro P=P00-04` (00'ın scriptiyle!) koş: 5xx geri gelir. Graceful shutdown'ın
  hangi parçasının işi yaptığını böyle görürsün.
- `kubectl -n lvl01 set env deploy/linkly HANDLER_TIMEOUT=1ms` → her istek 503; `TimeoutHandler`'ın
  nerede devreye girdiğini logdan izle.
- `make load S=abuser` → tek kötü client'ın normal client'ın p99'una etkisini ölç (08'in ön provası).

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`00 · Overview`](http://grafana.localtest.me/d/ladder-overview?var-level=lvl01&from=now-15m&to=now) | **Dolu** | Artık availability ve p99 da hesaplanabiliyor |
| [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl01&from=now-15m&to=now) | **Dolu** | cAdvisor + KSM + **Go runtime** (goroutine, heap, GC) |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl01&from=now-15m&to=now) | **Dolu** ✨ | 00'da boştu: `/metrics` yoktu |
| [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl01&from=now-15m&to=now) | **Dolu** ✨ | `links_total`, `redirect_*`, `create_*`, `create_rejected_unsafe_*` |
| [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl01&from=now-15m&to=now) | **Dolu** (kısmen) | Süreç içi limiter; `key_type="ip"` tek tür |
| [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl01&from=now-15m&to=now) | Dolu | Client tarafı |
| [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl01&from=now-15m&to=now) | Boş | Cache yok (03) |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl01&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl01&from=now-15m&to=now) · [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl01&from=now-15m&to=now) · [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl01&from=now-15m&to=now) | Boş | O bileşenler yok |
| [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl01&from=now-15m&to=now) | Boş | HPA yok (07) |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl01&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl01&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl01&from=now-15m&to=now) | Boş | 10/11/12'de gelir |
| [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl01&from=now-15m&to=now) | Kısmen | `create_rejected_unsafe_total` dolu; 401/403 yok (13) |

Not: `Pods & Resources` → "CPU throttling" paneli bu ortamda **boş kalır** — kind + Docker Desktop
(cgroup v1) cAdvisor'ı `container_cpu_cfs_throttled_seconds_total` yayınlamıyor. Ortam sınırı,
uygulama sorunu değil; 07'de bu panele ihtiyacımız olacak.

## 9. Bilerek bırakılanlar

- **Store hâlâ bellekte ve tek pod'da.** Kalıcılık, ölçeklenebilirlik, HA yok (P01-01/02/03).
- **Rate limit süreç içi** ve kova map'i sınırsız büyüyor (her yeni IP yeni kayıt). TTL yok (08).
- **URL güvenliği bir azaltma, eliminasyon değil:** özel bir adrese *çözülen* alan adı buradan geçer.
  DNS çözümü ve kalan TOCTOU sınırı 13'te.
- **Tenant yok.** `X-Tenant-ID` gönderebilirsin, hiçbir etkisi yok (13).
- **Analitik istek yolunda ve kalıcı değil** (P01-08 → 05/06).
- **`clientIP` X-Forwarded-For'a körü körüne güveniyor** — spoof edilebilir. Doğrusu yalnızca
  güvenilen proxy hop'undan almak: 08 (P08-03b).
- **Log seviyesi sabit `info`**, log sampling yok — yüksek trafikte Loki'yi zorlar (11, P11-05).

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 00 ile farkı gösterir. Sırayla şuna bak:

1. **`cmd/linkly/main.go`**: 120 satırlık tek dosya, 90 satırlık *bağlantı şemasına* dönüştü. İş
   mantığı `internal/`'a taşındı. En öğretici kısım son yirmi satır: **kapatma sırası** — önce
   readiness düşer, yayılma beklenir, sonra `Shutdown`. Sırayı değiştirip `make repro P=P00-04`
   koşarsan 5xx geri gelir.
2. **`internal/store/memory.go`**: `map` yerine `RWMutex`'li tip ve `CreateUnique`. `CreateUnique`'in
   koşullu ekleme semantiği tesadüf değil: 02'de SQL `UNIQUE`'e birebir çevrilecek.
3. **`internal/httpapi/middleware.go`**: zincirin **sırası** yorumlarda gerekçelendirilmiş.
4. **`deploy/deployment.yaml`**: probe'lar, `maxUnavailable: 0`, `preStop`, `terminationGracePeriodSeconds`,
   `securityContext`. Her satırın yanında hangi P00-XX'i kapattığı yazıyor.
5. **`deploy/servicemonitor.yaml`** (yeni): metrik üretmek yetmez, **toplanması** da gerekir.
6. **`deploy/pdb.yaml`** (yeni): bilerek işe yaramayan bir PDB — P01-03 bunun neden yanılsama
   olduğunu ölçüyor.
