# 07 — services-autoscaling · "Servisleri ayır, otomatik ölçekle"

> **Bu seviyede ne yaşayacaksın?**
> - Tek uygulamanın üç servise ayrılması ve her birinin kendi ölçekleme sinyali: redirect CPU'ya göre (HPA), tüketici kuyruk gecikmesine (lag) göre (KEDA)
> - HPA'nın yükten sonra geç gelmesi (P07-01); ölçeklemenin darboğazı DB'ye taşıması (P07-02)
> - "Hazır" ama soğuk yeni pod (P07-03); CPU limitinin gecikme üretmesi (P07-04); düğüm kapasitesi bitince Pending (P07-05)
> - Tuzaklar: N+1 sorgu (P07-06), her zaman "hazır" diyen probe (P07-08); bir düğüm donunca yedekliliğin işe yaramaması (P07-07)
>
> **Bu seviye olmasa ne olur?** Okuma, yazma ve tüketim tek bir replika sayısını paylaşır — biri yük alınca hepsi birlikte ölçeklenir ya da hiçbiri.
>
> **Yeni gelen teknolojiler:** HPA, KEDA, metrics-server, üç ayrı Deployment (redirect-svc, api-svc, analytics-consumer), `09 · Autoscaling` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Uygulama üçe ayrıldı: **redirect-svc** (trafiğin ~%99'u, salt okuma), **api-svc** (yazma ve yönetim) ve
**analytics-consumer** (06'dan). Her birinin kendi replika sayısı, bağlantı havuzu, kaynak limitleri ve ölçekleme
sinyali var: her yük şekline kendi düğmesi.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I["ingress<br/>/api → api-svc<br/>/ → redirect-svc"]
  I --> RS & AS

  subgraph RS["redirect-svc · HPA 2–12"]
    direction TB
    R1["küçük havuz (6)<br/>CPU limiti sıkı"]
  end
  subgraph AS["api-svc · sabit 2"]
    A1["büyük havuz (15)<br/>CPU limiti yok"]
  end

  RS --> RD[(redis)]
  RS ==>|clicks| K[(redpanda)]
  AS --> PG[("postgres")]
  RS -.->|MISS| PG
  K ==> CN["analytics-consumer<br/>KEDA: lag ≥ 500"]
  CN --> PG
```

Dışarıdan hiçbir şey değişmedi: aynı host, aynı URL'ler, aynı API. Servis sınırı içeriye ait bir karardır.

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P06-02 | Kuyrukta bekleyen tıklama olayları biriktiğinde (tüketici gecikmesi, lag) tüketici sayısını elle artırmak gerekiyordu | Tüketici, kuyrukta bekleyen mesaj sayısına göre kendiliğinden 1'den 6 kopyaya çıkar (KEDA `ScaledObject`). CPU'ya bakılmaz: mesaj bekleyen bir tüketici boşta görünür |

P05-03'ü (tıklama yazıcısının yönlendirmeyle aynı programı paylaşması) 06 çözdü; 07 ayrıca okuma (yönlendirme) ve
yazma (link oluşturma) yollarını ayrı servislere böler.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/07-services-autoscaling"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
make link          # example.com'a kısa link oluştur, yönlendirmeyi dene → 302 · başka adres: make link URL=https://…
make grafana       # Ladder klasörü, level=lvl07 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P07-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

Ölçeklemeyi canlı izlemek için (ayrı bir terminalde; Ctrl+C ile çık):
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 get hpa,scaledobject -w
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect -w
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl07 ayakta` yazar:
```bash
cd "$LADDER/06-event-stream"
make down
cd "$LADDER/07-services-autoscaling"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/07-services-autoscaling"
make up
```
2. 06'nın sorunlarını burada koş (yedi script, uzun sürer; koşarken başka komut çalıştırma). `BEKLENEN` sütunu
   `NOT-REPRODUCED` olan satırlar bu seviyenin çözdüğünü iddia ettikleri (burada P06-02: KEDA tüketiciyi lag'e göre
   ölçekliyor); sonuç uymazsa satır `✘` alır. `CONFIRM=1` isteyen P06-01, P06-05, P06-06 `SKIPPED` görünür:
```bash
cd "$LADDER/07-services-autoscaling"
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P07-01 → P07-08): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç. P07-05 kümeyi doldurur, P07-07 bir düğümü dondurur: ikisinde de
   son adım (geri alma) atlanmaz.
4. Bitince ayarları geri al ve seviyeyi kapat:
```bash
cd "$LADDER/07-services-autoscaling"
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). Dışarıdan fark yok: ingress yola göre yönlendirir (`/api` →
api-svc, geri kalan → redirect-svc).

## 6. Reproduce edilebilir sorunlar

Bu seviyede yaşayacağın 8 sorun. Her birini iki yoldan görebilirsin: **Otomatik** — `make repro P=<ID>` deneyi
kendisi yapar, ölçer ve hükmünü basar (`REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` =
ölçülemedi); **Elle** — adımları sırayla yapıştırıp sonucu kendi gözünle görürsün. Her sorunun bölümü aynı
düzende: **Ne oluyor** → **Neden oluyor** → **Bu deney** → adımlar → **Terminalde ne görmelisin** →
**Grafana'da gör** (giriş: admin / ladder) → **Nasıl çözülüyor**.

**Kısa komut** deneyi otomatik başlatır; seviyenin klasöründe çalıştır (önce
`cd "$LADDER/07-services-autoscaling"`). Başında `CONFIRM=1` olanlar yıkıcı bir adım içerir (pod silmek, yeniden
başlatmak, arıza enjekte etmek gibi); bu onay olmadan script o adımı yapmaz ve `SKIPPED` basar. `FREEZE_NODE=1` bir
worker düğümünü gerçekten dondurur.

| ID | Kısa komut | Ne olur? | Neden olur? | Nasıl çözülür? |
|---|---|---|---|---|
| P07-01 | `make repro P=P07-01` | Trafik birkaç saniyede 80 katına çıkınca istekler yavaşlar; yeni pod'lar ancak dalga geçtikten sonra gelir | Otomatik ölçekleyici (HPA) CPU'yu 15 sn'de bir ölçüp karar verir; pod'un yerleşmesi, açılması ve hazır olması da sürer — zincir dalgadan uzun | **Bu seviyede:** ölçekleme yavaş büyüyen trafik içindir; ani dalgaya karşı en az pod sayısı (`minReplicas`) yüksek tutulur |
| P07-02 | `make repro P=P07-02` | Pod sayısı artınca uygulama rahatlar ama veritabanı bağlantıları tükenir; istekler veritabanını bekler | Her yeni pod kendi bağlantı havuzunu açar: toplam 112 bağlantı, veritabanı en fazla 100 kabul eder | **09:** bağlantı havuzlayıcı (PgBouncer) + okuma replikaları |
| P07-03 | `make repro P=P07-03` | Yük altında yeni eklenen pod'lar eskilerden yavaş cevap verir | "Hazır" sinyali yalnızca "program açıldı" demek; bağlantılar ve önbellek henüz ısınmadı | **Bu seviyede:** açılış kontrolü (`startupProbe`), baştan açık bağlantılar, yeni pod'a trafiği yavaş açmak |
| P07-04 | `make repro P=P07-04` | CPU grafiği boşta görünürken istekler yavaşlar | CPU limiti bir kotadır: pod her 100 ms'de payını bitirince dilimin sonuna kadar bekletilir (throttling) | **Bu seviyede:** CPU limiti yerine yalnızca CPU isteği (`requests`); bellek limiti kalır |
| P07-05 | `CONFIRM=1 make repro P=P07-05` | Ölçekleyici 10 pod ister ama bir kısmı hiç çalışmaz, `Pending` bekler | Düğümlerde yer (CPU) kalmadı; ölçekleyici yalnızca sayı ister, yeni makine ekleyen yok | **Bulutta:** yeni düğüm ekleyen küme ölçekleyici (cluster autoscaler) + kapasite planı |
| P07-06 | `make repro P=P07-06` | 100 linki listeleyen tek istek veritabanına 101 sorgu gönderir; sayfa büyüdükçe yavaşlar | Tuzak (`TRAP_LIST_N_PLUS_ONE`): liste bir sorguyla gelir, sonra her link için ayrı sorgu (N+1) | **Bu seviyede:** tek toplu sorgu (tuzak kapalıyken) · **14:** servisler arası toplu çağrı |
| P07-07 | `FREEZE_NODE=1 CONFIRM=1 make repro P=P07-07` | Bir sunucu (düğüm) donunca isteklerin bir kısmı dakikalarca takılı kalır | Kubernetes donmuş düğümdeki pod'u hâlâ sağlam sanır ve trafik göndermeye devam eder (40 sn + 5 dk) | **10:** devre kesici + aktif sağlık kontrolü |
| P07-08 | `make repro P=P07-08` | Yeni sürüm dağıtılırken hata sayısı artabilir | Tuzak (`TRAP_READY_ALWAYS`): pod her zaman "hazırım" der; Kubernetes gerçekten hazır olanı ayıramaz | **Bu seviyede:** tuzak kapalıyken hazır olma kontrolü gerçek durumu söyler |

---

### P07-01 · HPA gecikir

**Ne oluyor:** Trafik birkaç saniyede saniyede 5 istekten 400'e fırlayınca (burst) yanıt süreleri uzar. Otomatik
ölçekleyici (HPA) yeni pod'ları getirir ama pod'lar ancak dalga geçtikten sonra hazır olur; ani trafiğe karşı
otomatik ölçekleme geç kalır.
**Neden oluyor:** Ölçekleme bir olaya tepki verir ve zinciri uzundur: CPU 15 sn'de bir ölçülür → HPA 15 sn'de bir
karar verir → pod bir düğüme yerleştirilir → imaj açılır → program başlar → hazır olur. Bu zincirin toplamı, 20 sn
süren bir dalgadan uzundur.
**Bu deney:** `burst` yüküyle (5 → 400 istek/sn, 20 sn tepe) yanıt süresini (p99), HPA'nın istediği pod sayısını ve
gerçekten hazır olan pod sayısını karşılaştırır.

**Reproduce (adım adım):** Otomatik: `make repro P=P07-01` (`burst` senaryosu: 5 → 400 istek/sn, 20 sn tepe; tepe p99
ile HPA'nın istediği ve gerçekten hazır olan replika sayısını karşılaştırır; daha sert tepe için
`PEAK=1000 make repro P=P07-01`, ama bu kümenin ~650 istek/sn kapasitesinin üstündedir). Elle:

1. Temiz başla; HPA'nın ve redirect pod'larının başlangıç durumuna bak:
```bash
cd "$LADDER/07-services-autoscaling"
make fresh
kubectl -n lvl07 get hpa redirect
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect
```
2. İkinci bir terminalde HPA'yı canlı izle (deney bitince Ctrl+C):
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 get hpa redirect -w
```
3. İlk terminalde ani yükü ver (~70 sn: 20 sn sessizlik, 5 sn'de 400 istek/sn'ye tırmanış, 20 sn tepe, iniş), bitince
   pod'lara bak:
```bash
cd "$LADDER/07-services-autoscaling"
make load S=burst
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect
```
4. İstersen kapasitenin üstünde bir tepeyle tekrarla (probe'lar düşebilir; sonraki soruna geçmeden bütün pod'ların
   hazır olduğunu gör):
```bash
cd "$LADDER/07-services-autoscaling"
PEAK=1000 make load S=burst
kubectl -n lvl07 get pods
```

**Terminalde ne görmelisin:** başta `MINPODS 2 · MAXPODS 12 · REPLICAS 2`, hedef `…%/60%`. Yük sürerken `TARGETS`
60'ı aşar ama `REPLICAS` ancak tepenin ortasında ya da sonunda artar. k6 özetinde (`k6 lvl07: reqs=… 5xx=… p99=…`)
p99 yüksek; yeni `redirect-…` pod'larının `AGE`'i yükün sonuna denk gelir: pod'lar yük geçtikten sonra geldi.
Özetteki `429`'lar hız sınırından (pod ve IP başına 200 istek/sn), HPA'yla ilgisi yok. Yük bitince HPA 120 sn sonra
kademeli olarak 2'ye iner.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — yük ~70 sn; bittikten sonra 1–2 dk daha izle
- "İstek / sn ve pod sayısı" → `istek / sn` dik bir tepe çizer; `pod sayısı` tepe **geçtikten sonra** basamaklanır (bütün pod'ları sayar, taban 2 değil; basamağın ne zaman geldiğine bak).
- "Otomatik ölçekleyici: istenen / mevcut pod" → `istenen: redirect` burst'ün ortasında ya da sonunda artar, `mevcut: redirect` onu gecikmeyle izler; tepeyle aradaki yatay mesafe ölçekleme zincirinin süresi.
- "p99 süre (uç noktaya göre)" → `/{code}` burst anında sıçrar ve yeni pod'lar hazır olmadan, yük bittiği için düşer.

**Nasıl çözülüyor:** Bu seviyenin dersi: otomatik ölçekleme yavaş büyüyen trafik içindir, ani dalga için değil. Dalgaya karşı sigorta, en az pod sayısını (`minReplicas`) normal tepeyi karşılayacak kadar yüksek tutmaktır.

---

### P07-02 · Ölçekleme darboğazı taşır, yok etmez

**Ne oluyor:** Yük artınca HPA yönlendirme servisini 12 pod'a çıkarır ve uygulamanın CPU'su rahatlar; ama Postgres
bağlantıları tavana dayanır ve istekler veritabanından bağlantı beklemeye başlar. Darboğaz yok olmaz, veritabanına
taşınır — ve veritabanı pod eklenerek büyütülemez.
**Neden oluyor:** Her yeni pod kendi bağlantı havuzunu açar: 12 redirect pod'u × 6 + 2 api pod'u × 15 + analytics'in
10 bağlantısı = 112. Postgres en fazla 100 bağlantı kabul eder (`max_connections=100`).
**Bu deney:** Merdiven gibi artan yük altında pod sayısını, veritabanı bağlantı sayısını, havuzdan bağlantı bekleme
süresini ve CPU'yu birlikte ölçer.

**Reproduce (adım adım):** Otomatik: `make repro P=P07-02` (aritmetiği basar, `stairs` ve rastgele kodlu `scan`
yükünü birlikte koşar; pod sayısı, DB bağlantısı, havuz beklemesi ve CPU'yu birlikte ölçer). Elle:

1. Temiz başla; aritmetiği topla: her servisin havuzu, HPA tavanı, Postgres üst sınırı:
```bash
cd "$LADDER/07-services-autoscaling"
make fresh
make env | grep -E 'deploy/|DB_MAX_CONNS'
kubectl -n lvl07 get hpa redirect
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max(pg_settings_max_connections{namespace="lvl07"})' | jq -r '"max_connections: " + .data.result[0].value[1]'
```
2. İkinci bir terminalde rastgele (var olmayan) kodlarla 150 sn yük başlat — önbellek sıcak olduğu için bilinen kodlar
   DB'ye hiç ulaşmaz, rastgele kod her istekte bir DB okuması üretir:
```bash
cd "$LADDER/07-services-autoscaling"
make load S=scan K6_ARGS="--vus 30 --duration 150s"
```
3. Hemen ardından ilk terminalde merdiven yükünü ver (50 → 100 → 200 → 400 istek/sn, basamak başına 40 sn), HPA'ya bak:
```bash
cd "$LADDER/07-services-autoscaling"
make load S=stairs
kubectl -n lvl07 get hpa redirect
```
4. İki yük bitince son 6 dakikanın tepelerini oku: redirect pod sayısı, Postgres bağlantısı, havuz beklemesi, DB hatası:
```bash
cd "$LADDER/07-services-autoscaling"
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(kube_deployment_status_replicas_available{namespace="lvl07",deployment="redirect"}[6m:15s])' | jq -r '"tepe redirect pod: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(pg_stat_activity_count{namespace="lvl07"})[6m:15s])' | jq -r '"tepe PG bağlantı: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace="lvl07"}[1m])) by (le))[6m:15s])' | jq -r '"havuz bekleme p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(db_queries_total{namespace="lvl07",result="error"}[6m]))' | jq -r '"DB hatası: " + .data.result[0].value[1]'
```

**Terminalde ne görmelisin:** 1. adımda havuzlar `DB_MAX_CONNS=10` (analytics), `15` (api), `6` (redirect); HPA
`MAXPODS 12`; `max_connections: 100` — tavanda bağlantılar yetmez. 3. adımda `REPLICAS` merdivenle artar. 4. adımda
tepe PG bağlantısı pod sayısıyla yükselmiş, `havuz bekleme p99` 0.05 sn'yi (50 ms) aşmış ya da `DB hatası` sıfırdan
büyük (scriptin eşiği): uygulama pod'ları DB'yi **bekliyor**.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s), [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) — `stairs` ~3 dk; başlatınca aç
- "Otomatik ölçekleyici: istenen / mevcut pod" → `redirect` merdivenle basamak basamak artar (en fazla 12).
- "Bağlantılar ve üst sınır" → bağlantı çizgileri pod sayısıyla yükselir ve `üst sınır` (100) çizgisine yaklaşır: her yeni pod kendi havuzunu açıyor.
- "Uygulama havuzu: bağlantı bekleme (p99)" → pod sayısı arttıkça yükselir: pod'lar bağlantı bekliyor.
- "Veritabanı CPU" → merdivenle yükselir.
- "CPU kullanımı (bir çekirdeğin %'si)" → `redirect-…` pod'larının her biri düşük kalır: darboğaz uygulamada değil.

**Nasıl çözülüyor:** 09'da bağlantı havuzlayıcı (PgBouncer) yüzlerce uygulama bağlantısını onlarca veritabanı bağlantısına indirir; okuma replikaları okuma yükünü böler. Ölçekleme darboğazı yok etmez, taşır — ve genelde büyütülemeyen yere taşır.

---

### P07-03 · Yeni pod "hazır" ama soğuk

**Ne oluyor:** Yük altında yeni pod eklendiğinde yanıt süreleri kısa bir süre yükselir; en genç pod'lar en yavaş
olanlardır. Ölçekleme tam yardıma ihtiyaç duyulan anda kısa bir yavaşlama getirir.
**Neden oluyor:** Hazır olma kontrolü (readiness) yalnızca "program açıldı ve dinliyor" der; "veritabanı
bağlantılarım açık, önbelleğim ısındı" demez. Yeni pod'un ilk istekleri bağlantı kurmayı ve veri getirmeyi bekler.
**Bu deney:** Isınmış hâldeki yanıt süresini ölçer, yük altında yönlendirme servisini 6 pod'a çıkarır ve pod başına
yanıt süresini basar; sonra 2'ye döner.

**Reproduce (adım adım):** Otomatik: `make repro P=P07-03` (ısınmış taban p99'u ölçer, yük altında redirect'i 6
replikaya çıkarır, pod başına p99'u basar, sonra 2'ye döner). Elle:

1. Temiz başla; ısınmış durumda 40 sn yük ver (taban p99):
```bash
cd "$LADDER/07-services-autoscaling"
make fresh
make load S=redirect K6_ARGS="--vus 20 --duration 40s"
```
2. İkinci bir terminalde 70 sn'lik ikinci yükü başlat:
```bash
cd "$LADDER/07-services-autoscaling"
make load S=redirect K6_ARGS="--vus 30 --duration 70s"
```
3. Yük başladıktan ~12 sn sonra ilk terminalde yük altındayken 4 yeni pod ekle:
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 scale deploy/redirect --replicas=6
kubectl -n lvl07 rollout status deploy/redirect
```
4. İkinci yük bitince pod başına p99'u ve pod'ların yaşını oku:
```bash
cd "$LADDER/07-services-autoscaling"
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=topk(6, histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl07",route="/{code}"}[2m])) by (le, pod)))' | jq -r '.data.result[] | "\(.metric.pod): \((.value[1]|tonumber*1000)|floor) ms"'
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect
```
5. Geri al:
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 scale deploy/redirect --replicas=2
```

**Terminalde ne görmelisin:** ikinci yükün `p99=` değeri (ölçekleme anını içerir) birincisinden biraz yüksek. 4. adımda
`AGE`'i en küçük `redirect-…` pod'larının p99'u eskilerden yüksek olma eğiliminde — fark küçük, çünkü önbellek
Redis'te paylaşımlı: yeni pod boş bellekle doğmuyor (03'te fark çok daha sertti). HPA kendi döngüsünde pod sayısını
yeniden hesapladığı için sayı 6'da kalmayabilir.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl07&from=now-15m&to=now&refresh=10s) — ölçekleme ikinci yükün ~12. saniyesinde
- "p99 süre (pod'a göre; yeni pod soğuk)" → ölçekleme anında dört yeni `redirect-…` çizgisi belirir; ilk noktaları eskilerden yüksek, sonra yakınsar (`api-…` çizgilerini yok say).
- "İsabet oranı (pod'a göre)" → yeni pod'ların oranı ilk noktadan eskilerle aynı: önbellek Redis'te ve zaten sıcak.

**Nasıl çözülüyor:** Bu seviyede ele alınan ayarlar: açılış kontrolü (`startupProbe`), havuzda baştan açık bağlantılar (`MinConns`), ingress'in yeni pod'a trafiği yavaş yavaş açması (slow-start). Önbellek Redis'te paylaşıldığı için yeni pod boş bellekle doğmaz; fark 03'tekinden küçüktür.

---

### P07-04 · CPU limiti bir kota'dır

**Ne oluyor:** CPU grafiği boşta görünürken istekler yavaşlar. CPU limiti kaldırılınca aynı yükte CPU kullanımı artar
ve yanıt süresi düşer; yani limit sessizce gecikme üretiyordu.
**Neden oluyor:** CPU limiti bir kotadır: pod her 100 ms'lik dilimde en fazla limiti kadar çekirdek zamanı
kullanabilir. Kota dilimin ortasında biterse program dilimin sonuna kadar bekletilir (throttling); ortalama CPU düşük
görünür ama istekler bekler.
**Bu deney:** Tek pod'u önce dar bir CPU kotasıyla (50m = bir çekirdeğin %5'i), sonra pratikte kotasız aynı yükle
koşar; yanıt süresini (p99) ve CPU kullanımını karşılaştırır.

**Reproduce (adım adım):** Otomatik: `make repro P=P07-04` (tek pod'u önce dar kotayla — varsayılan 50m — sonra
pratikte kotasız aynı yükte koşar, p99 ve CPU'yu karşılaştırır, sonra geri alır; daha dar kota:
`TIGHT=30m make repro P=P07-04`). Elle:

1. Temiz başla; redirect'in şu anki kaynaklarına bak:
```bash
cd "$LADDER/07-services-autoscaling"
make fresh
kubectl -n lvl07 get deploy redirect -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
```
2. Tek pod'a in, kotayı 50m'ye daralt, 120 kullanıcıyla 60 sn yük ver, kullanılan CPU'yu oku:
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 scale deploy/redirect --replicas=1
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=50m --limits=cpu=50m
kubectl -n lvl07 rollout status deploy/redirect
make load S=redirect K6_ARGS="--vus 120 --duration 60s"
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="lvl07",pod=~"redirect.*",image!="",image!~".*pause.*"}[1m])) * 100' | jq -r '"CPU yüzdesi (100 = bir çekirdek): " + .data.result[0].value[1]'
```
3. Kotayı pratikte kaldır (4 çekirdek, düğümün verebileceğinden büyük), aynı yükü ver:
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=100m --limits=cpu=4
kubectl -n lvl07 rollout status deploy/redirect
make load S=redirect K6_ARGS="--vus 120 --duration 60s"
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="lvl07",pod=~"redirect.*",image!="",image!~".*pause.*"}[1m])) * 100' | jq -r '"CPU yüzdesi (100 = bir çekirdek): " + .data.result[0].value[1]'
```
4. Geri al (istek ile sınır tek komutta döner; ayrı dönerse ara durumda istek sınırdan büyük olur ve API reddeder):
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=150m --limits=cpu=300m
kubectl -n lvl07 scale deploy/redirect --replicas=2
kubectl -n lvl07 rollout status deploy/redirect
```

**Terminalde ne görmelisin:** başta `"limits":{"cpu":"300m",…},"requests":{"cpu":"150m",…}`. Dar kotada k6 özetinde
`p99=` yüksek (ölçülen: ~800 ms) ve CPU pod başına ~%5'te (50m) takılı (yazdırılan değer bütün redirect pod'larının
toplamı; HPA tabanı 2. pod'u geri getirirse ~%10). Kotasızda CPU belirgin artar, `p99=` düşer: aradaki fark kotanın
bedeli (script 1.5 kat farkta REPRODUCED der). Bu kurulum kısılma süresini (`container_cpu_cfs_throttled_*`)
yayınlamadığı için kanıt bu dolaylı p99 farkıdır.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — iki faz (dar kota, kotasız), her biri 60 sn; pod her fazda yeniden başlar
- "CPU: sınırın yüzde kaçı" → dar kotada `redirect-…` pod'u **%100'e yapışır** ve düz gider: kısılmanın görünen yüzü. Kotasız fazda (yeni pod adıyla) çizgi yere iner.
- "CPU kullanımı (bir çekirdeğin %'si)" → dar kotada %5'te düz bir tavan; kotasız fazda belirgin yükselir.
- "p99 süre (uç noktaya göre)" → `/{code}` dar kotada yüksek, kotasızda düşük.

**Nasıl çözülüyor:** Bu seviyenin dersi: bellek limiti şarttır (bellek taşarsa pod öldürülür), CPU limiti ise çoğu zaman zarar verir. CPU isteği (`requests`) yerleştirmeyi ve adil paylaşımı zaten sağlar.

---

### P07-05 · Node kapasitesi bitince Pending

**Ne oluyor:** Ölçekleyici 10 pod ister, Deployment "10 pod" der ve her şey yolunda görünür; ama pod'ların bir
kısmı hiç çalışmaz, `Pending` durumunda bekler. İsteği veren taraf bunu bilmez.
**Neden oluyor:** Ölçekleyici yalnızca pod **sayısını** ister; pod'u bir düğüme yerleştirmek zamanlayıcının
(scheduler) işidir. Düğümlerde istenen CPU kadar yer kalmadıysa pod bekler. kind'da yeni düğüm ekleyen bir küme
ölçekleyicisi (cluster autoscaler) yok.
**Bu deney:** Pod başına CPU isteğini bir düğümün %60'ına çıkarır, en az pod sayısını 10'a çeker; kaç pod'un
`Pending` kaldığını ve zamanlayıcının neden yerleştiremediğini (`Insufficient cpu`) gösterir, sonra geri alır.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P07-05` (pod başına CPU isteğini bir düğümün %60'ına
çıkarır, HPA tabanını geçici olarak 10'a çeker — yoksa HPA ölçeği geri çeker ve ölçüm kapasiteyi değil HPA'yı
ölçer —, Pending sayısını ve scheduler'ın mesajını basar, sonra geri alır). Elle — kümenin CPU rezervini doldurur;
4. adımı atlama:

1. Temiz başla; düğümlerin ayrılabilir CPU'suna bak, pod başına isteği bir düğümün %60'ı olarak hesapla (iki pod aynı
   düğüme sığmasın):
```bash
cd "$LADDER/07-services-autoscaling"
make fresh
kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.allocatable.cpu,BELLEK:.status.allocatable.memory
milli=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' | awk '/m$/{sub(/m$/,""); print; next}{print $1*1000}'); req=$(( milli * 60 / 100 )); echo "pod başına istek: ${req}m"
```
2. İsteği büyüt, HPA'nın tabanını 10'a çek ve 10 replika iste:
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=${req}m --limits=cpu=$(( req + 500 ))m
kubectl -n lvl07 patch hpa redirect --type=merge -p '{"spec":{"minReplicas":10,"maxReplicas":12}}'
kubectl -n lvl07 scale deploy/redirect --replicas=10
```
3. 45 sn bekle; istenen ile yerleşeni karşılaştır, scheduler'ın gerekçesini oku:
```bash
cd "$LADDER/07-services-autoscaling"
sleep 45
kubectl -n lvl07 get deploy redirect
kubectl -n lvl07 get hpa redirect
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect --field-selector status.phase=Pending
kubectl -n lvl07 get events --field-selector reason=FailedScheduling | tail -3
```
4. Geri al — önce HPA'nın tabanı, sonra kaynaklar, sonra replika:
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 patch hpa redirect --type=merge -p '{"spec":{"minReplicas":2,"maxReplicas":12}}'
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=150m --limits=cpu=300m
kubectl -n lvl07 scale deploy/redirect --replicas=2
kubectl -n lvl07 rollout status deploy/redirect
```

**Terminalde ne görmelisin:** her düğüm ~6 CPU ayrılabilir gösterir, istek `3600m` çıkar. 3. adımda HPA `MINPODS 10`,
`REPLICAS 10` der — istediğini aldığını sanıyor — ama Deployment'ın `READY`'si 10'un gerisinde, Pending listesi dolu.
Olay satırında `… Insufficient cpu`. Bu pod'lar sen geri alana kadar Pending kalır.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) — başlattıktan ~1 dk sonra aç
- "Yer bekleyen pod" → 0'dan birkaç pod'a sıçrar ve geri alınana kadar orada kalır.
- "Düğüm CPU: ayrılabilir / istenen" → `pod'ların istediği` çizgisi `ayrılabilir`'a dayanır: yeni pod'lar hiçbir düğüme sığmıyor (küme geneli, seviye seçicisine bakmaz).
- "Otomatik ölçekleyici: istenen / mevcut pod" → `istenen` ve `mevcut` ikisi de 10: Pending pod'lar da sayılır, ölçekleyici "10 pod var" sanır; farkı yalnızca "Yer bekleyen pod" gösterir.

**Nasıl çözülüyor:** Bulutta küme ölçekleyici (cluster autoscaler) yeni düğüm ekler — ama bu dakikalar sürer. Kapasite, ölçekleme zincirinin en yavaş halkasına göre planlanır.

---

### P07-06 · TRAP · N+1: maliyet sonuç kümesiyle orantılı

**Ne oluyor:** 100 linki listeleyen tek bir istek veritabanına 101 sorgu gönderir. Az veriyle fark edilmez; sayfa
boyutu büyüdükçe süre ve veritabanı yükü de büyür.
**Neden oluyor:** Bu seviyenin tuzağı (`TRAP_LIST_N_PLUS_ONE`) açıkken liste bir sorguyla gelir, sonra her linkin
istatistiği ayrı bir sorguyla okunur (N+1: döngü içinde sorgu). Maliyet, sonuçtaki satır sayısıyla orantılıdır.
**Bu deney:** Bir kiracı için 100 link oluşturur; tuzak kapalı ve açıkken liste süresini ve api pod'larının yaptığı
sorgu sayısını karşılaştırır, sonra tuzağı kapatır.

**Reproduce (adım adım):** Otomatik: `make repro P=P07-06` (bir kiracı için 100 link oluşturur, tuzak kapalı/açık liste
süresini ve api pod'larının sorgu sayısını karşılaştırır, sonra tuzağı kapatır). Elle:

1. Temiz başla; `nplusone` kiracısı için 100 link oluştur, listeyi iki kez ısıt (ilk istek havuzu açar):
```bash
cd "$LADDER/07-services-autoscaling"
make fresh
for i in $(seq 1 100); do curl -s -o /dev/null -XPOST http://lvl07.localtest.me/api/links -H 'Content-Type: application/json' -H 'X-Tenant-ID: nplusone' -d "{\"url\":\"https://example.com/n/$i\"}"; done
curl -s -o /dev/null -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
curl -s -o /dev/null -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
```
2. Varsayılan hâl: `list`/`stats` sorgu sayaçlarını oku, listeyi bir kez iste, Prometheus kazısın diye 40 sn bekle,
   tekrar oku:
```bash
cd "$LADDER/07-services-autoscaling"
sleep 40
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (db_queries_total{namespace="lvl07",pod=~"api-.*",op=~"list|stats"})' | jq -r '.data.result[] | "\(.metric.op): \(.value[1])"'
curl -s -o /dev/null -w 'liste süresi: %{time_total}s\n' -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
sleep 40
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (db_queries_total{namespace="lvl07",pod=~"api-.*",op=~"list|stats"})' | jq -r '.data.result[] | "\(.metric.op): \(.value[1])"'
```
3. Tuzağı yalnızca api'de aç (pod'lar yeniden başlar, sayaçlar sıfırlanır), ısıt, aynı ölçümü yap:
```bash
cd "$LADDER/07-services-autoscaling"
make set E="TRAP_LIST_N_PLUS_ONE=true" W=api
sleep 10
curl -s -o /dev/null -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
curl -s -o /dev/null -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
sleep 40
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (db_queries_total{namespace="lvl07",pod=~"api-.*",op=~"list|stats"})' | jq -r '.data.result[] | "\(.metric.op): \(.value[1])"'
curl -s -o /dev/null -w 'liste süresi: %{time_total}s\n' -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
sleep 40
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (db_queries_total{namespace="lvl07",pod=~"api-.*",op=~"list|stats"})' | jq -r '.data.result[] | "\(.metric.op): \(.value[1])"'
```
4. Tuzağı kapat:
```bash
cd "$LADDER/07-services-autoscaling"
make reset
```

**Terminalde ne görmelisin:** varsayılan hâlde iki okuma arasında `list` 1 artar, `stats` değişmez: 100 link tek
sorguyla geldi. Tuzak açıkken tek liste isteği `stats`'ı ~100 artırır (ısıtma istekleri ilk okumada ~200 olarak
görünür) — maliyet sonuç kümesiyle orantılı. `liste süresi` de genelde yükselir ama oynaktır; asıl ölçü sorgu sayısı.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — başlatınca aç
- "Veritabanı sorguları (türe göre)" → 100 oluşturma `create` serisinde; varsayılan fazda liste yalnızca `list`'te küçük bir kıpırtı, tuzakta aynı istek `stats`'ta ayrı bir tepe (~100 sorgu). Tepeler alçak ve kısa; kesin sayı terminalde.
- "p99 süre (uç noktaya göre)" → `/api/links` tuzak fazında daha yüksek.

**Nasıl çözülüyor:** Bu seviyenin kendi ayarı: tuzak kapalıyken (varsayılan) bütün istatistikler tek toplu sorguyla (`WHERE code = ANY($1)`) gelir. 14'te aynı ilke servisler arası çağrılara uygulanır: 101 fonksiyon çağrısı 101 ağ çağrısına dönmesin diye toplu çağrı.

---

### P07-07 · Node donunca yedeklilik işe yaramıyor

**Ne oluyor:** Bir sunucu (worker düğüm) donduğunda, pod'lar birden fazla düğüme dağılmış olsa bile isteklerin bir
kısmı takılır ve bu dakikalarca sürer. Birden çok kopya (yedeklilik) tam da bu anda işe yaramaz.
**Neden oluyor:** Donmuş düğümdeki pod'lar trafik listesinde (Endpoints) kalır: düğüm cevap vermiyor ama Kubernetes
pod'u hâlâ hazır sanıyor. Düğümün "hazır değil" sayılması 40 sn, pod'ların taşınması 5 dk sürer; bu sürede trafiğin
bir kısmı ölü pod'a gider.
**Bu deney:** Normal istek hızını ölçer, bir redirect pod'unun düğümünü `docker pause` ile dondurur; düğümün
NotReady olma süresini, tamamlanan istek hızını ve 5xx'i ölçer, sonra düğümü çözer.

**Reproduce (adım adım):** Otomatik: `FREEZE_NODE=1 CONFIRM=1 make repro P=P07-07` (taban hızı ölçer, bir redirect
pod'unun düğümünü `docker pause` ile dondurur, NotReady süresini, tamamlanan istek hızını ve 5xx'i ölçer, sonra
düğümü çözüp Ready'yi bekler). `FREEZE_NODE=1` olmadan yalnızca replikaların düğüm dağılımını basar: donma sonrası
containerd bozuk kalıp düğümü uzun süre NotReady bırakabildiği için deney varsayılan olarak atlanır. Elle —
**yıkıcı:** 3. adım bir düğümü dondurur; 4. adım (çözme) ne olursa olsun çalıştırılmalı:

1. Temiz başla; replikaların düğümlerine bak, hazır bir redirect pod'unun düğümünü seç:
```bash
cd "$LADDER/07-services-autoscaling"
make fresh
kubectl -n lvl07 rollout status deploy/redirect
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect -o wide
victim=$(kubectl -n lvl07 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].nodeName}' | awk '{print $1}'); echo "dondurulacak düğüm: $victim"
```
2. Taban: donma öncesi 30 sn'de kaç istek tamamlanıyor:
```bash
cd "$LADDER/07-services-autoscaling"
make load S=redirect K6_ARGS="--vus 10 --duration 30s"
```
3. İkinci bir terminalde 120 sn'lik yükü başlat:
```bash
cd "$LADDER/07-services-autoscaling"
make load S=redirect K6_ARGS="--vus 10 --duration 120s"
```
   ~12 sn sonra ilk terminalde düğümü dondur, NotReady olmasını izle, pod'ların API'deki hâline bak, 20 sn daha bekle:
```bash
cd "$LADDER/07-services-autoscaling"
docker pause "$victim"
for i in $(seq 1 20); do st=$(kubectl get node "$victim" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); echo "$((i*5)) sn: Ready=$st"; [ "$st" = True ] || break; sleep 5; done
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect -o wide
sleep 20
```
4. Düğümü çöz (atlama): containerd'yi yeniden başlat ve düğüm `Ready` olana kadar bekle; `kubectl wait` zaman aşımına
   düşerse aynı komutu tekrarla, düğüm Ready olmadan devam etme:
```bash
cd "$LADDER/07-services-autoscaling"
docker unpause "$victim"
docker exec "$victim" systemctl restart containerd
kubectl wait --for=condition=Ready node/"$victim" --timeout=150s
kubectl get nodes
kubectl -n lvl07 get pods -o wide
```

**Terminalde ne görmelisin:** tabanda `k6 lvl07: reqs=…` (30'a böl: saniyedeki istek). Dondurmadan ~40 sn sonra
`Ready=Unknown`; ama `get pods` donmuş düğümdeki `redirect-…` pod'unu hâlâ `Running 1/1` gösterir — Endpoints'ten
düşmüyor. 120 sn'lik yükün `reqs`'i tabanın 4 katına yaklaşmaz: istekler ölü pod'da asılı kalıyor. `5xx` az ya da
sıfır — arızanın işareti hata kodu değil, işin bitmemesi (60 sn'yi aşan istek k6'da `request timeout` ve `5xx` olur).
4. adımın sonunda bütün düğümler `Ready`.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-30m&to=now&refresh=10s), [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-30m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-30m&to=now&refresh=10s) — yalnızca düğüm gerçekten dondurulduysa dolar
- "Düğüm başına pod" → donmuş düğümün çizgisi **düşmez**: Kubernetes pod'ları hâlâ yerinde sanıyor.
- "Dönen durum kodları" → donmadan itibaren `302` belirgin düşer; zaman aşımına uğrayan istekler `502`/`504` olarak belirir.
- "İstek / saniye (pod'a göre)" → donmuş düğümdeki `redirect-…` çizgisi kesilir, diğerleri sürer; zaman aşımını ingress ürettiği için uygulamanın 5xx paneli 0 kalabilir.

**Nasıl çözülüyor:** 10'da devre kesici ve aktif sağlık kontrolü gelir: istemci, Kubernetes'in fark etmesini beklemeden cevap vermeyen hedefi kendisi devreden çıkarır.

---

### P07-08 · TRAP · Her zaman hazır diyen probe

**Ne oluyor:** Bu seviyenin tuzağı (`TRAP_READY_ALWAYS`) açıkken pod'lar her zaman "hazırım" der; yeni sürüm
dağıtılırken henüz hazır olmayan pod'lar trafik alabilir ve hata sayısı artabilir.
**Neden oluyor:** Hazır olma kontrolünün (readiness probe) değeri "hayır" diyebilmesindedir. Sabit "evet" (200)
cevabı, Kubernetes'in pod'un gerçekten hazır olup olmadığını öğrenmesinin tek yolunu siler.
**Bu deney:** Aynı dağıtımı yük altında önce dürüst, sonra her zaman "evet" diyen readiness ile koşar; 5xx sayısını ve
hazır sayılan pod'ların tepesini karşılaştırır. Kubernetes kapanan pod'u zaten trafikten çıkardığı için fark
çıkmayabilir; script o zaman nedenini yazar.

**Reproduce (adım adım):** Otomatik: `make repro P=P07-08` (preStop beklemesini 0 yapar — yoksa 5 sn'lik preStop
trafiği emer ve iki modda da 5xx=0 çıkar —, aynı rollout'u yük altında varsayılan ve tuzaklı readiness ile koşar,
5xx'i ve hazır endpoint tepesini karşılaştırır, sonra geri alır). Elle:

1. Temiz başla; preStop beklemesini 0 yap (yalnızca readiness'ın etkisi ölçülsün):
```bash
cd "$LADDER/07-services-autoscaling"
make fresh
kubectl -n lvl07 patch deploy/redirect --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":0}]'
kubectl -n lvl07 rollout status deploy/redirect
```
2. Varsayılan readiness ile rollout: ikinci bir terminalde yükü başlat:
```bash
cd "$LADDER/07-services-autoscaling"
make load S=redirect K6_ARGS="--vus 10 --duration 60s"
```
   ~12 sn sonra ilk terminalde rollout'u başlat ve bitene kadar her 2 sn'de endpoint'lerin `ready` durumunu bas:
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 rollout restart deploy/redirect
for i in $(seq 1 30); do kubectl -n lvl07 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{" "}{end}{end}'; echo; kubectl -n lvl07 rollout status deploy/redirect --timeout=3s >/dev/null 2>&1 && break; sleep 2; done
```
3. Tuzağı yalnızca redirect'te aç (pod'lar yeniden başlar), sonra 2. adımı aynen tekrarla — ikinci terminalde aynı
   yük, ~12 sn sonra ilk terminalde aynı rollout döngüsü:
```bash
cd "$LADDER/07-services-autoscaling"
make set E="TRAP_READY_ALWAYS=true" W=redirect
sleep 10
```
```bash
cd "$LADDER/07-services-autoscaling"
make load S=redirect K6_ARGS="--vus 10 --duration 60s"
```
```bash
cd "$LADDER/07-services-autoscaling"
kubectl -n lvl07 rollout restart deploy/redirect
for i in $(seq 1 30); do kubectl -n lvl07 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{" "}{end}{end}'; echo; kubectl -n lvl07 rollout status deploy/redirect --timeout=3s >/dev/null 2>&1 && break; sleep 2; done
```
4. Geri al: tuzağı kapat, preStop'u 5 sn'ye döndür:
```bash
cd "$LADDER/07-services-autoscaling"
make reset
kubectl -n lvl07 patch deploy/redirect --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":5}]'
kubectl -n lvl07 rollout status deploy/redirect
```

**Terminalde ne görmelisin:** döngünün her satırı endpoint'lerin `ready` bayrakları (`true true false …`). İki fazda
`true` sayısının tepesini ve k6 özetindeki `5xx=` değerini karşılaştır: tuzakta yeni pod'lar süreç açılır açılmaz
`true` sayılır. Fark çıkmayabilir — Kubernetes sonlanan pod'u readiness'tan bağımsız olarak Endpoints'ten düşürür;
o zaman script NOT-REPRODUCED der ve nedenini yazar (probe'un değeri P01-07 ve P10-02'de ölçülüyor).

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-15m&to=now&refresh=10s) — iki rollout (varsayılan, tuzaklı)
- "Hazır pod adresi (endpoint) sayısı" → her rollout'ta `redirect` çizgisi kısa bir tepe/çukur çizer; iki rollout'un şeklini yan yana karşılaştır.
- "Dönen durum kodları" → rollout anlarında `502`/`503` kıvılcımları (ingress'ten gelir); tuzaklı rollout'takileri varsayılanla karşılaştır.

**Nasıl çözülüyor:** Bu seviyenin kendi ayarı: tuzak kapalıyken probe gerçek durumu söyler. Probe'un neyi sorduğu açıkça tanımlanmalı: yalnızca bağlantı kontrolü (TCP), canlılık ucunu (`/healthz`) hazır olma için kullanmak ya da hazır olmaya dış bağımlılık koymak (P02-10) aynı kökten hatalardır.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_LIST_N_PLUS_ONE` | Liste yanıtında link başına stats sorgusu | `make repro P=P07-06` | Bayrağı kapat; toplu sorgu |
| `TRAP_READY_ALWAYS` | readiness sabit 200 | `make repro P=P07-08` | Bayrağı kapat |
| `TRAP_COMMIT_BEFORE_WRITE` · `TRAP_NO_DLQ` · `TRAP_COMMIT_DELAY_MS` | (06'dan devam) | 06'da | — |

Elle denemeye değer:
- `kubectl -n lvl07 patch hpa redirect --type=json -p '[{"op":"replace","path":"/spec/behavior/scaleUp/stabilizationWindowSeconds","value":60}]'`
  sonra P07-01'i tekrar koş: ölçek büyütmeyi yavaşlatmanın bedeli.
- `rpk topic add-partitions clicks -n 6` sonra `make load S=hot-key`: tek partition tavanı (P06-03) kalkınca KEDA
  tüketiciyi gerçekten ölçekler.
- api-svc'ye HPA ekle, `make load S=create` koş: yazma yolunu ölçeklemek DB'yi farklı etkiler (yazma replikaya dağılmaz).
- `DB_MAX_CONNS=2` yap, `stairs` koş: havuzu küçültmek P07-02'yi çözmez, kuyruğu uygulamaya taşır (P02-06).

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now) | **Dolu** ✨ | HPA istenen/mevcut, Pending pod, düğüm kapasitesi, KEDA |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now) | Dolu — **servis bazında** | `redirect` ve `api` ayrı pod'lar; `pod` kırılımıyla oku, ortalama iki yük şeklini gizler |
| [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl07&from=now-15m&to=now) · [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl07&from=now-15m&to=now) · [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl07&from=now-15m&to=now) | Dolu | — |
| [`01 · Pods`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now) → "CPU: sınırın yüzde kaçı" | Dolu — yalnızca CPU sınırı olan pod'lar | Kısılma süresi bu kurulumda yayınlanmıyor; kısılmayı kullanımın sınıra oranından oku (P07-04) |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl07&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl07&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl07&from=now-15m&to=now) | Boş | — |

## 9. Bilerek bırakılanlar

- Postgres tek ve havuz aritmetiği sınırda (P07-02 → 09).
- Redis tek (P04-01 → 14).
- Tek partition: KEDA 6 replikaya çıkabilir ama tavan 1 partition (P06-03).
- api-svc'de HPA yok: trafiği öngörülebilir varsayılıyor.
- Servisler arası çağrı yok (N+1 tuzağı hariç) → 14'te gRPC.
- Hız sınırı hâlâ süreç içi ve artık iki serviste ayrı (P02-04 → 08).
- Kaynak istekleri tahmini; VPA kurulu değil.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 06 ile farkı gösterir:

1. `cmd/linkly/` yerine `cmd/redirect-svc/` ve `cmd/api-svc/`: ortak kod `internal/`'da, fark yalnızca hangi
   handler'ın bağlandığı ve hangi ayarlar.
2. `internal/httpapi/split.go`: `RedirectHandler` ve `APIHandler` — ayrım bir yönlendirme tablosu, iş mantığı bölünmedi.
3. `deploy/redirect-svc.yaml` ile `deploy/api-svc.yaml`: aynı kod, zıt ayarlar (`DB_MAX_CONNS` 6 / 15, HPA 2–12 / sabit
   2, CPU limiti var / yok).
4. `deploy/keda.yaml`: tüketici CPU'ya değil lag'e göre ölçeklenir — kullanıcıya görünen sorunu kodlayan metrik.
5. `deploy/ingress.yaml`: yol tabanlı yönlendirme; dışarıdan hiçbir şey değişmedi.
