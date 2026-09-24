# 07 — services-autoscaling · "Servisleri ayır, otomatik ölçekle"

> **Bu seviyede ne yaşayacaksın?**
> - Tek uygulamanın üçe ayrılması ve her birinin kendi ölçekleme sinyali: redirect CPU'ya göre (HPA), tüketici lag'e göre (KEDA)
> - HPA'nın yükten sonra geç tepki vermesi (P07-01); ölçeklemenin darboğazı yok etmeyip DB'ye taşıması (P07-02)
> - Yeni pod'un "hazır" ama önbelleği soğuk olması (P07-03); CPU limitinin bir kota olarak gecikme üretmesi (P07-04); düğüm kapasitesi bitince Pending (P07-05)
> - Tuzaklar: N+1 sorgu (P07-06), her zaman "hazır" diyen probe (P07-08); bir düğüm donunca yedekliliğin işe yaramaması (P07-07)
>
> **Bu seviye olmasa ne olur?** Okuma, yazma ve tüketim tek bir replika sayısını paylaşır — biri yük alınca hepsi birlikte ölçeklenir ya da hiçbiri.
>
> **Yeni gelen teknolojiler:** HPA, KEDA, metrics-server, üç ayrı Deployment (redirect-svc, api-svc, analytics-consumer), `09 · Autoscaling` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Tek uygulama üçe ayrıldı: **redirect-svc** (trafiğin ~%99'u, salt okuma), **api-svc** (yazma ve
yönetim) ve **analytics-consumer** (06'dan). Her birinin kendi replika sayısı, kendi bağlantı
havuzu, kendi kaynak limitleri ve kendi ölçekleme sinyali var: redirect CPU'ya göre (HPA),
tüketici **lag**'e göre (KEDA). Bu bir "mikroservis" tercihi değil — **her yük şekline kendi
düğmesini vermek**.

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

Dışarıdan **hiçbir şey değişmedi**: aynı host, aynı URL uzayı, aynı sözleşme. *Servis sınırı
içeriye ait bir karardır; client'ları değiştirmeye zorluyorsa sınır yanlış yere çizilmiştir.*

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P06-02 | Tüketici gecikmesi (lag) elle yönetiliyordu | KEDA `ScaledObject`: tüketici **lag**'e göre 1→6 ölçekleniyor. CPU değil lag, çünkü CPU bir tüketici için yanlış sinyaldir — bir milyon olay beklerken boşta olabilir |

Bir madde daha var ama **listeye yazmıyorum** ve sebebi öğretici: P05-03'ü (yazıcının okumayla
aynı süreci paylaşması) 06 zaten çözmüştü. 07 onu **derinleştiriyor**: artık okuma ve yazma
YOLLARI da birbirinden ayrıldı. Çözülmüş bir sorunu tekrar sahiplenmek, merdivenin hesabını bozar.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl07.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl07.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl07 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P07-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

Ölçeklemeyi izlemek için:
```bash
kubectl -n lvl07 get hpa,scaledobject -w
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect -w
```

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Önceki seviye açıksa kapat (aynı anda tek seviye çalışır), bu seviyeyi kur. `make up` Grafana'yı da temizler:
```bash
make -C ../06-event-stream down
make up
```
2. 06'nın sorunlarını bu seviyede koş (06'nın yedi scripti sırayla; uzun sürer). Koşarken başka komut çalıştırma:
   aynı pod'lara dokunurlar. Çıktıdaki `BEKLENEN` sütunu `NOT-REPRODUCED` diyorsa 07 o sorunu çözmüş olmalı
   (burada P06-02: KEDA tüketiciyi lag'e göre ölçekliyor). `CONFIRM=1` isteyen P06-01, P06-05, P06-06 `SKIPPED` görünür:
```bash
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P07-01 → P07-08). Her sorunda aynı düzen:
   **Elle** bloklarını sırayla yapıştır (ilk komut `make fresh`: Grafana bu deneye boş başlar) →
   **Terminalde ne görmelisin** ile karşılaştır → **Grafana'da gör** linklerini aç, her madde hangi panelde neyi
   göreceğini söyler. İstersen aynı deneyi `make repro P=…` ile otomatik koş: ölçer ve hükmünü basar.
   P07-05 kümeyi kasıtlı olarak doldurur, P07-07 bir düğümü dondurur: ikisinde de son adım (geri alma) atlanmaz.
4. Bitince açık kalan ayarları geri al ve seviyeyi kapat:
```bash
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). **Dışarıdan hiçbir fark yok** — ingress yol
tabanlı yönlendirme yapıyor (`/api` → api-svc, geri kalan → redirect-svc).

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P07-01 | HPA gecikir: burst'te pod yok | `make repro P=P07-01` | [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "İstek / sn ve pod sayısı" | seviye içi (tampon) |
| P07-02 | Ölçekleme darboğazı DB'ye taşır | `make repro P=P07-02` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "Otomatik ölçekleyici: istenen / mevcut pod" | 09 |
| P07-03 | Yeni pod hazır ama soğuk | `make repro P=P07-03` | [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "p99 süre (pod'a göre; yeni pod soğuk)" | seviye içi |
| P07-04 | CPU limiti = kota → throttling | `make repro P=P07-04` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "CPU kısıtlama (throttling)" | seviye içi |
| P07-05 | Node kapasitesi bitti → Pending | `CONFIRM=1 make repro P=P07-05` | [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "Yer bekleyen pod" | (bulut: autoscaler) |
| P07-06 | **TRAP** N+1: maliyet sonuç kümesiyle orantılı | `make repro P=P07-06` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "Veritabanı sorguları (türe göre)" | seviye içi · 14 |
| P07-07 | Node donunca yedeklilik işe yaramıyor | `CONFIRM=1 make repro P=P07-07` | [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-30m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-30m&to=now&refresh=10s) → "Düğüm başına pod" | 10 |
| P07-08 | **TRAP** her zaman hazır diyen probe | `make repro P=P07-08` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "Hazır pod adresi (endpoint) sayısı" | seviye içi |

---

### P07-01 · HPA gecikir

**Belirti:** 5 rps'ten 400 rps'e 5 saniyede çıkan bir burst'te p99 fırlar; pod'lar yük **bittikten
sonra** gelir.
**Neden:** Ölçekleme reaktiftir ve zincir uzundur: metrics-server'ın CPU örneklemesi (15 sn) → HPA
döngüsü (15 sn) → schedule → imaj → süreç başlangıcı → readiness. [Topic · Konu: Reaktif ölçekleme, kapasite]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P07-01` (`burst` senaryosunu koşar: 5 → 400 rps, tepe 20 sn;
tepe p99 ile HPA'nın istediği ve gerçekten hazır olan replika sayısını karşılaştırır). Tepe varsayılan olarak
400: bu kümede redirect ~650 istek/s kaldırıyor; 1000'lik bir tepe gecikmeyi değil yıkımı ölçer
(probe'lar düşer, pod'lar yeniden başlar). Daha sert burst için: `PEAK=1000 make repro P=P07-01`.

Elle — `07-services-autoscaling` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, HPA'nın ve redirect pod'larının başlangıç durumuna bak:
```bash
make fresh
kubectl -n lvl07 get hpa redirect
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect
```
2. İKİNCİ bir terminalde `07-services-autoscaling` klasöründe HPA'yı canlı izle (deney bitince Ctrl+C):
```bash
kubectl -n lvl07 get hpa redirect -w
```
3. İLK terminalde ani yükü ver (~70 sn: 20 sn sessizlik, 5 sn'de 400 rps'e tırmanış, 20 sn tepe, iniş),
   bitince pod'lara tekrar bak:
```bash
make load S=burst
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect
```
4. İstersen daha sert bir tepeyle tekrarla. Kapasitenin üstüdür: probe'lar düşebilir, pod'lar yeniden başlayabilir;
   sonraki soruna geçmeden önce `kubectl -n lvl07 get pods` ile hepsinin hazır olduğunu gör:
```bash
PEAK=1000 make load S=burst
kubectl -n lvl07 get pods
```

**Terminalde ne görmelisin:** başta `kubectl get hpa` satırında `MINPODS 2 · MAXPODS 12 · REPLICAS 2` ve hedef
`…%/60%`. Yük sürerken ikinci terminalde `TARGETS` yüzdesi 60'ı aşar, ama `REPLICAS` ancak tepenin
ortasında ya da sonunda 2'nin üstüne çıkar. k6 çıktısının sonundaki özet satırında (`k6 lvl07: reqs=… 5xx=… p99=…`) p99 yüksektir;
pod listesindeki yeni `redirect-…` pod'larının `AGE`'i yükün sonuna denk gelir: pod'lar yük geçtikten sonra geldi.
(Hız sınırı pod ve IP başına 200 rps: iki pod'la 400 rps'lik tepe sınıra dayanır, özette `429` görebilirsin — HPA'yla
ilgisi yok.) Yük bitince HPA 120 sn'lik küçültme penceresinden sonra replikaları kademeli olarak 2'ye indirir;
geri alınacak bir şey yok.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — `burst` ~70 sn sürer; bittikten sonra 1–2 dk daha izle, pod'lar geç gelir (giriş: admin / ladder)
- "İstek / sn ve pod sayısı" → `istek / sn` yarım dakikalık dik bir tepe çizer; `pod sayısı` çizgisi tepe **geçtikten sonra** basamaklanır. `pod sayısı` namespace'teki bütün pod'ları sayar (postgres, redis, redpanda, api, tüketici dahil), yani tabanı 2 değildir — basamağın **ne zaman** geldiğine bak.
- "Otomatik ölçekleyici: istenen / mevcut pod" → `istenen: redirect` ancak burst'ün ortasında ya da sonunda 2'nin üstüne çıkar; `mevcut: redirect` onu gecikmeyle izler. İki çizgi ile rps tepesi arasındaki yatay mesafe, Neden'deki zincirin süresidir.
- "p99 süre (uç noktaya göre)" → `/{code}` burst anında sıçrar ve yeni pod'lar hazır olmadan, yük bittiği için düşer.

**Ders:** *Otomatik ölçekleme burst için değil, TREND için tasarlanmıştır.* Ani yük bir kapasite
sorunudur, bir otomasyon sorunu değil — `minReplicas`'ı tabanı karşılayacak kadar yüksek tutmak
"israf" değil, burst sigortasıdır.

---

### P07-02 · Ölçekleme darboğazı taşır, yok etmez

**Belirti:** HPA redirect'i 12 replikaya çıkarır; uygulama CPU'su rahatlar, **Postgres bağlantıları
tavana dayanır** ve havuz bekleme süresi büyür.
**Neden:** Her yeni pod kendi havuzunu açar. `12 × 6 + 2 × 15 + 10 = 112 > max_connections=100`.
[Topic · Konu: Paylaşılan kaynak, ölçeklenemeyen katman]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P07-02` (aritmetiği basar, `stairs` yükünü ve yanında rastgele
kodlarla `scan` yükünü koşar, pod sayısı ile DB bağlantılarını, havuz beklemesini ve CPU'ları birlikte ölçer).

Elle — `07-services-autoscaling` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, aritmetiği topla: her servisin havuzu, HPA'nın tavanı, Postgres'in üst sınırı:
```bash
make fresh
make env | grep -E 'deploy/|DB_MAX_CONNS'
kubectl -n lvl07 get hpa redirect
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max(pg_settings_max_connections{namespace="lvl07"})' | jq -r '"max_connections: " + .data.result[0].value[1]'
```
2. İKİNCİ bir terminalde `07-services-autoscaling` klasöründe rastgele (var olmayan) kodlarla 150 sn yük başlat.
   Neden: `stairs` 200 tohum kodu döndürür ve önbellek 04'ten beri paylaşımlı — isabet ~%100 olur, yük DB'ye hiç
   ulaşmaz. Rastgele kod her istekte bir DB okuması üretir:
```bash
make load S=scan K6_ARGS="--vus 30 --duration 150s"
```
3. Hemen ardından İLK terminalde merdiven yükünü ver (50 → 100 → 200 → 400 rps, basamak başına 40 sn), HPA'ya bak:
```bash
make load S=stairs
kubectl -n lvl07 get hpa redirect
```
4. İki yük de bitince son 6 dakikanın tepelerini oku — redirect pod sayısı, Postgres bağlantısı, havuz beklemesi, DB hatası:
```bash
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(kube_deployment_status_replicas_available{namespace="lvl07",deployment="redirect"}[6m:15s])' | jq -r '"tepe redirect pod: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(pg_stat_activity_count{namespace="lvl07"})[6m:15s])' | jq -r '"tepe PG bağlantı: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace="lvl07"}[1m])) by (le))[6m:15s])' | jq -r '"havuz bekleme p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(db_queries_total{namespace="lvl07",result="error"}[6m]))' | jq -r '"DB hatası: " + .data.result[0].value[1]'
```

**Terminalde ne görmelisin:** 1. adımda havuzlar `DB_MAX_CONNS=10` (analytics), `15` (api), `6` (redirect); HPA
`MAXPODS 12`; `max_connections: 100`. Aritmetik: `12 × 6 + 2 × 15 + 10 = 112 > 100` — redirect tavana çıkarsa
bağlantılar yetmez. 3. adımda HPA `REPLICAS` merdivenle birlikte 2'nin üstüne çıkar. 4. adımda tepe PG bağlantısı
pod sayısıyla birlikte yükselmiştir ve `havuz bekleme p99` 0.05 sn'yi (50 ms) aşar ya da `DB hatası` sıfırdan
büyüktür — scriptin REPRODUCED eşiği bu: uygulama pod'ları DB'yi **bekliyor**.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s), [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) — `stairs` yükü ~3 dk sürer, başlatınca aç (giriş: admin / ladder)
- "Otomatik ölçekleyici: istenen / mevcut pod" → `redirect` replikası merdivenle birlikte basamak basamak artar (en fazla 12).
- "Bağlantılar ve üst sınır" → durum (`active`, `idle` …) çizgileri pod sayısıyla birlikte yükselir ve `üst sınır` (100) çizgisine yaklaşır: her yeni pod kendi havuzunu açıyor.
- "Uygulama havuzu: bağlantı bekleme (p99)" → pod sayısı arttıkça yükselir: pod'lar bağlantı **bekliyor**. Script bunun 50 ms'yi aşmasını (ya da DB hatasını) arıyor. (Bekleme pgx'in her bağlantı alımının etrafında ölçülür — `internal/store/postgres.go`, `acquireTracer`. Havuzun durumuna bakan bir çağrıyı süreleyen bir ölçü burada yapı gereği ~0 okurdu: bekleme alımın kendisinde.)
- "Veritabanı CPU" → merdivenle yükselir.
- "CPU kullanımı (bir çekirdeğin %'si)" (Pods) → aynı anda `redirect-…` pod'larının her biri düşük kalır: darboğaz uygulamada değil.

**Nerede çözülüyor:** 09 (PgBouncer: yüzlerce uygulama bağlantısı → onlarca DB bağlantısı; okuma
replikaları). *Otomatik ölçekleme darboğazı görünmez yapmaz, taşır — ve taşıdığı yer genelde
ölçeklenemeyen yerdir.*

---

### P07-03 · Yeni pod "hazır" ama soğuk

**Belirti:** Ölçekleme anında p99 yükselir; en genç pod'lar en yavaştır.
**Neden:** readiness "süreç ayakta ve dinliyor" der; "havuzum açık, önbelleğim ısındı" demez.
[Topic · Konu: Soğuk başlangıç, readiness semantiği]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P07-03` (ısınmış taban p99'u ölçer, yük altında redirect'i 6
replikaya çıkarır, pod bazında p99 dağılımını basar, sonra 2'ye döner).

Elle — `07-services-autoscaling` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, ısınmış durumda 40 sn yük ver (taban p99):
```bash
make fresh
make load S=redirect K6_ARGS="--vus 20 --duration 40s"
```
2. İKİNCİ bir terminalde `07-services-autoscaling` klasöründe 70 sn'lik ikinci yükü başlat:
```bash
make load S=redirect K6_ARGS="--vus 30 --duration 70s"
```
3. Yük başladıktan ~12 sn sonra İLK terminalde yük altındayken 4 yeni pod ekle:
```bash
kubectl -n lvl07 scale deploy/redirect --replicas=6
kubectl -n lvl07 rollout status deploy/redirect
```
4. İkinci yük bitince pod bazında p99'u ve pod'ların yaşını oku:
```bash
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=topk(6, histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl07",route="/{code}"}[2m])) by (le, pod)))' | jq -r '.data.result[] | "\(.metric.pod): \((.value[1]|tonumber*1000)|floor) ms"'
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect
```
5. Geri al:
```bash
kubectl -n lvl07 scale deploy/redirect --replicas=2
```

**Terminalde ne görmelisin:** iki yükün k6 özet satırındaki (`k6 lvl07: …`) `p99=` değerlerinden ikincisi (ölçekleme anını içeren)
birincisinden biraz yüksektir. 4. adımdaki listede `AGE`'i en küçük `redirect-…` pod'larının p99'u eskilerden
yüksek olma eğilimindedir — fark küçüktür: önbellek Redis'te paylaşımlı, yeni pod boş bellekle doğmuyor. Pod sayısı
6'da kalmayabilir: HPA, `kubectl scale`'in koyduğu sayıyı kendi döngüsünde yeniden hesaplar.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl07&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; ölçekleme ikinci yük fazının ~12. saniyesinde (giriş: admin / ladder)
- "p99 süre (pod'a göre; yeni pod soğuk)" → ölçekleme anında dört yeni `redirect-…` çizgisi belirir; ilk noktaları eski pod'lardan yüksektir, sonra onlara yakınsar. Fark küçüktür (aşağıya bak). Panel tüm rotaları ve `api-…` pod'larını da çizer; `redirect-…` çizgilerine bak.
- "İsabet oranı (pod'a göre)" → yeni `redirect-…` pod'larının oranı ilk noktadan itibaren eskilerle aynı seviyede: önbellek Redis'te (L2) ve zaten sıcak, yeni pod boş bellekle doğmuyor.

**Bu seviyede maliyeti KÜÇÜK** — çünkü önbellek paylaşımlı (04). Aynı deney 03'te çok daha sert
olurdu: her yeni pod boş bellekle doğuyordu. *Mimarinin bir seviyede verdiği karar, üç seviye
sonraki bir sorunun şiddetini belirliyor.*
**Araçlar:** `startupProbe`, havuzda `MinConns`, ingress'te slow-start.

---

### P07-04 · CPU limiti bir kota'dır

**Belirti:** CPU kullanımı %50 görünürken p99 fırlar. Limit kaldırıldığında CPU artar ve p99 düşer.
**Neden:** CPU limiti, 100 ms'lik dilimlerde kullanılabilir çekirdek-zamanını sınırlar. Kota dilim
ortasında biterse süreç **bekler**. [Topic · Konu: CFS kotası, throttling]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P07-04` (tek pod'u önce dar kotayla — `TIGHT`, varsayılan 50m —
sonra pratikte kotasız, 4 çekirdek, aynı yük altında koşar; p99 ile CPU'yu karşılaştırır, sonra kaynakları ve
replikayı geri alır). Daha dar kota: `TIGHT=30m make repro P=P07-04`.

Elle — `07-services-autoscaling` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, redirect'in şu anki kaynaklarına bak:
```bash
make fresh
kubectl -n lvl07 get deploy redirect -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
```
2. Tek pod'a in ve kotayı 50m'ye daralt (istek de daralır: istek sınırdan büyük olamaz), 120 kullanıcıyla 60 sn yük ver,
   sonra kullanılan CPU'yu oku:
```bash
kubectl -n lvl07 scale deploy/redirect --replicas=1
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=50m --limits=cpu=50m
kubectl -n lvl07 rollout status deploy/redirect
make load S=redirect K6_ARGS="--vus 120 --duration 60s"
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="lvl07",pod=~"redirect.*",image!="",image!~".*pause.*"}[1m])) * 100' | jq -r '"CPU yüzdesi (100 = bir çekirdek): " + .data.result[0].value[1]'
```
3. Kotayı pratikte kaldır (4 çekirdek: düğümün verebileceğinden büyük bir sınır, sınır yok demektir), aynı yükü ver:
```bash
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=100m --limits=cpu=4
kubectl -n lvl07 rollout status deploy/redirect
make load S=redirect K6_ARGS="--vus 120 --duration 60s"
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="lvl07",pod=~"redirect.*",image!="",image!~".*pause.*"}[1m])) * 100' | jq -r '"CPU yüzdesi (100 = bir çekirdek): " + .data.result[0].value[1]'
```
4. Geri al — istek ile sınır tek komutta döner (ayrı ayrı dönerse ara durumda istek sınırdan büyük olur ve API reddeder):
```bash
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=150m --limits=cpu=300m
kubectl -n lvl07 scale deploy/redirect --replicas=2
kubectl -n lvl07 rollout status deploy/redirect
```

**Terminalde ne görmelisin:** başta `"limits":{"cpu":"300m",…},"requests":{"cpu":"150m",…}`. Dar kota fazında k6
çıktısının sonundaki özet satırında (`k6 lvl07: …`) `p99=` yüksektir (ölçülen tur: ~800 ms) ve CPU pod başına ~%5'te (50m), yani kotada takılı kalır
(yazdırılan değer tüm redirect pod'larının toplamı: iki pod varsa ~%10). Kotasız fazda aynı yükte CPU belirgin biçimde artar, `p99=`
düşer: aradaki fark kotanın bedeli. Script p99 farkı 1.5 katı aşınca REPRODUCED der. `kubectl scale --replicas=1`'den sonra HPA'nın tabanı (`minReplicas: 2`) pod sayısını
yeniden 2'ye çekebilir; iki faz aynı koşulda koştuğu için karşılaştırma yine geçerlidir.

> **Ortam sınırı:** Bu kurulumdaki cAdvisor `container_cpu_cfs_throttled_*` metriğini **yayınlamıyor**
> (kind + Docker Desktop, cgroup v1). Throttling'i doğrudan okuyamıyoruz; bu yüzden script dolaylı
> kanıt kullanıyor: limitli/limitsiz p99 farkı. *Ölçemediğin şeyi, ölçebildiğin bir şeyle kuşatmak
> gözlemlenebilirliğin sık kullanılan bir tekniğidir* — ve bunu README'de yazmak, sessizce boş bir
> panele bakmaktan iyidir.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — iki faz var (dar kota, sonra kotasız), her biri 60 sn yük; tek `redirect` pod'u her fazda yeniden başlar (giriş: admin / ladder)
- "CPU kısıtlama (throttling)" → bu kurulumda büyük olasılıkla **boş** (yukarıdaki ortam sınırı). Doluysa: dar kota fazında `redirect-…` çizgisi yükselir, kotasız fazda 0'a yakın kalır.
- "CPU kullanımı (bir çekirdeğin %'si)" → dar kota fazında tek `redirect-…` pod'u kotasında (`TIGHT`, varsayılan 50m = bir çekirdeğin %5'i) **%5'te** düz bir tavana yapışır; kotasız fazda (yeni pod adıyla) belirgin biçimde yükselir.
- "p99 süre (uç noktaya göre)" → `/{code}` dar kota fazında yüksek, kotasız fazda düşük: aradaki fark kotanın bedeli — throttling'i göremediğimiz yerde onu kuşatan dolaylı kanıt bu.

**Kural:** Bellek limiti şarttır (OOM koruması). **CPU limiti çoğu zaman zarar verir**; `requests`
zaten planlamayı ve adil paylaşımı sağlar.

---

### P07-05 · Node kapasitesi bitince Pending

**Belirti:** 10 replika istenir, bir kısmı çalışır, gerisi Pending'de bekler. Replika sayısını
isteyen taraf (HPA ya da `kubectl scale`) bunu bilmez; Deployment "10 replika" der ve mutlu görünür.
**Neden:** Ölçekleyici replika **sayısı** ister; yerleştirmek scheduler'ın işi. kind'da cluster
autoscaler yok. [Topic · Konu: Ölçekleme zinciri, kapasite]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `CONFIRM=1 make repro P=P07-05` — pod başına CPU isteğini bir node'un %60'ına çıkarır,
HPA'nın tabanını (`minReplicas`) geçici olarak 10'a çeker ve Deployment'ı 10'a ölçekler: 10, bir yük
dalgasındaki gibi HPA'nın **kendi** isteği olur. (Taban yerinde kalmazsa CPU düşük olduğu için HPA
45 sn'lik bekleme içinde ölçeği geri çeker, Pending pod'lar silinir ve ölçüm kapasiteyi değil HPA'yı
ölçer; script 45 sn sonra istenen sayının hâlâ 10 olduğunu doğrular, değilse hüküm vermez.) Pending
sayısını ve scheduler'ın mesajını basar; temizlik HPA'nın eski tabanını geri koyar.

Elle — `07-services-autoscaling` klasöründe, sırayla yapıştır. Bu deney kümenin CPU rezervini kasıtlı olarak
doldurur; 4. adımı (geri alma) atlama:

1. Grafana'yı temizle, düğümlerin ayrılabilir CPU'suna bak ve pod başına isteği bir düğümün %60'ı olarak hesapla
   (iki pod aynı düğüme sığmasın):
```bash
make fresh
kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.allocatable.cpu,BELLEK:.status.allocatable.memory
milli=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' | awk '/m$/{sub(/m$/,""); print; next}{print $1*1000}'); req=$(( milli * 60 / 100 )); echo "pod başına istek: ${req}m"
```
2. İsteği büyüt (sınır da büyür: istek sınırdan büyük olamaz), HPA'nın tabanını 10'a çek ve 10 replika iste:
```bash
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=${req}m --limits=cpu=$(( req + 500 ))m
kubectl -n lvl07 patch hpa redirect --type=merge -p '{"spec":{"minReplicas":10,"maxReplicas":12}}'
kubectl -n lvl07 scale deploy/redirect --replicas=10
```
3. 45 sn bekle, istenen ile yerleşeni karşılaştır, scheduler'ın gerekçesini oku:
```bash
sleep 45
kubectl -n lvl07 get deploy redirect
kubectl -n lvl07 get hpa redirect
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect --field-selector status.phase=Pending
kubectl -n lvl07 get events --field-selector reason=FailedScheduling | tail -3
```
4. Geri al — önce HPA'nın tabanı, sonra kaynaklar, sonra replika:
```bash
kubectl -n lvl07 patch hpa redirect --type=merge -p '{"spec":{"minReplicas":2,"maxReplicas":12}}'
kubectl -n lvl07 set resources deploy/redirect --requests=cpu=150m --limits=cpu=300m
kubectl -n lvl07 scale deploy/redirect --replicas=2
kubectl -n lvl07 rollout status deploy/redirect
```

**Terminalde ne görmelisin:** her düğüm ~6 CPU "ayrılabilir" gösterir (gerçekte VM'in 6 çekirdeğini paylaşırlar,
ama scheduler'ın gördüğü sayı budur), yani istek `3600m` çıkar. 3. adımda `kubectl get hpa` `MINPODS 10`,
`REPLICAS 10` der — HPA istediğini aldığını sanıyor — ama Deployment'ın `READY` sütunu 10'un gerisinde kalır ve
Pending listesi boş değildir. Olay satırında scheduler'ın gerekçesi: `… Insufficient cpu`. Kümede cluster
autoscaler yok; bu pod'lar sen geri alana kadar Pending kalır.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) — scripti başlattıktan ~1 dk sonra aç (giriş: admin / ladder)
- "Yer bekleyen pod" → 0'dan birkaç pod'a sıçrar ve script temizlik yapana kadar orada kalır.
- "Düğüm CPU: ayrılabilir / istenen" → `pod'ların istediği` çizgisi `ayrılabilir`'a dayanır: yeni pod'ların isteği hiçbir node'a sığmıyor. (Bu panel küme genelidir, seviye seçicisine bakmaz.)
- "Otomatik ölçekleyici: istenen / mevcut pod" → `istenen: redirect` 10'a çıkar (HPA'nın tabanı 10) ve `mevcut: redirect` de 10 olur, çünkü Pending pod'lar da sayılır: ölçekleyicinin gördüğü sayı "10 pod var"dır. İki çizgi üst üste biner — HPA istediğini aldığını sanıyor; farkı yalnızca "Yer bekleyen pod" gösterir.

**Ders:** Ölçekleme zinciri `metrics-server(15s) → HPA(15s) → scheduler → NODE(dakikalar) → imaj → başlangıç`.
*Kapasite planlaması bu zincirin en yavaş halkasına göre yapılır.*

---

### P07-06 · TRAP · N+1: maliyet sonuç kümesiyle orantılı

**Belirti:** 100 link listeleyen bir istek 101 sorgu yapar; süre beş katına çıkar.
**Neden:** Döngü içinde sorgu. Küçük veride görünmez; sayfa boyutunu büyüttüğün gün patlar.
[Topic · Konu: N+1, batch]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P07-06` (bir kiracı için 100 link oluşturur, tuzak kapalı/açık
liste süresini ve api pod'larının DB sorgu sayısını karşılaştırır, sonra tuzağı kapatır).

Elle — `07-services-autoscaling` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, `nplusone` kiracısı için 100 link oluştur, listeyi iki kez ısıt (ilk istek havuzu açar,
   ölçüme girmemeli):
```bash
make fresh
for i in $(seq 1 100); do curl -s -o /dev/null -XPOST http://lvl07.localtest.me/api/links -H 'Content-Type: application/json' -H 'X-Tenant-ID: nplusone' -d "{\"url\":\"https://example.com/n/$i\"}"; done
curl -s -o /dev/null -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
curl -s -o /dev/null -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
```
2. Varsayılan hâl: api pod'larının `list`/`stats` sorgu sayaçlarını oku, listeyi bir kez iste, Prometheus kazısın
   diye 40 sn bekle, tekrar oku:
```bash
sleep 40
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (db_queries_total{namespace="lvl07",pod=~"api-.*",op=~"list|stats"})' | jq -r '.data.result[] | "\(.metric.op): \(.value[1])"'
curl -s -o /dev/null -w 'liste süresi: %{time_total}s\n' -H 'X-Tenant-ID: nplusone' http://lvl07.localtest.me/api/links
sleep 40
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (db_queries_total{namespace="lvl07",pod=~"api-.*",op=~"list|stats"})' | jq -r '.data.result[] | "\(.metric.op): \(.value[1])"'
```
3. Tuzağı yalnızca api'de aç (api pod'ları yeniden başlar, sayaçları sıfırdan başlar), yeni pod'ları ısıt, aynı ölçümü yap:
```bash
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
make reset
```

**Terminalde ne görmelisin:** varsayılan hâlde iki okuma arasında `list` 1 artar, `stats` hiç değişmez: 100 link tek
sorguyla geldi. Tuzak açıkken aynı tek liste isteği `stats`'ı ~100 artırır (link başına bir sorgu; ısıtma istekleri de
ilk okumada ~200 olarak görünür) — maliyet sonuç kümesiyle doğru orantılı. `liste süresi` de tuzakta genelde daha
yüksektir, ama iki koşu arasında oynar: asıl ölçü sorgu sayısı (script de hükmü ona göre verir).

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç (giriş: admin / ladder)
- "Veritabanı sorguları (türe göre)" → başta 100 oluşturma `create` serisinde görünür. Varsayılan fazda liste isteği yalnızca `list` serisinde küçük bir kıpırtıdır; tuzak açıkken aynı istek `stats` serisinde **ayrı** bir tepe doğurur: link başına bir sorgu (100 link → ~100 sorgu). Yalnızca birkaç liste isteği atıldığı için tepeler alçak ve kısadır; sorgu sayısının kendisi terminalde.
- "p99 süre (uç noktaya göre)" → `/api/links` çizgisi tuzak fazında daha yüksektir.

**Ders:** Sayfa boyutu bir ayar değil, bir **maliyet çarpanı** hâline gelir. Doğrusu tek toplu sorgu
(`WHERE code = ANY($1)`) ya da tek JOIN. **Servis ayrımı bunu kötüleştirir**: 101 fonksiyon çağrısı
101 **ağ** çağrısına dönebilir → 14'te gRPC + batch.

---

### P07-07 · Node donunca yedeklilik işe yaramıyor

**Belirti:** Bir worker `docker pause` ile dondurulduğunda istekler düşmeye başlar ve bu **dakikalarca** sürer.
**Neden:** Donmuş node'daki pod'lar Endpoints'te **kalır** — kubelet cevap vermiyor ama API server
pod'u hâlâ Ready sanıyor. `node-monitor-grace-period` (40 sn) + eviction timeout (5 dk) boyunca
trafik ölü pod'lara gider. [Topic · Konu: Düğüm arızası, sağlık algılama gecikmesi]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `FREEZE_NODE=1 CONFIRM=1 make repro P=P07-07` (taban hızı ölçer, bir redirect
pod'unun düğümünü `docker pause` ile dondurur, NotReady süresini, tamamlanan istek hızını ve 5xx'i ölçer, sonra
düğümü çözer, containerd'yi yeniden başlatır ve Ready olmasını bekler). `FREEZE_NODE=1` olmadan
(`CONFIRM=1 make repro P=P07-07`) yalnızca replikaların düğümlere dağılımını basıp durur.

**Bu deney varsayılan olarak ATLANIR.** Node'un kubelet'ini donduruyor ve çözdükten sonra
containerd'nin PLEG'i ölü kalabiliyor — node onlarca dakika `NotReady` kalabilir, o node'daki
Chaos Mesh/Argo/KEDA pod'ları çürür ve sonraki bütün ölçümler bozuk bir kümede koşar.
Bilerek çalıştır: `FREEZE_NODE=1 CONFIRM=1 make repro P=P07-07`.
*Bir deneyin bedeli ortamın tamamıysa, onu varsayılan yapma.*

Elle — `07-services-autoscaling` klasöründe, sırayla yapıştır. **Yıkıcı:** 3. adım bir kind düğümünü (Docker
konteynerini) dondurur; 4. adım (çözme + containerd'yi yeniden başlatma + Ready'yi bekleme) ne olursa olsun
çalıştırılmalı, yoksa düğüm NotReady kalır ve sonraki her deney bozuk bir kümede koşar:

1. Grafana'yı temizle, replikaların hangi düğümlerde olduğuna bak ve hazır bir redirect pod'unun düğümünü seç
   (sonlanmakta olan bir pod'un düğümünü seçmemek için önce rollout'u bekle):
```bash
make fresh
kubectl -n lvl07 rollout status deploy/redirect
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect -o wide
victim=$(kubectl -n lvl07 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].nodeName}' | awk '{print $1}'); echo "dondurulacak düğüm: $victim"
```
2. Taban: donma öncesi 30 sn'de kaç istek tamamlanıyor:
```bash
make load S=redirect K6_ARGS="--vus 10 --duration 30s"
```
3. İKİNCİ bir terminalde `07-services-autoscaling` klasöründe 120 sn'lik yükü başlat:
```bash
make load S=redirect K6_ARGS="--vus 10 --duration 120s"
```
   ~12 sn sonra İLK terminalde düğümü dondur, NotReady olmasını izle, pod'ların API'deki hâline bak, 20 sn daha bekle:
```bash
docker pause "$victim"
for i in $(seq 1 20); do st=$(kubectl get node "$victim" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); echo "$((i*5)) sn: Ready=$st"; [ "$st" = True ] || break; sleep 5; done
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect -o wide
sleep 20
```
4. Düğümü çöz — bu adımı atlama. containerd'yi yeniden başlat (dondurma sonrası PLEG'i ölü kalabiliyor) ve düğüm
   `Ready` olana kadar bekle; `kubectl wait` zaman aşımına düşerse aynı komutu tekrar çalıştır, düğüm Ready olmadan
   devam etme:
```bash
docker unpause "$victim"
docker exec "$victim" systemctl restart containerd
kubectl wait --for=condition=Ready node/"$victim" --timeout=150s
kubectl get nodes
kubectl -n lvl07 get pods -o wide
```

**Terminalde ne görmelisin:** tabanın k6 çıktısının sonundaki özet satırında `k6 lvl07: reqs=…` (30'a böl: saniyedeki istek). Dondurmadan
sonra döngü ~40 sn içinde `Ready=Unknown` basar (kubelet sessiz); ama `get pods` donmuş düğümdeki `redirect-…` pod'unu
hâlâ `Running` ve `1/1` gösterir — API sunucusu onu hazır sanıyor, Endpoints'ten düşmüyor. İkinci terminaldeki
120 sn'lik yükün özet satırında `reqs` tabanın 4 katına yaklaşmaz: istekler ölü pod'a gidip asılı kalır. `5xx`
az olur ya da sıfır kalır — arızanın işareti burada hata kodu değil, işin bitmemesi (script, hızın tabanın yarısının
altına düşmesini ya da 5xx'i arar). Asılı bir istek k6'nın 60 sn'lik zaman aşımına düşerse k6 onun için bir
`request timeout` uyarısı basar ve onu `5xx` sayar. 4. adımın sonunda bütün düğümler `Ready`.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-30m&to=now&refresh=10s), [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-30m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-30m&to=now&refresh=10s) — yalnızca düğüm gerçekten dondurulduysa dolar (elle 3. adım ya da `FREEZE_NODE=1` ile otomatik koşu); `FREEZE_NODE`'suz otomatik koşu node'u dondurmadan çıkar (giriş: admin / ladder)
- "Düğüm başına pod" → donmuş node'un çizgisi **düşmez**: Kubernetes o node'daki pod'ları hâlâ yerinde sanıyor (40 sn + 5 dk kuralı).
- "Dönen durum kodları" (k6) → donma anından itibaren `302` çizgisi belirgin biçimde düşer; ölü pod'a giden istekler zaman aşımına uğradıkça 5xx (`502`/`504`) çizgileri belirir. Kodların anlamı: [Grafana'yı okumak](../README.md#grafanayı-okumak).
- "İstek / saniye (pod'a göre)" (App RED) → donmuş node'daki `redirect-…` pod'unun çizgisi kesilir (Prometheus onu da kazıyamıyor), diğerleri sürer. Aynı dashboard'daki "5xx (uç noktaya göre)" burada 0 kalabilir: zaman aşımını uygulama değil ingress üretiyor, hatayı k6 tarafında gör.

**Nerede çözülüyor:** 10 (devre kesici + aktif sağlık kontrolü: *Kubernetes'in fark etmesini
beklemek yerine client'ın kendisi hızlı karar verir*). Ayrıca `topologySpread`'i `DoNotSchedule`
yapmak — ama o da kapasiteyi zorlar (P07-05).

---

### P07-08 · TRAP · Her zaman hazır diyen probe

**Belirti:** `TRAP_READY_ALWAYS` ile rollout sırasındaki 5xx sayısı artar.
**Neden:** Bir probe'un değeri **hayır diyebilmesindedir**. Sabit 200, Kubernetes'in elindeki tek
gerçek bilgiyi siler. [Topic · Konu: Probe semantiği]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P07-08` (preStop beklemesini deney süresince 0 yapar — yoksa
5 sn'lik preStop trafiği emer ve iki modda da 5xx=0 çıkar —, aynı rollout'u yük altında varsayılan ve tuzaklı
readiness ile koşar, 5xx'i ve rollout sırasındaki tepe hazır endpoint sayısını karşılaştırır, sonra her şeyi geri alır).

Elle — `07-services-autoscaling` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, redirect'in preStop beklemesini 0 yap (diğer koruma sussun, yalnızca readiness'ın değeri ölçülsün):
```bash
make fresh
kubectl -n lvl07 patch deploy/redirect --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":0}]'
kubectl -n lvl07 rollout status deploy/redirect
```
2. Varsayılan readiness ile rollout: İKİNCİ bir terminalde `07-services-autoscaling` klasöründe yükü başlat:
```bash
make load S=redirect K6_ARGS="--vus 10 --duration 60s"
```
   ~12 sn sonra İLK terminalde rollout'u başlat ve bitene kadar her 2 sn'de endpoint'lerin `ready` durumunu bas:
```bash
kubectl -n lvl07 rollout restart deploy/redirect
for i in $(seq 1 30); do kubectl -n lvl07 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{" "}{end}{end}'; echo; kubectl -n lvl07 rollout status deploy/redirect --timeout=3s >/dev/null 2>&1 && break; sleep 2; done
```
3. Tuzağı yalnızca redirect'te aç (pod'lar yeniden başlar), sonra 2. adımı aynen tekrarla — İKİNCİ terminalde
   aynı yük, ~12 sn sonra İLK terminalde aynı rollout döngüsü:
```bash
make set E="TRAP_READY_ALWAYS=true" W=redirect
sleep 10
```
```bash
make load S=redirect K6_ARGS="--vus 10 --duration 60s"
```
```bash
kubectl -n lvl07 rollout restart deploy/redirect
for i in $(seq 1 30); do kubectl -n lvl07 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{" "}{end}{end}'; echo; kubectl -n lvl07 rollout status deploy/redirect --timeout=3s >/dev/null 2>&1 && break; sleep 2; done
```
4. Geri al: tuzağı kapat, preStop'u manifestteki 5 sn'ye döndür:
```bash
make reset
kubectl -n lvl07 patch deploy/redirect --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":5}]'
kubectl -n lvl07 rollout status deploy/redirect
```

**Terminalde ne görmelisin:** döngünün her satırı o anki endpoint'lerin `ready` bayrakları (`true true false …`);
rollout boyunca `true` sayısı yeni pod'lar girip eskiler çıktıkça değişir. İki fazı karşılaştır: `true` sayısının
tepesi ve ikinci terminaldeki k6 özet satırının (`k6 lvl07: …`) `5xx=` değeri. Tuzak fazında yeni pod'lar süreç açılır açılmaz `true`
sayılır. Fark çıkmayabilir: Kubernetes sonlanan pod'u readiness'tan bağımsız olarak Endpoints'ten düşürüyor — bu
durumda script de NOT-REPRODUCED der ve nedenini yazar; probe'un değeri P01-07 ve P10-02'de ölçülüyor.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-15m&to=now&refresh=10s) — iki rollout var (varsayılan, sonra tuzaklı); scripti başlatınca aç (giriş: admin / ladder)
- "Hazır pod adresi (endpoint) sayısı" → her rollout'ta `redirect-…` çizgisi kısa bir tepe/çukur çizer (yeni pod'lar girer, eskiler çıkar). Tuzak fazında yeni pod'lar süreç açılır açılmaz hazır sayılır; iki rollout'un şeklini yan yana karşılaştır.
- "Dönen durum kodları" (k6) → rollout anlarında 5xx (`502`/`503`) kıvılcımları; tuzaklı rollout'takileri varsayılandakilerle karşılaştır. Bu hatalar ingress'ten gelir, `02 · App RED` onları görmez. Fark çıkmayabilir: Kubernetes sonlanan pod'u readiness'tan bağımsız olarak Endpoints'ten düşürüyor — scriptin sonundaki nota bak.

**Aynı kökten üç hata:** readiness'ı TCP kontrolüne indirgemek · `/healthz`'i readiness olarak
kullanmak (kapanışta hayır diyemez — 01'de ayırmıştık) · readiness'a bağımlılık koymak (P02-10).
Hepsi **probe'un ne sorduğunu tanımlamamaktan** doğuyor.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_LIST_N_PLUS_ONE` | Liste yanıtında link başına stats sorgusu | `make repro P=P07-06` | Bayrağı kapat; toplu sorgu |
| `TRAP_READY_ALWAYS` | readiness sabit 200 | `make repro P=P07-08` | Bayrağı kapat |
| `TRAP_COMMIT_BEFORE_WRITE` · `TRAP_NO_DLQ` · `TRAP_COMMIT_DELAY_MS` | (06'dan devam) | 06'da | — |

Elle denemeye değer:
- `kubectl -n lvl07 patch hpa redirect --type=json -p '[{"op":"replace","path":"/spec/behavior/scaleUp/stabilizationWindowSeconds","value":60}]'`
  sonra P07-01'i tekrar koş: ölçek-büyütmeyi yavaşlatmanın bedelini ölç.
- `rpk topic add-partitions clicks -n 6` sonra `make load S=hot-key` ile KEDA'nın tüketiciyi
  gerçekten ölçekleyebildiğini gör (P06-03 tavanı kalkınca KEDA anlam kazanır).
- api-svc'ye HPA ekle ve `make load S=create` koş: yazma yolunu ölçeklemenin DB'ye etkisi,
  okuma yolunu ölçeklemekten **farklıdır** (yazma replikaya dağıtılamaz).
- `DB_MAX_CONNS=2` yap ve `stairs` koş: havuzu küçültmek P07-02'yi çözmez, kuyruğu uygulamaya taşır
  (P02-06'nın aynısı). *Bir kaynağı paylaşan iki taraf varsa, sınırı tek taraftan koymak işe yaramaz.*

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now) | **Dolu** ✨ | HPA desired/current, Pending pod, node kapasitesi, KEDA scaler değeri |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now) | Dolu — **servis bazında** | Artık `redirect` ve `api` ayrı pod'lar; panelleri `pod` kırılımıyla oku |
| [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl07&from=now-15m&to=now) · [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl07&from=now-15m&to=now) · [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl07&from=now-15m&to=now) | Dolu | — |
| [`01 · Pods`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now) → "CPU kısıtlama (throttling)" | **Boş (ortam sınırı)** | cAdvisor bu kurulumda metriği yayınlamıyor — P07-04'teki nota bak |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl07&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl07&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl07&from=now-15m&to=now) | Boş | — |

Bu seviyede dashboard okuma alışkanlığı değişiyor: tek bir "uygulama" yok artık. `app-red`'e
bakarken `pod` ya da `service` kırılımı olmadan bakmak, iki farklı yük şeklinin ortalamasını
almak demektir — ve ortalama, iki farklı dağılımı gizleyen en iyi araçtır.

## 9. Bilerek bırakılanlar

- **Postgres hâlâ tek ve havuz aritmetiği sınırda** (P07-02 → 09).
- **Redis hâlâ tek** (P04-01 → 14).
- **Tek partition** — KEDA 6 replikaya çıkabilir ama 1 partition tavanı var (P06-03).
- **api-svc'de HPA yok** — trafiği öngörülebilir kabul edildi; bu bir varsayımdır ve yanlış olabilir.
- **Servisler arası çağrı yok** (N+1 tuzağı hariç): 14'te gRPC ile gelecek.
- **Hız sınırı hâlâ süreç içi** ve artık **iki ayrı serviste** — yani P02-04 daha da kötüleşti (08).
- **Kaynak istekleri tahmini**: gerçek profil ölçülmedi; VPA kurulu değil (kapsam dışı).

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 06 ile farkı gösterir:

1. **`cmd/linkly/` SİLİNDİ**, yerine `cmd/redirect-svc/` ve `cmd/api-svc/` geldi. İki `main.go`'nun
   büyük kısmı **aynı** — ve bu kasıtlı: ortak kod `internal/`'da, farklı olan yalnızca hangi
   handler'ın bağlandığı ve hangi ayarların verildiği.
2. **`internal/httpapi/split.go`** (yeni): `RedirectHandler` ve `APIHandler`. Ayrım bir **yönlendirme
   tablosu** meselesi; iş mantığı bölünmedi.
3. **`deploy/redirect-svc.yaml` vs `deploy/api-svc.yaml`**: asıl fark burada.
   Karşılaştırmalı oku — `DB_MAX_CONNS` 6 vs 15, replika 2–12 (HPA) vs sabit 2, CPU limiti var vs yok.
   **Aynı kod, zıt ayarlar.** Tek deployment bu iki ayarı aynı anda taşıyamazdı.
4. **`deploy/keda.yaml`** (yeni): tüketici CPU'ya değil **lag**'e göre ölçekleniyor.
   *Ölçeklemeyi, toplaması en kolay metriğe göre değil, kullanıcıya görünen sorunu kodlayan
   metriğe göre yap.*
5. **`deploy/ingress.yaml`**: yol tabanlı yönlendirme. Dışarıdan hiçbir şey değişmedi — servis
   sınırının doğru çizildiğinin kanıtı.
