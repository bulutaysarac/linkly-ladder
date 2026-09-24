# 00 — naive · "Tek dosya, tek pod, bellek"

> **Bu seviyede ne yaşayacaksın?**
> - 50 eşzamanlı kullanıcıda sürecin `concurrent map writes` ile çökmesi (P00-01) ve her çöküşte bütün linklerin gitmesi (P00-02)
> - İkinci bir replika açınca linklerin rastgele 404 vermesi (P00-03) ve her dağıtımda bir hata dalgası (P00-04)
> - 4 karakterlik kodların çakışması (P00-05); `javascript:` linklerinin, iç ağ adreslerinin ve 5 MB'lık gövdelerin kabul edilmesi (P00-06)
> - Tek bir yavaş istemcinin bağlantıyı sonsuza kadar tutması — slowloris (P00-07) ve belleğin sınırsız büyüyüp OOMKilled olması (P00-08)
> - Bütün bunların hiçbir uygulama metriğinde görünmemesi (P00-09) ve 301'in tıklamaları tarayıcıda yutması (P00-10)
>
> **Bu seviye olmasa ne olur?** Merdivenin geri kalanındaki her parça — kilit, probe, veritabanı, önbellek, kuyruk — bir cevaptır; bu seviye soruları üretir. Soruyu yaşamadan öğrenilen bir çözüm ezberdir: neyi önlediğini hiç görmemiş olursun.
>
> **Yeni gelen teknolojiler:** Go `net/http`, Kubernetes (Deployment, Service, Ingress), ingress-nginx, k6, Prometheus + Grafana — bu seviyede yalnızca konteyner düzeyinde (cAdvisor, kube-state-metrics) ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

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
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl00.localtest.me/$code   # 301 → https://example.com (01'den itibaren 302 — neden: P00-10)
make grafana       # Ladder klasörü, level=lvl00 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P00-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Bu seviyeyi kur. Önceki seviye yok; başka bir seviye açıksa önce onu kapat (aynı anda tek seviye
   çalışır: `make -C ../NN-ad down`). `make up` Grafana'yı da temizler:
```bash
make up
```
2. §6'daki sorunları sırayla yaşa (P00-01 → P00-10). Her sorunda aynı düzen:
   **Elle** bloklarını sırayla yapıştır (ilk komut `make fresh`: Grafana bu deneye boş başlar) →
   **Terminalde ne görmelisin** ile karşılaştır → **Grafana'da gör** linklerini aç, her madde hangi panelde neyi
   göreceğini söyler. İstersen aynı deneyi `make repro P=…` ile otomatik koş: ölçer ve hükmünü basar.
   00'da iki eşzamanlı istek süreci çökertebilir (P00-01); bu yüzden P00-01 dışındaki yükler tek kullanıcıyla
   (`--vus 1`) ya da sıralı `curl` döngüleriyle verilir.
3. Bitince açık kalan ayarları geri al ve seviyeyi kapat:
```bash
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyenin farkları: `GET /{code}` **301** döner (01'den itibaren 302), `X-Tenant-ID` yok sayılır,
`/healthz`, `/readyz`, `/metrics` **yoktur**.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P00-01 | Eşzamanlı map yazımı → süreç çöker | `make repro P=P00-01` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl00&from=now-15m&to=now&refresh=10s) → "Yeniden başlatma sayısı" | 01 |
| P00-02 | Restart = tüm linkler kaybolur | `CONFIRM=1 make repro P=P00-02` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) · [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl00&from=now-15m&to=now&refresh=10s) → "Bellek kullanımı" | 02 |
| P00-03 | `replicas>1` → rastgele 404 | `CONFIRM=1 make repro P=P00-03` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) · [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl00&from=now-15m&to=now&refresh=10s) → "Hazır pod adresi (endpoint) sayısı" | 02 |
| P00-04 | Rollout sırasında hata dalgası | `make repro P=P00-04` | [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl00&from=now-15m&to=now&refresh=10s) · [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) → "Dönen durum kodları" | 01 |
| P00-05 | 4 karakter kod, çakışma kontrolü yok | `make repro P=P00-05` | görünmez — kanıt terminalde ↓ | 01 |
| P00-06 | Giriş doğrulaması yok | `make repro P=P00-06` | [14 · Security](http://grafana.localtest.me/d/ladder-security?var-level=lvl00&from=now-15m&to=now&refresh=10s) · [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) → "Tehlikeli URL reddi (sebebe göre)" | 01 |
| P00-07 | Sunucu timeout'u yok (slowloris) | `make repro P=P00-07` | görünmez — kanıt terminalde ↓ | 01 |
| P00-08 | Bellek sınırsız → OOMKilled | `make repro P=P00-08` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) → "Son sonlanma nedeni" | 01 (ölçüm) · 02 (asıl) |
| P00-09 | Gözlemlenebilirlik sıfır | `make repro P=P00-09` | [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl00&from=now-15m&to=now&refresh=10s) · [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl00&from=now-15m&to=now&refresh=10s) → "Saniyedeki istek" | 01 |
| P00-10 | 301 + Cache-Control yok | `make repro P=P00-10` | görünmez — kanıt terminalde ↓ | 01 |

---

### P00-01 · Eşzamanlı map yazımı → süreç çöker

**Belirti:** Yük altında pod aniden restart eder; loglarda `fatal error: concurrent map writes`.
**Neden:** `links`, `clicks`, `created` map'leri her istek goroutine'i tarafından kilitsiz yazılıyor
(`cmd/linkly/main.go` — `links[code] = req.URL` ve `clicks[code]++`). Go runtime'ı eşzamanlı map yazımını
tespit ederse süreci **tümden** öldürür: recover edilemez. [Topic · Konu: Eşzamanlılık, veri yarışı]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P00-01` (taze bir pod'la başlar, 50 kullanıcıyla 15 sn POST yağdırır, pod'un önceki logunda Go'nun ölüm mesajını arar).

Elle — `00-naive` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, pod'u taze başlat (geri çekilme beklemesindeki bir pod'un restart sayacı donar — Ölçüm notu),
   adını al:
```bash
make fresh
kubectl -n lvl00 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl00 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
pod=$(kubectl -n lvl00 get pod -l app.kubernetes.io/name=linkly -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "pod: $pod"
kubectl -n lvl00 get pods
```
2. İKİNCİ bir terminalde `00-naive` klasöründe pod'u canlı izle:
```bash
kubectl -n lvl00 get pods -w
```
3. İLK terminalde 50 eşzamanlı kullanıcıyla 30 sn link oluştur, sonra sürecin neden öldüğüne bak:
```bash
make load S=create K6_ARGS="--vus 50 --duration 30s"
kubectl -n lvl00 get pods
kubectl -n lvl00 logs "$pod" --previous | grep -m1 'concurrent map'
kubectl -n lvl00 get pod "$pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'; echo
```
4. Pod'u taze başlat: çöken pod geri çekilme (CrashLoopBackOff) beklemesinde; sonraki deney sağlam bir pod'la başlasın
   (ikinci terminaldeki izlemeyi Ctrl+C ile durdurabilirsin):
```bash
kubectl -n lvl00 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl00 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
```
5. İstersen karşılaştır: aynı pod'a tek kullanıcıyla 90 sn yük ver — istekler hızlı ama hiçbiri bir diğeriyle aynı anda
   işlenmiyor:
```bash
make load S=redirect K6_ARGS="--vus 1 --duration 90s"
kubectl -n lvl00 get pods
```

**Terminalde ne görmelisin:** 1. adımda `RESTARTS 0`. Yük başlar başlamaz ikinci terminalde pod `Error` →
`CrashLoopBackOff` → `Running` arasında gidip gelir ve `RESTARTS` birkaç saniyede bir artar. k6 çıktısının sonundaki
özet satırı (`k6 lvl00: reqs=… 5xx=…`) büyük bir `5xx` sayısı gösterir: pod ölüyken ingress `503`, pod istek işlerken öldüyse
`502` döner. Log satırı `fatal error: concurrent map writes`, sonlanma nedeni `Error`: süreci kimse öldürmedi, Go
çalışma zamanı kendisi durdurdu. 5. adımda k6 özeti `5xx=0` ve `RESTARTS` 0'da kalır: saniyede ~1500 istek bile
tek kullanıcıyla eşzamanlı değildir.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl00&from=now-15m&to=now&refresh=10s) — yükü verdikten sonra aç (giriş: admin / ladder)
- "Yeniden başlatma sayısı" → yükle birlikte **basamak basamak** artar; her basamak bir çöküş.
- "CPU kullanımı (bir çekirdeğin %'si)" ve "Bellek: sınırın yüzde kaçı" → **sakin kalır** — ve doğrusu bu. Çöküşün sebebi kaynak değil: Go çalışma zamanı iki goroutine'in aynı map'e aynı anda yazdığını fark edip süreci **bilerek** öldürür (`fatal error: concurrent map writes`). Bu, CPU %1'deyken de %90'dayken de aynı şekilde olur; iki eşzamanlı istek yeter. CPU'nun neredeyse sıfır görünmesinin iki sebebi daha var: süreç yükün ilk anında çöker ve 30 saniyenin çoğunu ölü ya da yeniden başlatılmayı beklerken (CrashLoopBackOff) geçirir — k6'nın gördüğü 503'leri pod değil ingress üretir; ve küme metrikleri 30 sn'de bir toplandığı için iki toplama arasında doğup ölen bir konteynerin CPU'su **hiç kaydedilmez**. Karşılaştırma için çökmeyen bir yük: `make load S=redirect K6_ARGS="--vus 1 --duration 90s"` (tek kullanıcı, eşzamanlılık yok) aynı pod'u saniyede ~1500 istekle bir çekirdeğin ~%13'üne çıkarır ve pod ayakta kalır. **Ders: sakin bir kaynak grafiği "sağlıklı" demek değildir; mantık hatası kaynak panelinde görünmez**, kanıtı "Yeniden başlatma sayısı", "Son sonlanma nedeni" ve `--previous` logundadır.
- "Son sonlanma nedeni" → metin kutusunda turuncu `<pod>: Error`: süreç kendi kendine öldü (`OOMKilled` olsaydı bellek, `Completed` olsaydı dışarıdan kapatma olurdu).
- "Hazır pod adresi (endpoint) sayısı" → normalde 1; çöküş anında **0'a iner** = o anda trafiği alacak pod yok. Pod birkaç saniyede geri geldiği ve küme metrikleri 30 sn'de bir toplandığı için her çöküş bir 0 noktası bırakmaz; 30 sn'lik yükte bir ya da iki çentik görmek normaldir — restart sayısı kesin kanıttır.
- "Dönen durum kodları" (k6) → `503` (pod yokken ingress'in "servis yok" cevabı) ve `502` (pod istek işlerken öldü) çizgileri, `201`'i (başarılı oluşturma) ezer. Hatalar anında döndüğü için sayıca şişer; bkz. [Grafana'yı okumak](../README.md#grafanayı-okumak).
- `02 · App RED` bu seviyede **boştur** — 00'ın `/metrics` ucu yok (P00-09). Çöküşü yalnızca dışarıdan görürsün.

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

Otomatik: `CONFIRM=1 make repro P=P00-02` (bir link oluşturur, çalıştığını doğrular, pod'u siler ve aynı kodu yeniden ister).

Elle — sırayla yapıştır:

1. Grafana'yı temizle, bir link oluştur ve çalıştığını gör:
```bash
make fresh
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0002"}' | jq -r .code); echo "kod: $code"
curl -s -o /dev/null -w 'restart öncesi: %{http_code}\n' http://lvl00.localtest.me/$code
```
2. Pod'u sil (Deployment yenisini açar), ingress yeni pod'u görene kadar bekle, aynı kodu tekrar iste:
```bash
kubectl -n lvl00 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl00 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
sleep 5
curl -s -o /dev/null -w 'restart sonrası: %{http_code}\n' http://lvl00.localtest.me/$code
kubectl -n lvl00 get pods
```

**Terminalde ne görmelisin:** 4 karakterlik bir kod, `restart öncesi: 301`, ardından `restart sonrası: 404`.
`kubectl get pods` yeni bir pod adı ve `RESTARTS 0` gösterir: pod yeniden başlatılmadı, yenisiyle değiştirildi — ve
link eski pod'un belleğiyle birlikte gitti.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl00&from=now-15m&to=now&refresh=10s) — pod'u sildikten sonra aç (giriş: admin / ladder)
- "Bellek kullanımı" → eski pod'un çizgisi biter, yeni pod adıyla yeni bir çizgi başlar: bellek — ve içindeki bütün linkler — yeni pod'da boş başladı.
- "Yeniden başlatma sayısı" → **artmaz**: pod yeniden başlatılmadı, yenisiyle değiştirildi; yeni pod'un çizgisi 0'dan başlar. Veri kaybını restart sayacından okuyamazsın.
- "Kayıtlı link sayısı" → **No data**: 00 bu metriği üretmiyor (P00-09), yani **kaybı ölçemezsin bile**. 01'de sayaç görünür ve restartta dikey olarak sıfıra düşer (P01-01).

**Nerede çözülüyor:** 02 (Postgres). Not: P00-01 ve P00-08 bu sorunu *sürekli* tetikler — çökme ve OOM
zaten restart demek.

---

### P00-03 · `replicas>1` → rastgele 404

**Belirti:** İki replikaya çıkınca aynı kısa link bazen çalışır, bazen 404 verir.
**Neden:** Her pod'un kendi map'i var; Service istekleri rastgele dağıtır. N replikada bir linki bulma
olasılığı 1/N. [Topic · Konu: Yatay ölçekleme, stateless servis]

**Reproduce (adım adım):**

Otomatik: `CONFIRM=1 make repro P=P00-03` (3 replikaya çıkar, endpoint'lerin 3'e çıkmasını bekler, bir link oluşturup 60 kez okur, sonunda eski replika sayısına döner).

Elle — sırayla yapıştır:

1. Grafana'yı temizle, 3 replikaya çık ve ingress üç pod'u da görene kadar bekle (Ölçüm notu):
```bash
make fresh
kubectl -n lvl00 scale deploy/linkly --replicas=3
kubectl -n lvl00 rollout status deploy/linkly
sleep 10
kubectl -n lvl00 get endpointslice -l kubernetes.io/service-name=linkly
```
2. Bir link oluştur (yalnızca onu alan pod'un belleğine yazılır), aynı kodu 60 kez iste:
```bash
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0003"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code} ' http://lvl00.localtest.me/$code; done; echo
```
3. Geri al:
```bash
kubectl -n lvl00 scale deploy/linkly --replicas=1
kubectl -n lvl00 rollout status deploy/linkly
```

**Terminalde ne görmelisin:** `get endpointslice` satırının `ENDPOINTS` sütununda üç pod adresi. 60 cevabın yaklaşık
üçte biri `301`, üçte ikisi `404` — ölçülen tur: **60 okumadan 40'ı 404 (%66)**. Link yalnızca bir pod'un
belleğinde; ingress istekleri üç pod'a sırayla dağıtıyor.

**Ölçüm notu:** Script ölçekledikten sonra Service endpoint'lerinin gerçekten 3'e çıkmasını bekler.
Beklemezsen ingress'in upstream listesi birkaç saniye geriden gelir, tüm istekler tek pod'a düşer ve
sonuç yanlış negatif olur: 30 okumada 0 adet 404.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl00&from=now-15m&to=now&refresh=10s) — script çalışırken ya da hemen sonra aç (giriş: admin / ladder)
- "Hazır pod adresi (endpoint) sayısı" → 1'den **3**'e çıkar: Service istekleri artık üç ayrı belleğe dağıtıyor. Script bitince eski replika sayısına (1) döner.
- "404 (pod'a göre)" → **No data**: 00'da redirect metriği yok (P00-09). 404'leri yalnızca scriptin çıktısında görürsün (`60 okumadan 40 tanesi 404`); 01'de (P01-02) aynı panel pod başına ayrı çizgi çizer.

**Nerede çözülüyor:** 02. Bu, "ölçeklenebilirlik" sözünün neden **stateless** ile başladığının kanıtı.

---

### P00-04 · Rollout sırasında hata dalgası

**Belirti:** `kubectl rollout restart` sırasında client'lar 502/503 alır, bağlantılar yarıda kopar.
**Neden:** İki eksik: (a) readinessProbe yok → Kubernetes yeni pod'u hazır saymadan Endpoint'e ekler,
(b) graceful shutdown yok → SIGTERM gelince süreç işlenmekte olan istekleri bırakıp ölür. Ayrıca preStop
gecikmesi olmadığı için pod, ingress'in endpoint listesinden düşmeden önce ölmeye başlar.
[Topic · Konu: Kapatma sırası, hazır olma sinyali]

**Reproduce (adım adım):**

Otomatik: `make repro P=P00-04` (readinessProbe ve preStop'un yokluğunu gösterir, tek kullanıcılı redirect yükü altında 3 kez `rollout restart` yapar, 5xx ile 404'ü ayrı sayar). Yarışı kaçırırsa: `ROLLOUTS=6 make repro P=P00-04`.

Elle — sırayla yapıştır:

1. Grafana'yı temizle; pod'un trafiğe hazır olduğunu ve kapanırken ne yapacağını söyleyen bir ayar var mı, bak:
```bash
make fresh
kubectl -n lvl00 get deploy linkly -o yaml | grep -cE 'readinessProbe|livenessProbe|preStop'
```
2. İKİNCİ bir terminalde `00-naive` klasöründe **tek kullanıcılı** yükü başlat (paralel yük P00-01'i tetikler — Ölçüm notu):
```bash
make load S=redirect K6_ARGS="--vus 1 --duration 90s"
```
3. Yük başladıktan ~15 sn sonra İLK terminalde üç kez art arda dağıtım yap:
```bash
for i in 1 2 3; do kubectl -n lvl00 rollout restart deploy/linkly; kubectl -n lvl00 rollout status deploy/linkly; sleep 5; done
```

**Terminalde ne görmelisin:** 1. adımda `0`: ne readiness/liveness probe ne de preStop var. İkinci terminalde k6 çıktısının
sonundaki özet satırında (`k6 lvl00: reqs=… 5xx=… 404=…`) `5xx` sıfırdan büyüktür (ölçülen tur: 142) — dağıtım penceresinin
kendisi, bu sorun. `404` ise çok daha büyüktür: ilk dağıtımdan sonra yeni pod'un belleği boş, k6'nın elindeki
kodların hiçbiri yok (P00-02, ayrı sorun). `5xx=0` çıkarsa yarışı kazandın: 3. adımı yeni bir yükle tekrarla.

**Ölçüm notu (önemli):** Yük **tek VU** ile verilir. Paralel istek P00-01'i tetikler, hata oranı %99'a
fırlar ve "rollout mu çökme mi kaybettirdi?" ayırt edilemez. Ayrıca k6'nın tek bir `http_req_failed`
oranına bakmak yanıltır: rollout'tan sonra gelen **404'ler P00-02'dir** (yeni pod'un belleği boş),
rollout penceresinin kendisi ise **5xx** üretir. Bu yüzden senaryolar 5xx ve 404'ü ayrı sayar.

**Grafana'da gör:** [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl00&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; yük yaklaşık 1 dk sürer (giriş: admin / ladder)
- "Dönen durum kodları" → yük `301` ile başlar; ilk `rollout restart`'tan sonra `301`'in yerini `404` alır — yeni pod'un belleği boş (P00-02, ayrı sorun). Her rollout anında `502`/`503` belirir: bu sorunun kendisi. Diğer çizgilerin yanında çok küçük kaldığı için lejantta `502`'ye (ya da `503`'e) tıklayıp tek başına bak.
- "Başarısız oran (zaman içinde)" → ilk rollout'ta yükselir ve bir daha inmez: k6 404'ü de hata sayar. Tek başına bu panel iki sorunu karıştırır (bkz. Ölçüm notu).
- "Bellek kullanımı" → her rollout'ta eski pod'un çizgisi biter, yeni pod adıyla yeni bir çizgi başlar; bu geçişler 15 · k6'daki "Dönen durum kodları" panelinin 5xx anlarıyla üst üste düşer.
- `02 · App RED` bu seviyede **boştur** (P00-09): 5xx'i yalnızca istemci tarafından görürsün; bkz. [Grafana'yı okumak](../README.md#grafanayı-okumak).

**Nerede çözülüyor:** 01 (probe'lar + `preStop` + `Server.Shutdown` sırası).

---

### P00-05 · 4 karakterlik kod, çakışma kontrolü yok

**Belirti:** Yeterince link üretince iki farklı kullanıcı aynı kodu alır; ilkinin linki **sessizce** ikinciyle
değişir. Hata yok, log yok.
**Neden:** `newCode()` 4 karakter base62 üretiyor (62⁴ ≈ 14.8 M) ve `links[code] = url` mevcut kaydı kontrol
etmeden üzerine yazıyor. Doğum günü paradoksu: ~4.5 k linkte %50 çakışma olasılığı. Ayrıca `math/rand`
tahmin edilebilir. [Topic · Konu: Anahtar üretimi, doğum günü paradoksu]

**Reproduce (adım adım):**

Otomatik: `make repro P=P00-05` (10.000 link üretir — sıralı, ~2 dk —, "N üretim, M benzersiz → K çakışma" der ve çakışan kodun **şu an kime ait olduğunu** gösterir).

Elle — sırayla yapıştır:

1. Grafana'yı temizle, 10.000 link oluştur — **sıralı**, paralel değil (Ölçüm notu) — ve cevapları bir dosyada topla
   (birkaç dakika sürer):
```bash
make fresh
for i in $(seq 1 10000); do curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d "{\"url\":\"https://example.com/u/$i\"}"; done > /tmp/p0005.json
```
2. Kodları say, çakışan birini seç ve o kodun şu an nereye gittiğine bak:
```bash
jq -r .code /tmp/p0005.json | wc -l
jq -r .code /tmp/p0005.json | sort -u | wc -l
dupe=$(jq -r .code /tmp/p0005.json | sort | uniq -d | head -1); echo "çakışan kod: $dupe"
grep -F "\"code\":\"$dupe\"" /tmp/p0005.json
curl -s http://lvl00.localtest.me/api/links/$dupe | jq .
```

**Terminalde ne görmelisin:** önce `10000`, sonra ondan birkaç eksik — ölçülen tur: **10000 üretim, 9997 benzersiz → 3
çakışma** (beklenen n²/2N = 3.4 ile birebir). `grep` aynı kodu taşıyan **iki** oluşturma cevabı basar, `url`'leri farklı
(`…/u/<i>` ve `…/u/<j>`): iki kullanıcıya da `201` ve aynı kısa link verildi. `GET /api/links/<kod>` yalnızca
sonrakinin `url`'ini döner; ilkinin linki hata vermeden yok oldu. `çakışan kod:` boş kalırsa (olasılık ~%4) bu turda
çakışma çıkmadı: 1. adımı `seq 1 20000` ile tekrarla.

**Ölçüm notu:** Üretim **sıralı** yapılır. Paralel denersen P00-01 devreye girer: süreç çöker, üretim
durur, map sıfırlanır ve çakışmayı ölçemezsin (paralel bir turda 10.000 istekten yalnızca 362'si tamamlanır).
**Sorunlar birbirini maskeler** — bir katmandaki hata, alttakini görünmez yapar. Bu, merdivenin
tekrar tekrar karşına çıkacak dersi.

**Grafana'da gör:** Grafana'da görünmez — `03 · App Business` → "create sonuçları" panelinde `collision` serisi olurdu ama 00'da böyle bir metrik yok; çakışma hiçbir katmanda iz bırakmaz — **sessiz veri kaybının en saf örneği**. Kanıt terminalde:
- `make repro P=P00-05` → `10000 üretim, 9997 benzersiz kod → 3 çakışma` ve ardından çakışan kodun şu an **kime** ait olduğu ("Bu kodu İKİ kullanıcı aldı; kayıtta yalnızca sonuncusu var").
- `curl -s http://lvl00.localtest.me/api/links/<çakışan-kod>` → yalnızca son yazanın URL'i; ilk kullanıcının linki hata vermeden yok oldu.

**Nerede çözülüyor:** 01 (`crypto/rand`, 7 karakter, `CreateUnique` + retry, `create_total{result="collision"}` sayacı).

---

### P00-06 · Giriş doğrulaması yok

**Belirti:** `javascript:alert(1)`, `http://169.254.169.254/...`, boş URL ve 5 MB'lık gövde kabul edilir.
**Neden:** Handler `json.Decode` dışında hiçbir kontrol yapmıyor: şema allowlist'i yok, host kontrolü yok,
`MaxBytesReader` yok. Kısaltıcı **güvenilir görünen** bir link üretip tarayıcıyı hedefe yolladığı için bu bir
open-redirect ve (kurum içi tarayıcılarda) iç ağa yönlendirme yüzeyidir. [Topic · Konu: Giriş doğrulama, open redirect]

**Reproduce (adım adım):**

Otomatik: `make repro P=P00-06` (`javascript:`, metadata adresi, boş/bozuk URL ve 5 MB'lık gövdeyi dener; gövdeyi önce ingress üzerinden, sonra doğrudan pod'a gönderir).

Elle — sırayla yapıştır:

1. Grafana'yı temizle; `javascript:` hedefli bir link oluştur ve yönlendirmenin nereye gittiğine bak:
```bash
make fresh
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"javascript:alert(1)"}' | jq -r .code); echo "kod: $code"
curl -sI http://lvl00.localtest.me/$code | grep -i '^location'
```
2. Aynısını bulut metadata adresiyle (iç ağ) dene:
```bash
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"http://169.254.169.254/latest/meta-data/"}' | jq -r .code); echo "kod: $code"
curl -sI http://lvl00.localtest.me/$code | grep -i '^location'
```
3. Boş ve bozuk URL'ler:
```bash
for u in '' 'not-a-url' '   '; do curl -s -o /dev/null -w "[$u] → %{http_code}\n" -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d "{\"url\":\"$u\"}"; done
```
4. 5 MB'lık gövde: önce ingress üzerinden, sonra ingress'i atlayıp doğrudan pod'a (port-forward) gönder, en sonda
   port-forward'u kapat:
```bash
{ printf '{"url":"https://e.com/'; head -c 5000000 /dev/zero | tr '\0' 'a'; printf '"}'; } > /tmp/p0006-big.json
curl -s -o /dev/null -w 'ingress üzerinden: %{http_code}\n' -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' --data-binary @/tmp/p0006-big.json
pod=$(kubectl -n lvl00 get pod -l app.kubernetes.io/name=linkly -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "pod: $pod"
kubectl -n lvl00 port-forward "pod/$pod" 18080:8080 >/dev/null 2>&1 &
pf=$!
sleep 3
curl -s -o /dev/null -w 'doğrudan pod: %{http_code}\n' --max-time 60 -XPOST http://127.0.0.1:18080/api/links -H 'Content-Type: application/json' --data-binary @/tmp/p0006-big.json
kill $pf
rm -f /tmp/p0006-big.json
```

**Terminalde ne görmelisin:** 1. adımda `Location: javascript:alert(1)`, 2. adımda
`Location: http://169.254.169.254/latest/meta-data/` — ikisi de `201` ile kabul edildi ve kısaltıcı tarayıcıyı oraya
yollayacak. 3. adımda `[] → 201`, `[not-a-url] → 201`, `[   ] → 201`. 4. adımda `ingress üzerinden: 413` ama
`doğrudan pod: 201`: 413'ü uygulama değil ingress-nginx verdi (Ölçüm notu); uygulamanın kendisi 5 MB'ı belleğe aldı.

**Ölçüm notu:** Ingress'ten gelen 413'ü **uygulama vermiyor** — ingress-nginx'in varsayılan
`proxy-body-size: 1m` limiti veriyor. Yani koruma, senin tasarlamadığın bir katmandan tesadüfen geldi.
Bu yüzden script uygulamanın kendi davranışını görmek için ingress'i atlayıp doğrudan pod'a bağlanır:
uygulama 5 MB'ı sorunsuz belleğe alır. **Başkasının verdiği korumaya güvenemezsin** — o katman
yarın değişir, kaldırılır ya da atlanır (servis-içi çağrı, port-forward, service mesh bypass).

**Grafana'da gör:** [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl00&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) — scripti koştuktan sonra aç (giriş: admin / ladder)
- "Tehlikeli URL reddi (sebebe göre)" → **No data** (sıfır değil): 00 hiçbir şeyi reddetmiyor, üstelik reddi sayacak metriği de yok (P00-09). 01'de aynı panelde `scheme` ve `private_address` çizgileri belirir.
- "Bellek kullanımı" → script 5 MB'lık gövdeyi doğrudan pod'a gönderdiği anda çizgi yukarı sıçrar ve eski seviyesine dönmez: uygulama gövdeyi kabul edip map'te sakladı.

**Nerede çözülüyor:** 01 (şema allowlist, host kontrolü, `MaxBytesReader`) · 13 (DNS çözümü ile özel IP reddi).
Not: Bu bir *azaltma*, eliminasyon değil — 13'te TOCTOU sınırı anlatılıyor.

---

### P00-07 · Sunucu timeout'u yok (slowloris)

**Belirti:** Birkaç yüz yavaş/yarım bağlantı normal istekleri yavaşlatır; pod CPU'su neredeyse boştur.
**Neden:** `http.ListenAndServe` varsayılanları: `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout`,
`IdleTimeout` **hiçbiri yok**. İsteğini bitirmeyen her bağlantı bir goroutine ve bir soket tutar; sunucu
kendini korumaz. [Topic · Konu: Timeout, kaynak tükenmesi]

**Reproduce (adım adım):**

Otomatik: `make repro P=P00-07` (doğrudan pod'a bağlanır, yarım bir istek gönderip 20 sn bekler ve **sunucunun bu boşta duran yarım bağlantıyı kapatıp kapatmadığını** sorar; sonra 300 yarım bağlantı açar — her biri bir goroutine + bir FD).

Elle — sırayla yapıştır:

1. Grafana'yı temizle; ingress'i atlamak için pod'a port-forward aç (ingress yarım bağlantıları kendi timeout'larıyla
   yutar — Ölçüm notu 1):
```bash
make fresh
pod=$(kubectl -n lvl00 get pod -l app.kubernetes.io/name=linkly -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "pod: $pod"
kubectl -n lvl00 port-forward "pod/$pod" 18081:8080 >/dev/null 2>&1 &
pf=$!
sleep 3
```
2. Yarım bir istek gönder (başlıklar tam, gövdenin 500 baytından yalnızca 1'i), 20 sn bekle ve sunucunun bağlantıyı
   kapatıp kapatmadığına bak; sonra 300 yarım bağlantı aç ve 5 sn tut (scriptin Python parçasının aynısı, ~30 sn sürer):
```bash
python3 - <<'PY'
import socket, time
s = socket.create_connection(("127.0.0.1", 18081), timeout=5)
s.sendall(b"POST /api/links HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 500\r\n\r\n{")
time.sleep(20)
s.settimeout(3)
try:
    s.recv(1024)
    print("20 sn sonra: sunucu bağlantıyı KAPATTI ya da cevap verdi (koruma var)")
except socket.timeout:
    print("20 sn sonra: bağlantı hâlâ AÇIK, sunucu yarım isteği bekliyor (koruma yok)")
except OSError:
    print("20 sn sonra: sunucu bağlantıyı KAPATTI (koruma var)")
s.close()
held = []
for _ in range(300):
    try:
        c = socket.create_connection(("127.0.0.1", 18081), timeout=3)
        c.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")
        held.append(c)
    except OSError:
        break
print("aynı anda tutulan yarım bağlantı:", len(held))
time.sleep(5)
PY
```
3. port-forward'u kapat:
```bash
kill $pf
```

**Terminalde ne görmelisin:** `20 sn sonra: bağlantı hâlâ AÇIK, sunucu yarım isteği bekliyor (koruma yok)` ve
`aynı anda tutulan yarım bağlantı: 300` — ölçülen tur: `20 sn sonra AÇIK TUTUYOR, 300 bağlantı birikti`. Hiçbir timeout
yok: her yarım bağlantı bir goroutine ve bir dosya tanımlayıcısı olarak kalır. `ReadHeaderTimeout` olsaydı sunucu
saniyeler içinde kapatırdı; aynı adımlar 01'de `(koruma var)` diye biter.

**Ölçüm notu 1:** Ingress üzerinden ölçmek işe yaramaz — ingress-nginx yarım bağlantıları kendi
timeout'larıyla yutar (yine P00-06'daki ders: koruma senin değil).
**Ölçüm notu 2:** Go'da slowloris **yeni istekleri yavaşlatmaz** (her bağlantı kendi goroutine'inde,
Apache'deki gibi worker havuzu tükenmesi yok). Gerçek belirti birikmedir: goroutine, FD ve bellek.
Bu yüzden test "yavaşladı mı?" diye değil, **"sunucu hiç kapatıyor mu?"** diye sorar — `ReadHeaderTimeout`
olsaydı saniyeler içinde kapatırdı. Aynı script 01'de NOT-REPRODUCED verir.

**Grafana'da gör:** Grafana'da görünmez — birikim goroutine ve FD olarak olur; `01 · Pods & Resources` → "Goroutine" paneli 01'den itibaren dolar, 00'da **bu paneli dolduramıyorsun** (`/metrics` yok). Script 300 bağlantıyı yalnızca ~5 sn tuttuğu için bellek çizgisinde de iz kalmaz. Yani sorunun varlığını sunucu tarafından kanıtlayamıyorsun; bu, P00-09'un pratik sonucu. Kanıt terminalde:
- `make repro P=P00-07` → `Yarım istek 20 sn sonra: sunucu hâlâ sessizce BEKLİYOR (koruma yok)` ve `sunucu yarım bağlantıyı 20 sn boyunca kapatmadı — hiçbir timeout yok, 300 bağlantı birikti`

**Nerede çözülüyor:** 01 (`ReadHeaderTimeout`, `IdleTimeout`, istek başına timeout middleware).

---

### P00-08 · Bellek sınırsız büyür → OOMKilled

**Belirti:** Yük sürdükçe working set 128 Mi limitine tırmanır, konteyner `OOMKilled` olur, restart eder —
ve P00-02 gereği tüm linkler gider.
**Neden:** Store'da eviction yok, TTL yok, üst sınır yok. Bellek = sınırsız kuyruk: sonu ertelenmiş çöküş.
[Topic · Konu: Bounded resources, kapasite planlaması]

**Reproduce (adım adım):**

Otomatik: `make repro P=P00-08` (taze bir pod'la başlar, tek akışla 4 KB'lık URL'ler üretir — 2 dk —, sonlanma nedenini ve OOM olaylarını okur). OOM gelmezse: `DURATION=240s URL_SIZE=8000 make repro P=P00-08`.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, pod'u taze başlat, adını ve bellek sınırını al:
```bash
make fresh
kubectl -n lvl00 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl00 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
pod=$(kubectl -n lvl00 get pod -l app.kubernetes.io/name=linkly -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "pod: $pod"
kubectl -n lvl00 get deploy linkly -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'; echo
```
2. İKİNCİ bir terminalde `00-naive` klasöründe pod'u canlı izle:
```bash
kubectl -n lvl00 get pods -w
```
3. İLK terminalde **tek kullanıcıyla** (paralel yük OOM değil P00-01 çökmesi üretir — Ölçüm notu 1) 2 dk boyunca
   4 KB'lık linkler üret, sonra konteynerin neden öldüğüne bak:
```bash
URL_SIZE=4000 make load S=create K6_ARGS="--vus 1 --duration 120s"
kubectl -n lvl00 get pods
kubectl -n lvl00 describe pod "$pod" | grep -A4 'Last State'
```
4. Pod'u taze başlat (geri çekilme beklemesi sonraki deneyi geciktirmesin; ikinci terminaldeki izlemeyi Ctrl+C ile
   durdurabilirsin):
```bash
kubectl -n lvl00 delete pod -l app.kubernetes.io/name=linkly
kubectl -n lvl00 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
```

**Terminalde ne görmelisin:** 1. adımda `128Mi`. Yük sürerken ikinci terminalde pod `OOMKilled` durumuna düşüp yeniden
`Running` olur ve `RESTARTS` basamak basamak artar. `describe` çıktısında `Last State: Terminated`,
`Reason: OOMKilled`, `Exit Code: 137` — ölçülen tur: `restart 0 → 3 · son sonlanma: OOMKilled (exit 137)`. Her OOM
bütün linkleri de götürür (P00-02). Sonlanma nedeni `Error` çıkarsa bu OOM değil P00-01 çökmesidir; OOM hiç gelmezse
3. adımı `URL_SIZE=8000` ve `--duration 240s` ile tekrarla.

**Ölçüm notu 1 (ayrım):** Yine tek VU. Paralel yükte `reason=Error` çıkar — bu **OOM değil,
P00-01 çökmesi**. Script bu ikisini ayırır: `OOMKilled` → P00-08, `Error` → P00-01 (ve "ölçüm kirlendi" der).
**Ölçüm notu 2 (örnekleme):** Grafana'daki tepe bellek değeri limitin **altında** görünür (ölçülen turda
6 MB / 128Mi). Sebep: Prometheus 15 sn'de bir örnekliyor, konteyner iki örnek arasında dolup ölüyor.
Yani *metrik grafiği olayı kaçırabilir*; asıl kanıt `OOMKilled` + `exit 137`. Örnekleme çözünürlüğünün
gerçeği gizlemesi 11'de (sampling, exemplar) tekrar karşına çıkacak.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; yük 2 dk sürer (giriş: admin / ladder)
- "Son sonlanma nedeni" → metin kutusunda kırmızı `<pod>: OOMKilled` belirir: konteyneri bellek limiti öldürdü (P00-01'deki turuncu `Error` ise sürecin kendi çöküşüydü).
- "Yeniden başlatma sayısı" → yük boyunca **basamak basamak** artar (ölçülen tur: 0 → 3); her basamak bir OOM ve P00-02 gereği tüm linklerin kaybı.
- "Bellek: sınırın yüzde kaçı" → sınır 128 MiB; çizgi %100'e **değmeyebilir** — konteyner iki örnek arasında dolup ölüyor (ölçülen tepe 6 MB, yani %5 civarı; bkz. Ölçüm notu 2). Grafik olayı kaçırabilir; asıl kanıt yukarıdaki iki panel.

**Nerede çözülüyor:** 01 kısmen (ölçüm + `links_total`), asıl 02 (durum DB'de) · 03 (bounded LRU).

---

### P00-09 · Gözlemlenebilirlik sıfır

**Belirti:** "Son 5 dakikada kaç 404 döndük?", "p99 kaç ms?", "hangi endpoint yavaş?" — hiçbirini
cevaplayamazsın.
**Neden:** `/metrics` ucu yok, yapılandırılmış log yok, request-id yok. Prometheus'un gördüğü tek şey
cAdvisor ve kube-state-metrics: CPU, bellek, restart. Bunlar **altyapı** metrikleri; uygulama hakkında
hiçbir şey söylemezler. [Topic · Konu: Gözlemlenebilirlik, RED metrikleri]

**Reproduce (adım adım):**

Otomatik: `make repro P=P00-09` (30 başarılı + 10 başarısız istek üretir, sonra `/metrics` ucuna ve Prometheus'a "kaç 404 döndü?" diye sorar).

Elle — sırayla yapıştır:

1. Grafana'yı temizle; 30 başarılı yönlendirme ve 10 tane `404` üret:
```bash
make fresh
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0009"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 30); do curl -s -o /dev/null http://lvl00.localtest.me/$code; done
for i in $(seq 1 10); do curl -s -o /dev/null http://lvl00.localtest.me/yoxxxxx; done
```
2. Önce uygulamaya, sonra Prometheus'a sor; karşılaştırma için Kubernetes'in bu pod hakkında bildiğine de bak:
```bash
curl -s -o /dev/null -w '/metrics → %{http_code}\n' http://lvl00.localtest.me/metrics
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=http_requests_total{namespace="lvl00"}' | jq '.data.result | length'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=kube_pod_info{namespace="lvl00"}' | jq '.data.result | length'
```

**Terminalde ne görmelisin:** `/metrics → 404` — 00'da `/metrics` yalnızca var olmayan bir kısa kod. Prometheus'ta
bu seviyenin uygulama serisi sayısı `0`: az önce ürettiğin 10 tane 404'ü kimse saymadı. Aynı Prometheus pod'un
varlığını biliyor (`1`, kube-state-metrics'ten): altyapı metriği var, uygulama metriği yok. Grafana'da `02 · App RED`
ve `03 · App Business`'ın bütün panelleri "No data".

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl00&from=now-15m&to=now&refresh=10s), [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl00&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now&refresh=10s) — scripti koştuktan sonra aç; boş olmasının **kendisi** kanıt (giriş: admin / ladder)
- "Saniyedeki istek" → **No data** — oysa script az önce 40 istek gönderdi.
- "Bulunamayan link / sn (404)" → **No data**: 10 tane 404 ürettin, kaç tane olduğunu Prometheus'a soramıyorsun.
- "CPU kullanımı (bir çekirdeğin %'si)" → **dolu** (cAdvisor): konteyneri dışarıdan görüyorsun. Pod'un çalıştığını söyler; kaç isteğin 404 olduğunu ya da p99'u söylemez — altyapı metriği, uygulama metriği değil.
- Explore'da: `http_requests_total{namespace="lvl00"}` → boş sonuç: Prometheus'ta bu seviyenin tek bir uygulama serisi yok.

**Nerede çözülüyor:** 01 (Prometheus metrikleri sıfırla pre-register, slog JSON, request-id, ServiceMonitor).

---

### P00-10 · 301 + `Cache-Control` yok

**Belirti:** Chrome'da bir kısa linki açtıktan sonra linki silsen bile tarayıcı yönlendirmeye devam eder;
tıklamalar sayılmaz.
**Neden:** `http.Redirect(..., http.StatusMovedPermanently)` ve hiçbir önbellek başlığı yok. 301 "bu eşleme
kalıcıdır" demektir; tarayıcı bunu süresiz saklayabilir ve bir daha sunucuya sormaz. Kısa link eşlemesi
**iptal edilebilir** olduğu için 301 yanlış sözdür. [Topic · Konu: HTTP önbellekleme, semantik]

**Reproduce (adım adım):**

Otomatik: `make repro P=P00-10` (durum kodunu ve `Cache-Control` başlığını gösterir, linki silip önbelleksiz bir client'ın ne gördüğünü basar). Asıl ikna edici olan tarayıcı; o kısım yalnızca elle.

Elle — sırayla yapıştır:

1. Grafana'yı temizle; bir link oluştur, yönlendirmenin durum satırına ve başlıklarına bak:
```bash
make fresh
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0010"}' | jq -r .code); echo "kod: $code"
curl -sI http://lvl00.localtest.me/$code | grep -iE '^(HTTP|location|cache-control)'
```
2. Linki varsayılan tarayıcında aç (macOS `open`; Chrome'da DevTools → Network sekmesi açıkken en net görünür):
```bash
open "http://lvl00.localtest.me/$code"
```
3. Linki sil ve önbelleksiz bir client'a (curl) sor:
```bash
curl -s -o /dev/null -w 'DELETE → %{http_code}\n' -XDELETE http://lvl00.localtest.me/api/links/$code
curl -s -o /dev/null -w 'silindikten sonra curl: %{http_code}\n' http://lvl00.localtest.me/$code
```
4. Aynı adresi tarayıcıda yeniden aç:
```bash
open "http://lvl00.localtest.me/$code"
```

**Terminalde ne görmelisin:** `HTTP/1.1 301 Moved Permanently` ve `Location: https://example.com/p0010`;
`Cache-Control` satırı **yok**. `DELETE → 204`, `silindikten sonra curl: 404` — sunucu linkin gittiğini biliyor. Ama
tarayıcı 4. adımda yine `example.com/p0010`'a gider: Network sekmesinde istek `301 … (disk cache)` olarak görünür,
sunucuya hiç uğramadı. Yönlendirmeyi geri alamazsın ve bu tıklama hiçbir yerde sayılmaz.

**Grafana'da gör:** Grafana'da görünmez — tarayıcı 301'i önbellekten uyguladığında istek sunucuya **hiç uğramaz**; hiçbir sunucu metriği görmediği tıklamayı sayamaz. `03 · App Business` → "redirect ok/s" 00'da zaten boş; 01+'da da gerçek tıklamanın altında kalır. 05'te bu, analitiklerin neden eksik saydığının kökü olarak geri gelir (P05-06). Kanıt terminalde:
- `make repro P=P00-10` → `GET /<code> → HTTP 301 ; Cache-Control: '<yok>'`
- `curl -s -o /dev/null -w '%{http_code}\n' http://lvl00.localtest.me/<code>` (DELETE'ten sonra) → `404` — ama Chrome aynı adresi yönlendirmeye devam eder (Network sekmesinde `(disk cache)`).

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
| [`00 · Overview`](http://grafana.localtest.me/d/ladder-overview?var-level=lvl00&from=now-15m&to=now) | Kısmen | Pod/restart satırları dolu; availability/p99 boş (uygulama metriği yok) |
| [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now) | **Dolu** | cAdvisor + kube-state-metrics; Go runtime satırları boş (01'de gelir) |
| [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl00&from=now-15m&to=now) | **Dolu** | Client tarafı; yükü buradan görürsün — sunucudan değil |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl00&from=now-15m&to=now) | Boş | P00-09: `/metrics` yok |
| [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl00&from=now-15m&to=now) | Boş | P00-09 |
| [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl00&from=now-15m&to=now) … [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl00&from=now-15m&to=now) | Boş | Bu seviyede o bileşenler yok |

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
