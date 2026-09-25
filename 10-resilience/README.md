# 10 — resilience · "Hata izolasyonu"

> **Bu seviyede ne yaşayacaksın?**
> - Bir bağımlılık kısmen bozulunca sistemin de yalnızca kısmen bozulması: timeout bütçesi, bütçeli retry, devre kesici, bulkhead, yük atma — hepsi tek bir `Guard`'da
> - Tuzak: bütçesiz retry'ın arızalı bağımlılığa giden yükü katlaması (P10-01); tuzak: bağımlılığa bakan readiness'ın bütün pod'ları birden düşürmesi (P10-02)
> - Hizasız timeout'larla boşa yapılan iş (P10-03); tuzak: devre kesicinin açılması, denemesi ve flapping (P10-04)
> - Tuzak: yavaş bağımlılığın ölüden beter olması (P10-05); kapasite dolunca kabul edileni hızlı tutmak için yük atmak (P10-06)
>
> **Bu seviye olmasa ne olur?** Yavaşlayan tek bir Redis ya da DB bütün istek havuzunu doldurur; bir bağımlılığın arızası bütün servisin arızası olur.
>
> **Yeni gelen teknolojiler:** `internal/resilience` (timeout, retry, breaker, bulkhead, shedder), degrade modları, `11 · Resilience` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Tek soru: bir bağımlılık kısmen bozulunca sistem nasıl kısmen çalışır kalır? Beş mekanizma eklenir — timeout
bütçesi, bütçeli retry, devre kesici, bulkhead, yük atma — ve hepsi tek bir `Guard` ile veri yoluna uygulanır.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> S["shedder<br/>in-flight > N → hızlı 503"]
  S --> H["handler<br/>timeout bütçesi"]
  H --> CA["Cached<br/>(önbellek)"]
  CA --> GR["Guard(redis)<br/>breaker · bulkhead · timeout"] --> R[(redis)]
  GR -.->|"açık / bulkhead dolu"| D2["degrade: no_cache<br/>önbellek atlanır → DB"]
  CA -->|ıska| RW["ReadWrite<br/>(primary / replika)"]
  RW --> GP["Guard(postgres)<br/>breaker · bulkhead · retry"] --> PG[(postgres)]
  GP -.->|"açık / bulkhead dolu"| D1["degrade: cache_only<br/>yalnızca isabetler cevaplanır"]
```

Her bağımlılığın kendi guard'ı ve `dep` etiketi var (`postgres`, `redis`); Postgres guard'ı önbelleğin altında durur,
önbellek isabetleri ona hiç uğramaz.

| Mekanizma | Sorusu | Neyi korur |
|---|---|---|
| timeout | ne kadar beklerim? | tek isteği |
| retry (+ bütçe, + jitter) | tekrar dener miyim? | geçici kayıptan kurtarır |
| breaker (devre kesici) | sormaya devam eder miyim? | bağımlılığı ve beklemekten seni |
| bulkhead | aynı anda kaç kişi sorar? | diğer bağımlılıkların kapasitesini |
| shedding (yük atma) | kabul eder miyim? | kabul ettiklerinin gecikmesini |

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P04-01 | Redis düşünce tüm yük DB'ye iner | Bulkhead + devre kesici: DB'ye giden eşzamanlılık sınırlı, bozuk bağımlılık hızlı reddedilir; kesinti taşınmaz, sınırlanır |

P02-06 (yavaş sorgu → havuz tıkanması) ve P09-02 (failover penceresi) de büyük ölçüde emilir: timeout + retry + breaker.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/10-resilience"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl10.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl10.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl10 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P10-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make chaos C=pg-loss-30   # bu seviyenin ana aracı
make unchaos
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl10 ayakta` yazar:
```bash
cd "$LADDER/09-database-scaling"
make down
cd "$LADDER/10-resilience"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/10-resilience"
make up
```
2. 09'un sorunlarını burada koş (koşarken başka komut çalıştırma). `problems/SOLVES` 09'dan bir sorun listelemiyor
   (içindeki P04-01 04'ün sorunu), bu yüzden `BEKLENEN` her satırda `(açık kalabilir)` der; `SONUÇ` 09'un
   sorunlarından hangilerinin burada hâlâ üretildiğini gösterir. P09-02 ve P09-06 `SKIPPED` görünür — onları da
   koşmak için `CONFIRM=1 make verify-prev`:
```bash
cd "$LADDER/10-resilience"
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P10-01 → P10-06): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç. Deneylerin çoğu bir arıza enjekte eder (`make chaos`) ve iki faz
   koşar: koruma açık, sonra `make set … W=redirect` ile tuzak açık; son adım ikisini de geri alır.
4. Bitince kalan arızaları ve ayarları geri al, seviyeyi kapat:
```bash
cd "$LADDER/10-resilience"
make unchaos
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Yeni davranış: aşırı yükte `503 {"error":"overloaded"}` + `Retry-After`. Bu bir arıza değil karardır: sunucu kabul
ettiklerine hızlı cevap verebilmek için fazlasını erken reddeder.

## 6. Reproduce edilebilir sorunlar

Her sorun aynı düzende: **Ne deniyoruz** (deneyin sorusu) → **Neden** → adımlar (her adım ne yaptığını söyler)
→ **Terminalde ne görmelisin** → **Grafana'da gör** (giriş: admin / ladder) → **Nerede çözülüyor**.
`make repro` hükmü: `REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` = ölçülemedi.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P10-01 | **TRAP** bütçesiz retry = yükseltec | `make repro P=P10-01` | [11 · Resilience](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) → "Yeniden deneme / sn" | seviye içi |
| P10-02 | **TRAP** readiness bağımlılığa bakar | `CONFIRM=1 make repro P=P10-02` | [11 · Resilience](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-15m&to=now&refresh=10s) → "Hazır pod adresi (endpoint) sayısı" | seviye içi |
| P10-03 | Timeout hizasızlığı: boşa çalışan sunucu | `make repro P=P10-03` | [11 · Resilience](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-15m&to=now&refresh=10s) → "Başarısız oran (zaman içinde)" | seviye içi |
| P10-04 | **TRAP** devre kesici yok / flapping | `make repro P=P10-04` | [11 · Resilience](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl10&from=now-15m&to=now&refresh=10s) → "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" | seviye içi |
| P10-05 | **TRAP** yavaş bağımlılık, ölüden beter | `make repro P=P10-05` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl10&from=now-15m&to=now&refresh=10s) · [11 · Resilience](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) → "Goroutine sayısı" | seviye içi |
| P10-06 | Yük atma: kabul edileni hızlı tut | `make repro P=P10-06` | [11 · Resilience](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-30m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-30m&to=now&refresh=10s) → "Atılan yük / sn" | seviye içi |

---

### P10-01 · TRAP · Bütçesiz retry bir yükseltectir

**Ne deniyoruz:** Bağımlılık %30 hata verirken "3 kez dene" kuralı ona giden yükü katlıyor mu?
**Neden:** Retry geçici bir kaybı kurtarmak içindir; bütçe (retry trafiğin en fazla %10'u) olmadan, zaten hata veren
bağımlılığa ikinci bir yük kaynağı olur.

**Reproduce (adım adım):** Otomatik: `make repro P=P10-01` (`pg-loss-30` altında aynı yükü önce bütçeli retry'la,
sonra `TRAP_NAIVE_RETRY` ile verir; iki fazın Postgres çağrı ve retry sayısını karşılaştırır). Elle:

1. Temiz başla; Postgres'e %30 paket kaybı enjekte et:
```bash
cd "$LADDER/10-resilience"
make fresh
make chaos C=pg-loss-30
sleep 5
```
2. Bütçeli retry'la (varsayılan: en fazla 2 tekrar, retry trafiğin en fazla %10'u) 45 sn yük ver, Postgres çağrısı ve
   retry sayısını oku:
```bash
cd "$LADDER/10-resilience"
make load S=mixed K6_ARGS="--vus 25 --duration 45s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(dependency_requests_total{namespace="lvl10",dep="postgres"}[3m]))' | jq -r '"postgres çağrısı: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(retry_total{namespace="lvl10",dep="postgres"}[3m]))' | jq -r '"retry: " + .data.result[0].value[1]'
```
3. Tuzağı aç (3 deneme, bütçe ve jitter yok; redirect pod'ları yeniden başlar), aynı yükü ver, aynı iki sayıyı oku:
```bash
cd "$LADDER/10-resilience"
make set E="TRAP_NAIVE_RETRY=true" W=redirect
make load S=mixed K6_ARGS="--vus 25 --duration 45s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(dependency_requests_total{namespace="lvl10",dep="postgres"}[3m]))' | jq -r '"postgres çağrısı: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(retry_total{namespace="lvl10",dep="postgres"}[3m]))' | jq -r '"retry: " + .data.result[0].value[1]'
```
4. Arızayı kaldır, tuzağı kapat:
```bash
cd "$LADDER/10-resilience"
make unchaos
make reset
```

**Terminalde ne görmelisin:** `make chaos` `networkchaos.chaos-mesh.org/pg-loss-30 created` basar. 2. adımda `retry`,
`postgres çağrısı`nın en fazla ~%10'u: bütçe retry'ı sınırlıyor. 3. adımda aynı yükle ikisi de büyür: bir kullanıcı
isteği birden çok bağımlılık çağrısına dönüşüyor, tam da bağımlılık hata verirken. (3 dakikalık pencere 2. adımın
kuyruğunu da biraz içerir; script de aynı pencereyle ölçer.)

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; `pg-loss-30` altında iki faz 45'er sn, arada redirect rollout'u
- "Yeniden deneme / sn" → `postgres` çizgisi birinci fazda (bütçeli) alçak; ikinci fazda (`TRAP_NAIVE_RETRY`) belirgin yükselir.
- "Bağımlılık hatası / sn" → `postgres` iki fazda da sıfırın üstünde: retry'ların üstüne bindiği arıza bu.
- Explore'da: `sum(rate(dependency_requests_total{namespace="lvl10",dep="postgres"}[1m]))` → aynı yükle ikinci fazda daha yüksek: istek başına birden çok bağımlılık çağrısı.

**Nerede çözülüyor:** Seviye içinde: üstel geri çekilme + jitter (retry'lar senkronize olmasın) + bütçe. Bütçenin
gerçekten harcandığını `TestRetryBudgetCapsAmplification` birim testi doğrular.

---

### P10-02 · TRAP · Readiness'ın bağımlılığa bakması (ikinci kez)

**Ne deniyoruz:** Redis ~40 sn kesilince redirect pod'ları trafikten düşüyor mu?
**Neden:** Uygulama Redis'siz de çalışır (önbelleği atlayıp DB'ye gider), ama readiness Redis'e bakarsa bütün pod'lar
aynı anda "hazır değilim" der ve trafik alacak pod kalmaz (P02-10'un kardeşi).

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P10-02` (yük altında Redis'i iki kez ~40 sn durdurur —
önce varsayılan readiness, sonra `TRAP_READY_CHECKS_REDIS`; her fazda en düşük hazır adres sayısını, 5xx'i ve `no_cache`
degrade tepesini ölçer). Elle — 3. ve 7. adım Redis'i durdurur, aynı bloğun son iki satırı geri getirir; bloğu yarıda
kesme:

1. Temiz başla; redirect'in hazır pod adresi sayısına bak:
```bash
cd "$LADDER/10-resilience"
make fresh
kubectl -n lvl10 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' | grep -c true
```
2. İkinci bir terminalde 90 sn yük başlat:
```bash
cd "$LADDER/10-resilience"
make load S=redirect K6_ARGS="--vus 10 --duration 90s"
```
3. ~12 sn sonra ilk terminalde Redis'i durdur, 40 sn boyunca 2 sn'de bir hazır adres sayısını bas, Redis'i geri getir:
```bash
cd "$LADDER/10-resilience"
kubectl -n lvl10 scale statefulset redis --replicas=0
for i in $(seq 1 20); do kubectl -n lvl10 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' | grep -c true; sleep 2; done
kubectl -n lvl10 scale statefulset redis --replicas=1
kubectl -n lvl10 rollout status statefulset/redis --timeout=180s
```
4. Yük bitince kesinti sırasında Redis devresinin açılıp açılmadığına bak:
```bash
cd "$LADDER/10-resilience"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(max(degraded_mode{namespace="lvl10",mode="no_cache"})[2m:10s])' | jq -r '"no_cache tepe: " + .data.result[0].value[1]'
```
5. Tuzağı aç (readiness Redis'e ping atar; redirect pod'ları yeniden başlar):
```bash
cd "$LADDER/10-resilience"
make set E="TRAP_READY_CHECKS_REDIS=true" W=redirect
```
6. İkinci terminalde yükü yeniden başlat:
```bash
cd "$LADDER/10-resilience"
make load S=redirect K6_ARGS="--vus 10 --duration 90s"
```
7. ~12 sn sonra ilk terminalde aynı kesintiyi tekrarla:
```bash
cd "$LADDER/10-resilience"
kubectl -n lvl10 scale statefulset redis --replicas=0
for i in $(seq 1 20); do kubectl -n lvl10 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' | grep -c true; sleep 2; done
kubectl -n lvl10 scale statefulset redis --replicas=1
kubectl -n lvl10 rollout status statefulset/redis --timeout=180s
```
8. Yük bitince tuzağı kapat:
```bash
cd "$LADDER/10-resilience"
make reset
```

**Terminalde ne görmelisin:** 1. adımda hazır pod sayısı (manifest'te 2; HPA ölçeklediyse fazla). Varsayılan fazda
Redis dururken döngü hep aynı sayıyı basar, k6 özetinde `5xx` ~0 ve `no_cache tepe: 1`: Redis devresi açıldı, okumalar
DB'den cevaplandı, pod trafik almaya devam etti. Tuzaklı fazda döngü birkaç saniyede `0` basar ve Redis dönene kadar
`0`'da kalır; `5xx` sıfırdan büyük (ingress'in gönderecek pod'u yok → 503). Redis dönünce bütün pod'lar aynı anda geri
gelir.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; iki faz 90'ar sn, Redis her fazda ~40 sn durur
- "Hazır pod adresi (endpoint) sayısı" → `redirect` çizgisi birinci fazda düz; ikinci fazda 0'a iner ve Redis dönünce bütün pod'larla aynı anda geri gelir.
- "Azaltılmış mod (degrade)" → birinci fazda `no_cache` 1'e çıkar: bağımlılığın durumu bir metrikte görünüyor, pod ise trafik almaya devam ediyor.
- "Dönen durum kodları" (k6) → birinci fazda `302` kesintisiz; ikinci fazda kesinti boyunca `503`.

**Nerede çözülüyor:** Seviye içinde: Redis kendi guard'ının arkasında; kesinti devresini açar ve `no_cache` degrade
modunu işaretler. Readiness "trafik alabilir miyim?" sorusudur; "bağımlılığım iyi mi?" bir metriktir.

---

### P10-03 · Timeout hizasızlığı

**Ne deniyoruz:** İstemci 1 sn'de vazgeçtiğinde sunucu işi bırakıyor mu, yoksa kimseye teslim edemeyeceği işi taşıyor mu?
**Neden:** Timeout bütçesi bir zincirdir: her katman, kendisini çağıranın kalan süresinden az beklemeli
(`handler > bağımlılık ≥ sorgu`).

**Reproduce (adım adım):** Otomatik: `make repro P=P10-03` (redirect'in timeout zincirini basar, `pg-delay-2s` altında
45 sn yük verir; tepe in-flight, goroutine, Postgres çağrı p99'u, timeout ve bulkhead reddini ölçer). Elle:

1. Temiz başla; redirect'in timeout zincirine bak (manifest'tekiler ve kodun varsayılanları):
```bash
cd "$LADDER/10-resilience"
make fresh
make env W=redirect | grep TIMEOUT
grep -nE '"(HANDLER_TIMEOUT|DEP_TIMEOUT|DB_QUERY_TIMEOUT)"' internal/config/config.go
```
2. Postgres'e 2 sn gecikme enjekte et, 1 sn'de vazgeçen istemciyle yük ver:
```bash
cd "$LADDER/10-resilience"
make chaos C=pg-delay-2s
sleep 5
make load S=mixed K6_ARGS="--vus 30 --duration 45s -e K6_TIMEOUT=1s"
sleep 10
```
3. Sunucunun ne kadar iş taşıdığını ve korumaların tetiklenip tetiklenmediğini oku:
```bash
cd "$LADDER/10-resilience"
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(http_in_flight_requests{namespace="lvl10"})[3m:15s])' | jq -r '"tepe in-flight: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(go_goroutines{namespace="lvl10",pod=~"redirect.*"})[3m:15s])' | jq -r '"tepe goroutine: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace="lvl10",dep="postgres"}[2m])) by (le))' | jq -r '"postgres çağrı p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (result) (increase(dependency_requests_total{namespace="lvl10",dep="postgres",result=~"timeout|bulkhead"}[3m]))' | jq -r '.data.result[] | "\(.metric.result): \(.value[1])"'
```
4. Arızayı kaldır:
```bash
cd "$LADDER/10-resilience"
make unchaos
```

**Terminalde ne görmelisin:** 1. adımda manifest yalnızca `DEP_TIMEOUT=2s` verir; `config.go` diğer varsayılanları
gösterir: `HANDLER_TIMEOUT` 5 sn, `DB_QUERY_TIMEOUT` 3 sn. k6 özetinde `failed=` yüksek, `5xx` sıfırdan büyük. 3. adımda
Postgres çağrı p99'u 2–2,5 sn bandında (bağımlılık timeout'u 2 sn'de kesiyor) ve `timeout` ve/veya `bulkhead` sıfırdan
büyük: yavaş bağımlılık kendisine ayrılan eşzamanlılıkla sınırlandı (scriptin REPRODUCED koşulu). Tepe in-flight ve
goroutine, taşınan işin büyüklüğü.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; `pg-delay-2s` altında yük 45 sn
- "Başarısız oran (zaman içinde)" (k6) → yük boyunca yüksek: istemci her isteği 1 sn'de bırakıyor.
- "Şu an işlenen istek (pod'a göre)" → aynı anda yükselir: bırakılan istekleri sunucu hâlâ taşıyor; iki panel arasındaki fark kimseye teslim edilmeyecek iş.
- "Bağımlılık gecikmesi p99" → `postgres` 2–2,5 sn'de düzleşir: bağımlılık timeout'u çağrıyı kesiyor.
- Explore'da: `sum(rate(dependency_requests_total{namespace="lvl10",dep="postgres",result=~"timeout|bulkhead"}[1m])) by (result)` → `timeout` ve `bulkhead` yükte sıfırdan ayrılır: koruma çalışıyor.

**Nerede çözülüyor:** Seviye içinde (hizalı timeout zinciri). Eksik halka sunucu tarafı `statement_timeout`'tur
(P02-06): istemci vazgeçse de Postgres sorguyu yalnızca kendisi durdurabilir.

---

### P10-04 · TRAP · Devre kesici: açılma, deneme, flapping

**Ne deniyoruz:** Bağımlılık bozukken devre kesici istekleri hızlı mı cevaplatıyor, yoksa her istek bozuk bağımlılığı mı bekliyor?
**Neden:** Devre kesici (breaker) belli sayıda hatadan sonra bağımlılığa gitmeyi bir süre bırakır ve hızlı reddeder;
yoksa her istek bozuk bağımlılığı bekler. İşi bağımlılığı kurtarmak değil, ona ve sana nefes aldırmaktır.

**Reproduce (adım adım):** Otomatik: `make repro P=P10-04` (`pg-loss-50` altında aynı yükü önce devre kesiciyle, sonra
`TRAP_NO_BREAKER` ile verir; her fazın kendi penceresinde bozuk bağımlılığa ulaşan çağrıyı, istek sayısını ve tipik
isteğin süresini (p50) ölçüp oranları karşılaştırır — p99 iki fazda da handler'ın 5 sn sınırına dayanır). Elle:

1. Temiz başla; Postgres'e %50 paket kaybı enjekte et:
```bash
cd "$LADDER/10-resilience"
make fresh
make chaos C=pg-loss-50
sleep 5
```
2. Devre kesici açıkken (varsayılan) 50 sn yük ver; bu fazda Postgres çağrılarını sonuca göre, tepe devre durumunu ve
   tipik istek süresini (p50) oku:
```bash
cd "$LADDER/10-resilience"
t0=$(date +%s)
make load S=mixed K6_ARGS="--vus 25 --duration 50s"
sleep 20
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum by (result) (increase(dependency_requests_total{namespace='lvl10',dep='postgres'}[${w}s]))" | jq -r '.data.result[] | "\(.metric.result): \(.value[1])"'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(max(breaker_state{namespace='lvl10',dep='postgres'})[${w}s:15s])" | jq -r '"tepe devre durumu: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace='lvl10'}[${w}s])) by (le))" | jq -r '"tipik istek, p50 (sn): " + .data.result[0].value[1]'
```
3. Devre kesiciyi kapat (redirect pod'ları yeniden başlar), aynı yükü ver, aynı üç ölçümü al:
```bash
cd "$LADDER/10-resilience"
make set E="TRAP_NO_BREAKER=true" W=redirect
t0=$(date +%s)
make load S=mixed K6_ARGS="--vus 25 --duration 50s"
sleep 20
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum by (result) (increase(dependency_requests_total{namespace='lvl10',dep='postgres'}[${w}s]))" | jq -r '.data.result[] | "\(.metric.result): \(.value[1])"'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(max(breaker_state{namespace='lvl10',dep='postgres'})[${w}s:15s])" | jq -r '"tepe devre durumu: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace='lvl10'}[${w}s])) by (le))" | jq -r '"tipik istek, p50 (sn): " + .data.result[0].value[1]'
```
4. Arızayı kaldır, devre kesiciyi geri aç:
```bash
cd "$LADDER/10-resilience"
make unchaos
make reset
```

**Terminalde ne görmelisin:** sonuç satırları `ok`, `error`, `timeout`, `bulkhead`, `open`. 2. adımda `open` büyük
(bağımlılığa hiç gitmeden reddedilen çağrılar) ve `tepe devre durumu: 2` (açık). Bozuk bağımlılığa ulaşan çağrı =
`open` dışındakilerin toplamı; k6 özetindeki `reqs=` ile oranla. 3. adımda `open` `0`, devre durumu `0`: her istek
bozuk bağımlılığa gidiyor, ulaşan/istek oranı büyür ve tipik istek (p50) milisaniyelerden saniyelere çıkar — yavaş
hata, hızlı hatadan kötü.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl10&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; `pg-loss-50` altında iki faz ~70'er sn, arada redirect rollout'u
- "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" → birinci fazda `postgres` 0'dan 2'ye çıkar ve 2 / 1 / 0 arasında gidip gelir (açık → yarı açık deneme → yine açık): testere dişi = flapping. İkinci fazda düz 0.
- "Azaltılmış mod (degrade)" → birinci fazda devre açıkken `cache_only` 1: önbellek isabetleri cevaplanmaya devam ediyor, yalnızca ıskalar hızlı 503 alıyor. İkinci fazda 0.
- "Gecikme (p50 / p95 / p99)" (App RED) → ikinci fazda belirgin yükselir: her istek bozuk bağımlılığı bekliyor.
- Explore'da: `sum(rate(dependency_requests_total{namespace="lvl10",dep="postgres",result="open"}[1m]))` → yalnızca birinci fazda sıfırdan ayrılır: DB'ye hiç gitmeden reddedilen çağrılar.

**Nerede çözülüyor:** Seviye içinde (devre kesici). Eşik ayarı bir ölçüm işidir: çok hassas → sağlıklı bağımlılık bozuk
ilan edilir; çok tembel → arıza fark edilmez. `ErrNotFound` (404) devreyi tetiklemez: 404 arıza değildir.

---

### P10-05 · TRAP · Yavaş bağımlılık, ölüden beterdir

**Ne deniyoruz:** Redis ölmeyip 3 sn yavaşlarsa, timeout'suz kodda istekler birikiyor mu?
**Neden:** Ölü bağımlılık hızlı hata verir; yavaş olan her isteği bekletir. Timeout'suz çağrı sınırsız bir kuyruktur ve
devre kesici de kördür: 3 sn'de gelen cevap başarılı sayılır.

**Reproduce (adım adım):** Otomatik: `make repro P=P10-05` (`redis-delay-3s` altında sabit geliş hızlı yükle — saniyede
60 istek, `RATE=` ile değişir — timeout'lu/timeout'suz goroutine, in-flight, bellek ve Redis çağrı süresini
karşılaştırır). Sabit geliş hızı şart: kapalı döngülü yükte her kullanıcı cevabı beklediği için birikim görünmez;
gerçek trafik servis yavaşladı diye yavaşlamaz. Gecikme yalnızca Redis'ten uygulama pod'larına giden paketlere
uygulanır (Redis'in yoklamaları etkilenmesin). Elle:

1. Temiz başla; Redis'e 3 sn gecikme enjekte et (ölmedi, yavaşladı):
```bash
cd "$LADDER/10-resilience"
make fresh
make chaos C=redis-delay-3s
sleep 5
```
2. Timeout varken (varsayılan) 45 sn saniyede 60 istek ver; tepe goroutine, tepe in-flight, Redis çağrı p99'u ve
   kesilen/devre-açık Redis çağrısı sayısını oku:
```bash
cd "$LADDER/10-resilience"
t0=$(date +%s)
RATE=60 make load S=steady K6_ARGS="--duration 45s"
sleep 15
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(sum(go_goroutines{namespace='lvl10',pod=~'redirect.*'})[${w}s:10s])" | jq -r '"tepe goroutine: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(sum(http_in_flight_requests{namespace='lvl10',pod=~'redirect.*'})[${w}s:10s])" | jq -r '"tepe in-flight: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace='lvl10',dep='redis'}[${w}s])) by (le))" | jq -r '"redis çağrı p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(dependency_requests_total{namespace='lvl10',dep='redis',result=~'timeout|open'}[${w}s]))" | jq -r '"kesilen/devre-açık redis çağrısı: " + .data.result[0].value[1]'
```
3. Süre sınırlarını kaldır (guard'ınki ve Redis istemcisinin 500 ms'si; redirect pod'ları yeniden başlar), gecikmeyi
   yeni pod'lar için yeniden uygula (arıza hedef pod'ları uygulandığı anda sabitler), aynı yükü ver, aynı ölçümleri al:
```bash
cd "$LADDER/10-resilience"
make set E="TRAP_NO_DEP_TIMEOUT=true" W=redirect
make unchaos
make chaos C=redis-delay-3s
sleep 5
t0=$(date +%s)
RATE=60 make load S=steady K6_ARGS="--duration 45s"
sleep 15
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(sum(go_goroutines{namespace='lvl10',pod=~'redirect.*'})[${w}s:10s])" | jq -r '"tepe goroutine: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(sum(http_in_flight_requests{namespace='lvl10',pod=~'redirect.*'})[${w}s:10s])" | jq -r '"tepe in-flight: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace='lvl10',dep='redis'}[${w}s])) by (le))" | jq -r '"redis çağrı p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(dependency_requests_total{namespace='lvl10',dep='redis',result=~'timeout|open'}[${w}s]))" | jq -r '"kesilen/devre-açık redis çağrısı: " + .data.result[0].value[1]'
```
4. Arızayı kaldır, süre sınırlarını geri getir:
```bash
cd "$LADDER/10-resilience"
make unchaos
make reset
```

**Terminalde ne görmelisin:** 2. adımda Redis çağrı p99'u 1 sn'nin altında (çağrılar 500 ms'de kesiliyor) ve
kesilen/devre-açık sayısı sıfırdan büyük: timeout'lar hata sayıldı, devre açıldı, istekler önbelleği atlayıp DB'den
hızlı döndü — ölü bağımlılık gibi. 3. adımda p99 ~3 sn (çağrılar başarıyla ama geç bitiyor), kesilen/devre-açık ~0 ve
tepe goroutine ile in-flight 2. adımdakinden yüksek: bekleyen her çağrı bir goroutine ve bir istek tutuyor. Redis p99'u
uzamadıysa tuzak etkili olmamıştır; script hüküm vermez.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl10&from=now-15m&to=now&refresh=10s) ve [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; `redis-delay-3s` altında iki faz 45'er sn, arada redirect rollout'u
- "Goroutine sayısı" → `redirect-…` pod'larında ikinci fazın tepesi birinciden yüksek: bekleyen her çağrı bir goroutine.
- "Bağımlılık gecikmesi p99" → `redis` birinci fazda ~0,5 sn'de düzleşir; ikinci fazda ~3 sn'ye çıkar: çağrılar sonuna kadar bekleniyor.
- "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" → `redis` birinci fazda 2'ye çıkar; ikinci fazda 0'da kalır: yavaş cevap hata sayılmıyor.
- "Şu an işlenen istek (pod'a göre)" → ikinci fazda belirgin yüksek: istekler bitmiyor, birikiyor.
- "Bellek kullanımı" → goroutine'lerle aynı yönde: bekleyen her çağrı bellekte duruyor.

**Nerede çözülüyor:** Seviye içinde: bir bağımlılığa yapılan her çağrının süre sınırı var — guard'da ve istemcinin
kendisinde. Timeout, süre sınırının uygulandığı yerdedir.

---

### P10-06 · Yük atma: kabul ettiğini hızlı tut

**Ne deniyoruz:** Kapasite dolunca fazlasını reddetmek (yük atma), kabul edilen isteklerin hızını koruyor mu?
**Neden:** Aşırı yüklü sunucu her şeyi kabul ederse herkes yavaşlar ve zaman aşımına uğrar. Eşiği aşan isteği hızlı
bir 503 ile reddetmek, kabul edilenleri hızlı tutar.

**Reproduce (adım adım):** Otomatik: `make repro P=P10-06` (`redis-delay-200ms` altında — istekler sürsün, birikebilsin
— `stairs` yüküyle yük atma açık (eşik 40) / kapalı, kabul edilen isteklerin p99'unu karşılaştırır; atılan 503'ler
uygulamanın histogramına hiç girmez. Hiçbir istek atılmadıysa hüküm vermez). Elle:

1. Temiz başla; Redis'e 200 ms gecikme enjekte et, yük atma eşiğini pod başına 40 eşzamanlı isteğe çek (redirect pod'ları
   yeniden başlar):
```bash
cd "$LADDER/10-resilience"
make fresh
make chaos C=redis-delay-200ms
make set E="SHED_ENABLED=true SHED_MAX_INFLIGHT=40" W=redirect
```
2. Merdiven yükünü ver (50 → 100 → 200 → 400 istek/sn, ~3 dk), atılan istek sayısını ve kabul edilenlerin tepe p99'unu
   oku:
```bash
cd "$LADDER/10-resilience"
t0=$(date +%s)
make load S=stairs
sleep 20
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(load_shed_total{namespace='lvl10'}[${w}s]))" | jq -r '"atılan: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace='lvl10'}[30s])) by (le))[${w}s:10s])" | jq -r '"kabul edilenlerin tepe p99 (sn): " + .data.result[0].value[1]'
```
3. Yük atmayı kapat (her şey kabul edilir), aynı yükü ver, aynı iki ölçümü al:
```bash
cd "$LADDER/10-resilience"
make set E="SHED_ENABLED=false" W=redirect
t0=$(date +%s)
make load S=stairs
sleep 20
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(load_shed_total{namespace='lvl10'}[${w}s]))" | jq -r '"atılan: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace='lvl10'}[30s])) by (le))[${w}s:10s])" | jq -r '"kabul edilenlerin tepe p99 (sn): " + .data.result[0].value[1]'
```
4. İstersen: 2. adımda `atılan: 0` çıktıysa sistem doymadı — yük atmayı yeniden aç ve merdiveni yükselt:
```bash
cd "$LADDER/10-resilience"
make set E="SHED_ENABLED=true SHED_MAX_INFLIGHT=40" W=redirect
RATES=100,200,400,800 make load S=stairs
```
5. Arızayı kaldır, ayarları manifest'teki hâline döndür:
```bash
cd "$LADDER/10-resilience"
make unchaos
make reset
```

**Terminalde ne görmelisin:** 2. adımda `atılan` ve k6 özetindeki `5xx` sıfırdan büyük: hızlı
`503 {"error":"overloaded"}` cevapları. 3. adımda `atılan: 0`, 503 yok ama kabul edilenlerin tepe p99'u 2. adımdakinden
yüksek: her şey kabul edildiği için herkes yavaşladı. Hüküm: yük atma açıkken kabul edilenlerin p99'u ≤ kapalıyken.
2. adımda hiç istek atılmadıysa doygunluğu Redis'in bulkhead'i shedder'dan önce karşılamış olabilir — 4. adımı dene.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-30m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-30m&to=now&refresh=10s) — deney başlayınca aç; `redis-delay-200ms` altında iki `stairs` fazı (~3'er dk), toplam ~8 dk
- "Atılan yük / sn" → birinci fazda merdivenin üst basamaklarında sıfırdan ayrılır; ikinci fazda düz 0.
- "Kabul edilen isteklerin p99 süresi" → birinci fazda alçak kalır; ikinci fazda basamaklarla birlikte tırmanır.
- "Şu an işlenen istek (pod'a göre)" → birinci fazda eşik (40) civarında tavan yapar; ikinci fazda sınırsız yükselir.
- "Dönen durum kodları" (k6) → birinci fazda hızlı `503`'ler: atılan istekler. `02 · App RED` bunları saymaz — shedder metrik katmanının önünde.

**Nerede çözülüyor:** Seviye içinde (shedder). Toplam p99'a bakarsan yük atma kötü görünür, kabul edilenlere bakarsan
iyi: doğru metrik kabul edilenlerinki. Yük atma bir kalite aracıdır, kapasite için ölçekleme gerekir (07); sağlık uçları
asla atılmaz (P01-07).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_NAIVE_RETRY` | 3 deneme, bütçe ve jitter yok | `make repro P=P10-01` | Bayrağı kapat |
| `TRAP_READY_CHECKS_REDIS` | readiness Redis'e ping atar | `CONFIRM=1 make repro P=P10-02` | Bayrağı kapat |
| `TRAP_NO_BREAKER` | Devre kesiciyi etkisizleştirir | `make repro P=P10-04` | Bayrağı kapat |
| `TRAP_NO_DEP_TIMEOUT` | Bağımlılık timeout'unu kaldırır | `make repro P=P10-05` | Bayrağı kapat |

Elle denemeye değer:
- `BREAKER_OPEN=1s` + `BREAKER_THRESHOLD=2` ve `pg-loss-30`: flapping üret ("Devre kesici durumu" testere dişi); sonra `BREAKER_OPEN=30s` ile karşılaştır.
- `DEP_MAX_CONCURRENT=2`: bulkhead çok dar olunca sağlıklı bağımlılıkta bile reddeder — koruma da arıza kaynağı olabilir.
- `make chaos C=redis-kill` + `make load S=mixed`: `no_cache` 1 olur (okumalar DB'den); `make chaos C=pg-loss-50` ile `cache_only` 1 olur (yalnızca isabetler cevaplanır). Degrade bağımlılık başınadır.
- `pg-delay-2s` + `redis-delay-200ms` birlikte: korumaların birlikte etkisi parçaların toplamından farklıdır.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now) | **Dolu** | Devre kesici durumu, bağımlılık gecikmesi/hatası (`postgres`, `redis` ayrı), retry, atılan yük, in-flight, degrade modu |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl10&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl10&from=now-15m&to=now) · [`01 · Pods`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl10&from=now-15m&to=now) | Dolu | Chaos'un etkisi burada; `06 · Redis` → "Uygulama → Redis gecikmesi (p99)" ilk kez dolu |
| [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl10&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl10&from=now-15m&to=now) | Boş | 11 ve 12'de |

Okuma kuralı: devre durumu ile bağımlılık gecikmesini birlikte oku. Açık + düşük gecikme → koruma çalışıyor; kapalı +
yüksek gecikme → eşik çok tembel; testere dişi → eşik çok hassas.

## 9. Bilerek bırakılanlar

- Kafka üreticisinin guard'ı yok (zaten asenkron ve sınırlı tamponlu); Redis'teki hız sınırlayıcı ve yapışkan işaret de guard'sız (kendi kısa timeout'u ve fail-open'ı var).
- Degrade sınırlı: `cache_only` yalnızca önbellekte olanı sunar; DB'siz yazma yolu yok (create 503).
- Adaptif yük atma yok: sabit in-flight eşiği (gerçekte gecikmeye göre uyarlanır).
- `statement_timeout` hâlâ boş (P02-06).
- Chaos elle; sürekli/zamanlanmış chaos yok — game day 14'te.
- 09'dan devreden: nesne deposu/PITR yok, tek Redis, kimlik yok.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 09 ile farkı gösterir:

1. `internal/resilience/breaker.go` (yeni): tek `Guard` beş mekanizmayı birleştirir; yorumlar her birinin ayrı sorusunu yazar.
2. `internal/resilience/shed.go`: sağlık uçlarının yük atmadan muaf tutulması.
3. `internal/store/guarded.go`: `Store` arayüzünün dördüncü sarmalaması (Cached → ReadWrite → Guarded → Postgres); `GuardCall` aynı korumayı Redis'e uygular.
4. `Guarded.Get` içindeki `ErrNotFound` ayrımı: olmasa devre kesici 404'lerle açılırdı.
5. `Guarded.Ping` devre kesiciden geçmez: sağlık kontrolü ham gerçeği görür.
6. `deploy/*-svc.yaml`: sekiz yeni env değişkeni — her biri `make repro` ile ölçülebilen bir takas.
