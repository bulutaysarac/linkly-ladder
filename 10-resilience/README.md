# 10 — resilience · "Hata izolasyonu"

> **Bu seviyede ne yaşayacaksın?**
> - Bir bağımlılık kısmen bozulunca sistemin tamamen değil kısmen bozulması: timeout bütçesi, bütçeli retry, devre kesici, bulkhead, yük atma — hepsi tek bir `Guard`'da
> - Tuzak: bütçesiz retry'ın arızalı bağımlılığa giden yükü katlaması (P10-01); tuzak: readiness'ın bağımlılığa bakınca bütün pod'ları birden düşürmesi (P10-02)
> - İç ve dış timeout'lar hizasızken işin boşa yapılması (P10-03); tuzak: devre kesicinin açılması, denemesi ve flapping (P10-04)
> - Tuzak: yavaş bir bağımlılığın ölü bir bağımlılıktan beter olması (P10-05); kapasite dolunca kabul edileni hızlı tutmak için yük atmak (P10-06)
>
> **Bu seviye olmasa ne olur?** Yavaşlayan tek bir Redis ya da DB bütün istek havuzunu doldurur; bir bağımlılığın arızası bütün servisin arızası olur.
>
> **Yeni gelen teknolojiler:** `internal/resilience` (timeout, retry, breaker, bulkhead, shedder), degrade modları, `11 · Resilience` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Tek soru: bir bağımlılık **kısmen** bozulduğunda sistem tamamen bozulmak yerine nasıl **kısmen
çalışır** kalır? Beş mekanizma ekleniyor ve hiçbiri diğerinin yerine geçmiyor: timeout bütçesi,
bütçeli retry, devre kesici, bulkhead ve yük atma. Her biri `internal/resilience` içinde, hepsi
tek bir `Guard` ile birleşiyor ve `store.Guarded` dekoratörüyle veri yoluna uygulanıyor.

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

Her bağımlılığın **kendi** guard'ı ve kendi `dep` etiketi var (`postgres`, `redis`). Postgres
guard'ı önbelleğin **altında** durur ve yalnızca veritabanı çağrılarını sarar: önbellek isabetleri
ona hiç uğramaz. Bu sıra bir tasarım kararıdır — guard'ın nerede durduğu neyi ölçtüğünü belirler
(bkz. `store/guarded.go`).

Her mekanizmanın işi farklı:

| Mekanizma | Sorusu | Neyi korur |
|---|---|---|
| timeout | ne kadar beklerim? | tek isteği |
| retry (+ bütçe, + jitter) | tekrar dener miyim? | geçici kayıptan kurtarır |
| breaker | sormaya devam eder miyim? | bağımlılığı **ve** beklemekten seni |
| bulkhead | aynı anda kaç kişi sorar? | diğer bağımlılıkların kapasitesini |
| shedding | kabul eder miyim? | kabul ettiklerinin gecikmesini |

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P04-01 | Redis düşünce tüm yük DB'ye iner | Bulkhead + devre kesici: DB'ye giden eşzamanlılık sınırlı, bağımlılık bozulunca hızlı reddediliyor. Kesinti **taşınmıyor**, sınırlanıyor |

Ayrıca P02-06 (yavaş sorgu → havuz tıkanması) ve P09-02 (failover penceresi) büyük ölçüde
emiliyor: timeout + retry + breaker üçlüsü, geçici arızaları kullanıcıya yansıtmadan yutuyor.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl10.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl10.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl10 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P10-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make chaos C=pg-loss-30   # bu seviyenin ana aracı
make unchaos
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Önceki seviye açıksa kapat (aynı anda tek seviye çalışır), bu seviyeyi kur. `make up` Grafana'yı da temizler:
```bash
make -C ../09-database-scaling down
make up
```
2. 09'un altı sorun scriptini bu seviyede koş. Koşarken başka komut çalıştırma: aynı pod'lara dokunurlar.
   `problems/SOLVES` 09'dan bir sorun listelemiyor (içindeki P04-01 04'ün sorunu), bu yüzden `BEKLENEN` sütunu her
   satırda `(açık kalabilir)` der; `SONUÇ` sütunu 09'un sorunlarından hangilerinin burada hâlâ üretildiğini gösterir.
   Onay isteyen P09-02 ve P09-06 `SKIPPED` görünür — onları da koşmak için `CONFIRM=1 make verify-prev`:
```bash
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P10-01 → P10-06). Her sorunda aynı düzen:
   **Elle** bloklarını sırayla yapıştır (ilk komut `make fresh`: Grafana bu deneye boş başlar) →
   **Terminalde ne görmelisin** ile karşılaştır → **Grafana'da gör** linklerini aç, her madde hangi panelde neyi
   göreceğini söyler. İstersen aynı deneyi `make repro P=…` ile otomatik koş: ölçer ve hükmünü basar.
   Bu seviyede deneylerin çoğu bir arıza enjekte eder (`make chaos`) ve iki faz koşar: önce koruma açıkken, sonra
   `make set … W=redirect` ile tuzak açıkken. Her sorunun son adımı ikisini de geri alır.
4. Bitince kalan arızaları ve açık ayarları geri al, seviyeyi kapat:
```bash
make unchaos
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Yeni davranış: aşırı yükte `503 {"error":"overloaded"}` + `Retry-After`. Bu bir arıza değil bir
**karardır** — sunucu, kabul ettiği isteklere hızlı cevap verebilmek için fazlasını erken reddediyor.

## 6. Reproduce edilebilir sorunlar

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

**Belirti:** %30 hata oranında, bütçesiz "3 deneme" bağımlılık çağrılarını katlar — tam da
bağımlılık zaten hata verirken.
**Neden:** Retry bir **kurtarma** aracıdır, bir kapasite aracı değil. Bütçe olmadan, arızanın
hızlandırıcısına dönüşür. [Topic · Konu: Retry amplification, backoff, jitter]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P10-01` (`pg-loss-30` altında aynı yükü önce bütçeli retry'la, sonra
`TRAP_NAIVE_RETRY` ile verir; iki fazın Postgres çağrı ve retry sayısını karşılaştırır, sonra arızayı ve tuzağı geri alır).

Elle — `10-resilience` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, Postgres'e %30 paket kaybı enjekte et:
```bash
make fresh
make chaos C=pg-loss-30
sleep 5
```
2. Bütçeli retry'la (varsayılan: en fazla 2 tekrar, retry trafiğin en fazla %10'u) 45 sn yük ver, son 3 dakikadaki
   Postgres çağrısı ve retry sayısını oku:
```bash
make load S=mixed K6_ARGS="--vus 25 --duration 45s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(dependency_requests_total{namespace="lvl10",dep="postgres"}[3m]))' | jq -r '"postgres çağrısı: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(retry_total{namespace="lvl10",dep="postgres"}[3m]))' | jq -r '"retry: " + .data.result[0].value[1]'
```
3. Tuzağı aç (3 deneme, bütçe ve jitter yok; redirect pod'ları yeniden başlar), aynı yükü ver, aynı iki sayıyı oku:
```bash
make set E="TRAP_NAIVE_RETRY=true" W=redirect
make load S=mixed K6_ARGS="--vus 25 --duration 45s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(dependency_requests_total{namespace="lvl10",dep="postgres"}[3m]))' | jq -r '"postgres çağrısı: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(retry_total{namespace="lvl10",dep="postgres"}[3m]))' | jq -r '"retry: " + .data.result[0].value[1]'
```
4. Arızayı kaldır, tuzağı kapat:
```bash
make unchaos
make reset
```

**Terminalde ne görmelisin:** `make chaos` `networkchaos.chaos-mesh.org/pg-loss-30 created` basar; her yükün k6
çıktısının sonunda bir özet satırı var: `k6 lvl10: reqs=… failed=…% 5xx=… …`. 2. adımda `retry`, `postgres çağrısı`nın
en fazla ~%10'u kadardır: bütçe retry'ı sınırlıyor. 3. adımda aynı yükle iki sayı da büyür — `retry` belirgin artar,
`postgres çağrısı` 2. adımdakini geçer: bir kullanıcı isteği birden çok bağımlılık çağrısına dönüşüyor, tam da bağımlılık
hata verirken. (Pencere 3 dakika olduğu için 3. adımın sayısı 2. adımın kuyruğunu da biraz içerir; script de aynı
pencereyle ölçer.)

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; `pg-loss-30` altında iki faz 45'er sn, arada redirect rollout'u (giriş: admin / ladder)
- "Yeniden deneme / sn" → `postgres` çizgisi birinci fazda (bütçeli) alçak kalır — bütçe, retry'ı trafiğin en fazla %10'uyla sınırlıyor; ikinci fazda (`TRAP_NAIVE_RETRY`) **belirgin** yükselir.
- "Bağımlılık hatası / sn" → `postgres` çizgisi kayıp boyunca iki fazda da sıfırın üstünde: retry'ların üstüne bindiği arıza bu. Zaman aşımına düşen denemeler bu panelde değil, `result="timeout"` serisinde sayılır.
- Explore'da: `sum(rate(dependency_requests_total{namespace="lvl10",dep="postgres"}[1m]))` → aynı k6 yüküyle ikinci fazda daha yüksek: bir kullanıcı isteği birden çok bağımlılık çağrısına dönüşüyor — script'in karşılaştırdığı sayı bu.

**Üçü birlikte olmalı:** üstel geri çekilme + **jitter** + **bütçe**. Jitter'sız retry'lar
senkronize olur (P03-07'deki TTL hizalanmasıyla aynı fizik); bütçesiz retry ikinci bir yük
kaynağıdır.
**Korumanın kendisi de sınanır:** bütçeyi harcayan `retCount++` satırı olmasa bütçe her zaman
"boş" görünür ve retry sınırsız kalır — kod derlenir, koruma "var" görünür. Bunu
`TestRetryBudgetCapsAmplification` birim testi yakalar.
*Bir korumanın var olması ile çalışıyor olması ayrı şeylerdir.*

---

### P10-02 · TRAP · Readiness'ın bağımlılığa bakması (ikinci kez)

**Belirti:** Redis 10 saniye kesildiğinde hazır endpoint sayısı **sıfıra** iner.
**Neden:** P02-10'un kardeşi, yeni bağımlılıkla. Fail-open sayesinde hizmet **çalışır** (DB'ye
düşülür) ama readiness Redis'e bakıyorsa tüm pod'lar aynı anda düşer.
[Topic · Konu: Probe semantiği, kaskad]

**Reproduce (adım adım):**

Otomatik: `CONFIRM=1 make repro P=P10-02` — yük altında Redis'i iki kez ~40 sn durdurur (önce varsayılan readiness'la,
sonra `TRAP_READY_CHECKS_REDIS` ile); her fazda en düşük hazır endpoint sayısını, k6'nın 5xx sayısını ve `no_cache`
degrade tepesini ölçer, sonunda Redis'i ve tuzağı geri alır.

Elle — sırayla yapıştır. **Dikkat:** 3. ve 7. adım Redis'i durdurur (önbellek ve paylaşılan hız sınırlayıcı ~40 sn
yok); aynı bloğun son iki satırı onu geri getirir, bloğu yarıda kesme.

1. Grafana'yı temizle, redirect servisinin hazır pod adresi sayısına bak:
```bash
make fresh
kubectl -n lvl10 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' | grep -c true
```
2. İKİNCİ bir terminalde `10-resilience` klasöründe 90 sn yük başlat:
```bash
make load S=redirect K6_ARGS="--vus 10 --duration 90s"
```
3. Yük başladıktan ~12 sn sonra İLK terminalde Redis'i durdur, 40 sn boyunca 2 sn'de bir hazır adres sayısını bas,
   Redis'i geri getir:
```bash
kubectl -n lvl10 scale statefulset redis --replicas=0
for i in $(seq 1 20); do kubectl -n lvl10 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' | grep -c true; sleep 2; done
kubectl -n lvl10 scale statefulset redis --replicas=1
kubectl -n lvl10 rollout status statefulset/redis --timeout=180s
```
4. İkinci terminaldeki yük bitince (k6 çıktısının sonundaki özet satırı `k6 lvl10: …`) kesinti sırasında Redis
   devresinin açılıp açılmadığına bak:
```bash
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(max(degraded_mode{namespace="lvl10",mode="no_cache"})[2m:10s])' | jq -r '"no_cache tepe: " + .data.result[0].value[1]'
```
5. Tuzağı aç (readiness Redis'e ping atar; redirect pod'ları yeniden başlar):
```bash
make set E="TRAP_READY_CHECKS_REDIS=true" W=redirect
```
6. İKİNCİ terminalde yükü yeniden başlat:
```bash
make load S=redirect K6_ARGS="--vus 10 --duration 90s"
```
7. ~12 sn sonra İLK terminalde aynı kesintiyi tekrarla:
```bash
kubectl -n lvl10 scale statefulset redis --replicas=0
for i in $(seq 1 20); do kubectl -n lvl10 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' | grep -c true; sleep 2; done
kubectl -n lvl10 scale statefulset redis --replicas=1
kubectl -n lvl10 rollout status statefulset/redis --timeout=180s
```
8. Yük bitince tuzağı kapat:
```bash
make reset
```

**Terminalde ne görmelisin:** 1. adımda redirect'in hazır pod sayısı (manifest'te 2; HPA ölçeklediyse daha fazla).
Varsayılan fazda Redis dururken döngü hep aynı sayıyı basar, ikinci terminaldeki özet satırında `5xx` sıfır ya da sıfıra
yakındır ve 4. adım `no_cache tepe: 1` der: Redis devresi açıldı, okumalar önbelleği atlayıp DB'den cevaplandı — pod
trafik almaya devam etti. Tuzaklı fazda döngü birkaç saniye içinde `0` basmaya başlar ve Redis dönene kadar `0`'da kalır;
özet satırında `5xx` sıfırdan büyüktür (ingress'in gönderecek hazır pod'u yok → 503). Redis dönünce sayı bütün pod'larla
**aynı anda** eski değerine çıkar.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; iki faz 90'ar sn, Redis her fazda ~40 sn durur (giriş: admin / ladder)
- "Hazır pod adresi (endpoint) sayısı" → `redirect-…` çizgisine bak. Birinci fazda Redis dururken **düz** kalır; ikinci fazda (`TRAP_READY_CHECKS_REDIS`) **0'a** iner ve Redis dönünce bütün pod'larla **aynı anda** geri gelir. (Aynı metrik `01 · Pods & Resources` → "Hazır pod adresi (endpoint) sayısı" panelinde de var.)
- "Azaltılmış mod (degrade)" → birinci fazda Redis durunca `no_cache` **1'e çıkar**: Redis guard'ının devresi açıldı, önbellek atlanıyor ve okumalar DB'den cevaplanıyor. Redis dönünce ilk başarılı çağrıyla 0'a iner. Bağımlılığın durumu burada, bir METRİKTE görünüyor — pod ise trafik almaya devam ediyor. İkinci fazda da kısa bir süre 1 olabilir; ama pod'lar zaten trafikten düşmüştür.
- "Dönen durum kodları" (k6) → birinci fazda `302` kesintisiz sürer; ikinci fazda Redis kesintisi boyunca `503` (ingress: gönderilecek hazır pod yok). Bkz. [Grafana'yı okumak](../README.md#grafanayı-okumak).

**En sinsi tarafı:** bağımlılık **döndüğünde** tüm pod'lar aynı anda geri gelir ve onu ikinci kez
devirir — kurtarma da senkronize olur.
**Doğrusu kodda:** Redis kendi guard'ının arkasında; kesinti onun devresini açar ve `no_cache`
degrade modunu işaretler. Tepki pod'u öldürmek değil, önbelleksiz hizmet vermektir.
*Readiness "ben trafik alabilir miyim?" sorusudur. "Bağımlılığım iyi mi?" sorusunun cevabı bir
metriktir ve tepkisi degrade mod ya da devre kesicidir.*

---

### P10-03 · Timeout hizasızlığı

**Belirti:** Client 1 sn sonra vazgeçer; sunucu 30 sn daha çalışır ve cevabı kimseye teslim edemez.
**Neden:** Timeout bütçesi bir **zincirdir**: her katman, kendisini çağıranın kalan süresinden az
beklemeli. `handler > bağımlılık ≥ sorgu`. [Topic · Konu: Timeout bütçesi]

**Reproduce (adım adım):**

Otomatik: `make repro P=P10-03` — redirect'in timeout zincirini (handler / bağımlılık / sorgu) basar, `pg-delay-2s`
altında 45 sn yük verir; tepe in-flight, tepe goroutine, Postgres çağrı p99'u, bağımlılık timeout'u ve bulkhead reddini
ölçer, sonra arızayı kaldırır.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, redirect'in timeout zincirine bak (manifest'te olanlar ve kodun varsayılanları):
```bash
make fresh
make env W=redirect | grep TIMEOUT
grep -nE '"(HANDLER_TIMEOUT|DEP_TIMEOUT|DB_QUERY_TIMEOUT)"' internal/config/config.go
```
2. Postgres'e 2 sn gecikme enjekte et, scriptin verdiği yükü ver:
```bash
make chaos C=pg-delay-2s
sleep 5
make load S=mixed K6_ARGS="--vus 30 --duration 45s -e K6_TIMEOUT=1s"
sleep 10
```
3. Sunucunun ne kadar iş taşıdığını ve korumaların tetiklenip tetiklenmediğini oku:
```bash
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(http_in_flight_requests{namespace="lvl10"})[3m:15s])' | jq -r '"tepe in-flight: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(go_goroutines{namespace="lvl10",pod=~"redirect.*"})[3m:15s])' | jq -r '"tepe goroutine: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace="lvl10",dep="postgres"}[2m])) by (le))' | jq -r '"postgres çağrı p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (result) (increase(dependency_requests_total{namespace="lvl10",dep="postgres",result=~"timeout|bulkhead"}[3m]))' | jq -r '.data.result[] | "\(.metric.result): \(.value[1])"'
```
4. Arızayı kaldır:
```bash
make unchaos
```

**Terminalde ne görmelisin:** 1. adımda manifest yalnızca `DEP_TIMEOUT=2s` verir; `config.go` satırları diğer ikisinin
varsayılanını gösterir: `HANDLER_TIMEOUT` 5 sn, `DB_QUERY_TIMEOUT` 3 sn (script bunu `handler=5s · bağımlılık=2s ·
sorgu=3s` diye basar). Yükün özet satırında `failed=` yüksek, `5xx` sıfırdan büyük. 3. adımda Postgres çağrı p99'u
2–2,5 sn bandında (bağımlılık timeout'u 2 sn'de kesiyor, histogram kovası 2,5 sn'de), `timeout` ve/veya `bulkhead`
satırları sıfırdan büyük: yavaş bağımlılık kendisine ayrılan eşzamanlılıkla sınırlandı — scriptin REPRODUCED koşulu bu.
Tepe in-flight ve goroutine, gecikme varken taşınan işin büyüklüğü.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; `pg-delay-2s` altında yük 45 sn sürer (giriş: admin / ladder)
- "Başarısız oran (zaman içinde)" (k6) → yük boyunca yüksek: client her isteği 1 sn'de bırakıp gidiyor.
- "Şu an işlenen istek (pod'a göre)" → aynı anda **yükselir**: client'ın bıraktığı istekleri sunucu hâlâ taşıyor. İki panel arasındaki fark, kimseye teslim edilmeyecek iştir.
- "Bağımlılık gecikmesi p99" → `postgres` tavan yapar ve orada düzleşir: bağımlılık timeout'u (2 sn) çağrıyı kesiyor. Histogram kovası 2,5 sn'de olduğu için çizgi 2–2,5 sn bandında görünür.
- Explore'da: `sum(rate(dependency_requests_total{namespace="lvl10",dep="postgres",result=~"timeout|bulkhead"}[1m])) by (result)` → `timeout` ve `bulkhead` serileri yükte sıfırdan ayrılır: koruma çalışıyor, yavaş bağımlılık kendisine ayrılan eşzamanlılıkla sınırlı kalıyor. Script'in REPRODUCED koşulu tam bu.

**Eksik kalan halka:** sunucu tarafı `statement_timeout` (P02-06). Client vazgeçse bile Postgres
sorguyu durdurmaz — *bunu yalnızca DB'nin kendisi yapabilir.*

---

### P10-04 · TRAP · Devre kesici: açılma, deneme, flapping

**Belirti:** Devre kesici kapalıyken (`TRAP_NO_BREAKER`) her istek bozuk bağımlılığa gider ve
p99 tavan yapar; açıkken istekler hızlıca reddedilir.
**Neden:** Devre kesicinin işi bağımlılığı **kurtarmak** değil, ona ve sana nefes aldırmaktır.
[Topic · Konu: Circuit breaker, yanlış pozitif]

**Reproduce (adım adım):**

Otomatik: `make repro P=P10-04` — `pg-loss-50` altında aynı yükü önce devre kesiciyle, sonra `TRAP_NO_BREAKER` ile verir;
her fazın kendi zaman penceresinde bozuk bağımlılığa **ulaşan** çağrıyı (toplam − devre-açık reddi), istek sayısını ve
p99'u ölçer, oranları karşılaştırır ve tepe devre durumunu basar.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, Postgres'e %50 paket kaybı enjekte et:
```bash
make fresh
make chaos C=pg-loss-50
sleep 5
```
2. Devre kesici açıkken (varsayılan) 50 sn yük ver; bu fazın penceresinde Postgres çağrılarını sonuca göre, tepe devre
   durumunu ve tepe p99'u oku:
```bash
t0=$(date +%s)
make load S=mixed K6_ARGS="--vus 25 --duration 50s"
sleep 20
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum by (result) (increase(dependency_requests_total{namespace='lvl10',dep='postgres'}[${w}s]))" | jq -r '.data.result[] | "\(.metric.result): \(.value[1])"'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(max(breaker_state{namespace='lvl10',dep='postgres'})[${w}s:15s])" | jq -r '"tepe devre durumu: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace='lvl10'}[30s])) by (le))[${w}s:15s])" | jq -r '"tepe p99 (sn): " + .data.result[0].value[1]'
```
3. Devre kesiciyi kapat (redirect pod'ları yeniden başlar), aynı yükü ver, aynı üç ölçümü al:
```bash
make set E="TRAP_NO_BREAKER=true" W=redirect
t0=$(date +%s)
make load S=mixed K6_ARGS="--vus 25 --duration 50s"
sleep 20
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum by (result) (increase(dependency_requests_total{namespace='lvl10',dep='postgres'}[${w}s]))" | jq -r '.data.result[] | "\(.metric.result): \(.value[1])"'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(max(breaker_state{namespace='lvl10',dep='postgres'})[${w}s:15s])" | jq -r '"tepe devre durumu: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace='lvl10'}[30s])) by (le))[${w}s:15s])" | jq -r '"tepe p99 (sn): " + .data.result[0].value[1]'
```
4. Arızayı kaldır, devre kesiciyi geri aç:
```bash
make unchaos
make reset
```

**Terminalde ne görmelisin:** sonuç satırları `ok`, `error`, `timeout`, `bulkhead`, `open`. 2. adımda `open` büyüktür:
bağımlılığa **hiç gitmeden** hızlıca reddedilen çağrılar; `tepe devre durumu: 2` (açık). Bozuk bağımlılığa ulaşan çağrı
= `open` dışındakilerin toplamı; bunu yükün özet satırındaki `reqs=` ile oranla. 3. adımda `open` `0`, `tepe devre durumu:
0`: her istek bozuk bağımlılığa gidiyor, ulaşan/istek oranı 2. adımdakinden büyük ve tepe p99 belirgin yüksek — yavaş
hata, hızlı hatadan kötü. Scriptin hükmü bu iki farka bakar.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl10&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; `pg-loss-50` altında iki faz ~70'er sn, arada redirect rollout'u (giriş: admin / ladder)
- "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" → birinci fazda `postgres` 0'dan **2'ye** çıkar ve 2 / 1 / 0 arasında gidip gelir (5 sn açık → yarı açık deneme → yine açık): testere dişi = flapping. Uygulama metrikleri 10 sn'de bir kazındığı için 5 sn'lik dişler düzensiz görünür. İkinci fazda (`TRAP_NO_BREAKER`) **düz 0**: devre hiç açılmıyor.
- "Azaltılmış mod (degrade)" → birinci fazda devre açıkken `cache_only` 1'e çıkar: önbellek isabetleri DB'ye hiç gitmeden cevaplanmaya devam ediyor, yalnızca ıskalar hızlıca 503 alıyor (Postgres guard'ı önbelleğin altında). İkinci fazda 0.
- "Gecikme (p50 / p95 / p99)" (App RED) → ikinci fazda p99 belirgin yükselir: her istek bozuk bağımlılığı bekliyor. Birinci fazda açık devre hızlı reddettiği için daha alçak.
- Explore'da: `sum(rate(dependency_requests_total{namespace="lvl10",dep="postgres",result="open"}[1m]))` → yalnızca birinci fazda sıfırdan ayrılır: DB'ye **hiç gitmeden** reddedilen çağrılar (script'in "devre-açık reddi").

**Ayar riski:** çok hassas → sağlıklı bağımlılığı bozuk ilan eder; çok tembel → arızayı fark etmez.
**Kritik ayrıntı (kodda):** `ErrNotFound` devre kesiciyi **tetiklemez**. 404 bir arıza değildir;
bunu ayırt etmemek, çok sayıda 404'ün sağlıklı bir bağımlılığı "bozuk" ilan etmesine yol açar —
en sık yapılan devre kesici hatası.
*Yavaş hata, hızlı hatadan kötüdür.*

---

### P10-05 · TRAP · Yavaş bağımlılık, ölüden beterdir

**Belirti:** Redis 3 sn gecikirse (ölmedi, yavaşladı) timeout'suz modda istekler birikir: goroutine,
in-flight ve bellek şişer.
**Neden:** Ölü bağımlılık hızlı hata verir; yavaş olan her isteği bekletir. **Timeout'suz bir
çağrı, sınırsız bir kuyruktur** (P05-02'nin bağımlılık hâli). Üstelik timeout yoksa devre kesici de
kördür: 3 sn'de gelen bir cevap **başarılıdır**, hata sayılmaz.
[Topic · Konu: Kaynak sızıntısı, timeout]

**Reproduce (adım adım):**

Otomatik: `make repro P=P10-05` — `redis-delay-3s` altında timeout'lu/timeout'suz goroutine,
in-flight, bellek ve Redis çağrı süresini karşılaştırır. `TRAP_NO_DEP_TIMEOUT` hem guard'ların
timeout'unu hem de **Redis istemcisinin kendi** 500 ms'lik soket süre sınırlarını kaldırır.
(Yalnızca guard'ınkini kaldırmak yetmez: istemcinin 500 ms'si her çağrıyı iki fazda da keser ve
"timeout'suz" yol hiç sınanmaz. Timeout, süre sınırının **uygulandığı** yerdedir.)

Elle — sırayla yapıştır:

1. Grafana'yı temizle, Redis'e 3 sn gecikme enjekte et (ölmedi, yavaşladı):
```bash
make fresh
make chaos C=redis-delay-3s
sleep 5
```
2. Timeout varken (varsayılan) 45 sn yük ver; bu fazın penceresinde tepe goroutine, tepe in-flight, Redis çağrı p99'u
   ve kesilen/devre-açık Redis çağrısı sayısını oku:
```bash
t0=$(date +%s)
make load S=redirect K6_ARGS="--vus 30 --duration 45s"
sleep 15
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(sum(go_goroutines{namespace='lvl10',pod=~'redirect.*'})[${w}s:10s])" | jq -r '"tepe goroutine: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(sum(http_in_flight_requests{namespace='lvl10',pod=~'redirect.*'})[${w}s:10s])" | jq -r '"tepe in-flight: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace='lvl10',dep='redis'}[${w}s])) by (le))" | jq -r '"redis çağrı p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(dependency_requests_total{namespace='lvl10',dep='redis',result=~'timeout|open'}[${w}s]))" | jq -r '"kesilen/devre-açık redis çağrısı: " + .data.result[0].value[1]'
```
3. Süre sınırlarını kaldır (guard'ınki ve Redis istemcisininki; redirect pod'ları yeniden başlar), aynı yükü ver, aynı
   dört ölçümü al:
```bash
make set E="TRAP_NO_DEP_TIMEOUT=true" W=redirect
t0=$(date +%s)
make load S=redirect K6_ARGS="--vus 30 --duration 45s"
sleep 15
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(sum(go_goroutines{namespace='lvl10',pod=~'redirect.*'})[${w}s:10s])" | jq -r '"tepe goroutine: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(sum(http_in_flight_requests{namespace='lvl10',pod=~'redirect.*'})[${w}s:10s])" | jq -r '"tepe in-flight: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace='lvl10',dep='redis'}[${w}s])) by (le))" | jq -r '"redis çağrı p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(dependency_requests_total{namespace='lvl10',dep='redis',result=~'timeout|open'}[${w}s]))" | jq -r '"kesilen/devre-açık redis çağrısı: " + .data.result[0].value[1]'
```
4. Arızayı kaldır, süre sınırlarını geri getir:
```bash
make unchaos
make reset
```

**Terminalde ne görmelisin:** 2. adımda Redis çağrı p99'u 1 sn'nin altında (çağrılar istemcinin 500 ms'sinde kesiliyor)
ve kesilen/devre-açık çağrı sayısı sıfırdan büyük: timeout'lar hata sayıldı, Redis devresi açıldı, istekler önbelleği
atlayıp DB'den hızlıca döndü — ölü bir bağımlılık gibi. 3. adımda Redis çağrı p99'u 1 sn'nin çok üstüne çıkar (çağrılar
~3 sn sürüyor ve **başarıyla** bitiyor), kesilen/devre-açık sayısı sıfıra yakın (devre kesici yavaşlığı hata saymaz) ve
tepe goroutine ile tepe in-flight 2. adımdakinden yüksek: bekleyen her çağrı bir goroutine ve bir istek tutuyor. Scriptin
hükmü goroutine artışına bakar; Redis p99'u uzamadıysa tuzak etkili olmamıştır ve script hüküm vermez.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl10&from=now-15m&to=now&refresh=10s) ve [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; `redis-delay-3s` altında iki faz 45'er sn, arada redirect rollout'u (giriş: admin / ladder)
- "Goroutine sayısı" → `redirect-…` pod'larına bak: ikinci fazda (`TRAP_NO_DEP_TIMEOUT`) tepe, birinci fazdakinden yüksek. Timeout'suz her bekleyen çağrı bir goroutine tutuyor.
- "Bağımlılık gecikmesi p99" (Resilience) → `redis` çizgisi birinci fazda ~0,5 sn'de (istemci timeout'u) düzleşir; ikinci fazda **~3 sn'ye** çıkar: çağrılar kesilmiyor, sonuna kadar bekleniyor. `postgres` çizgisi iki fazda da alçak.
- "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" (Resilience) → `redis` birinci fazda 2'ye çıkar (timeout'lar hata sayılıyor, devre açılıyor, istekler önbelleği atlayıp DB'den dönüyor); ikinci fazda **0'da kalır**: yavaş cevap hata değil.
- "Şu an işlenen istek (pod'a göre)" (Resilience) → ikinci fazda belirgin yüksek: istekler bitmiyor, birikiyor. Birikimi sınırlayan artık yalnızca bulkhead (pod başına `DEP_MAX_CONCURRENT` eşzamanlı Redis çağrısı) ve istemcinin sabrı.
- "Bellek kullanımı" → aynı pod'larda goroutine'lerle aynı yönde: bekleyen her çağrı yığınıyla birlikte bellekte duruyor.

**Kural:** Bir bağımlılığa yapılan **her** çağrının süre sınırı olmalı. *"Genelde hızlıdır" bir
gerekçe değildir; sorun tam da "genelde" olmadığı anda başlar.*

---

### P10-06 · Yük atma: kabul ettiğini hızlı tut

**Belirti/Beklenti:** Shedding açıkken **kabul edilen** isteklerin p99'u korunur; kapalıyken herkes
yavaşlar.
**Neden:** Aşırı yüklü bir sunucu her şeyi kabul edip her şeyi yavaş servis ederse, herkes zaman
aşımına uğrar ve kimse cevap alamaz. [Topic · Konu: Load shedding, admission control]

**Reproduce (adım adım):**

Otomatik: `make repro P=P10-06` — `redis-delay-200ms` altında (istekler sürsün, in-flight birikebilsin diye) `stairs`
yüküyle shedding açık (eşik 40) / kapalı, **kabul edilen** isteklerin p99'unu karşılaştırır. Bu, uygulamanın kendi
histogramıdır: shedder metrik katmanının önünde durduğu için attığı 503'ler oraya hiç girmez. (`code!="503"` gibi bir
süzgeç burada hiçbir şey süzmez — histogramda `code` etiketi yok, yalnızca `route`.) Hiçbir istek atılmadıysa hüküm
vermez (çıkış 2).

Elle — sırayla yapıştır:

1. Grafana'yı temizle, Redis'e 200 ms gecikme enjekte et, yük atma eşiğini pod başına 40 eşzamanlı isteğe çek (redirect
   pod'ları yeniden başlar):
```bash
make fresh
make chaos C=redis-delay-200ms
make set E="SHED_ENABLED=true SHED_MAX_INFLIGHT=40" W=redirect
```
2. Merdiven yükünü ver (50 → 100 → 200 → 400 istek/sn, ~3 dk), bu fazın penceresinde atılan istek sayısını ve kabul
   edilenlerin tepe p99'unu oku:
```bash
t0=$(date +%s)
make load S=stairs
sleep 20
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(load_shed_total{namespace='lvl10'}[${w}s]))" | jq -r '"atılan: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace='lvl10'}[30s])) by (le))[${w}s:10s])" | jq -r '"kabul edilenlerin tepe p99 (sn): " + .data.result[0].value[1]'
```
3. Yük atmayı kapat (her şey kabul edilir), aynı yükü ver, aynı iki ölçümü al:
```bash
make set E="SHED_ENABLED=false" W=redirect
t0=$(date +%s)
make load S=stairs
sleep 20
w=$(( $(date +%s) - t0 ))
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(load_shed_total{namespace='lvl10'}[${w}s]))" | jq -r '"atılan: " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace='lvl10'}[30s])) by (le))[${w}s:10s])" | jq -r '"kabul edilenlerin tepe p99 (sn): " + .data.result[0].value[1]'
```
4. İstersen: 2. adımda `atılan: 0` çıktıysa sistem doymadı — yük atmayı yeniden aç ve merdiveni yükselt (özet
   satırında `5xx` sıfırdan büyükse bu kez yük atıldı):
```bash
make set E="SHED_ENABLED=true SHED_MAX_INFLIGHT=40" W=redirect
RATES=100,200,400,800 make load S=stairs
```
5. Arızayı kaldır, eşikleri manifest'teki hâline döndür:
```bash
make unchaos
make reset
```

**Terminalde ne görmelisin:** 2. adımda `atılan` sıfırdan büyük ve yükün özet satırında `5xx` sıfırdan büyük: bunlar
hızlı `503 {"error":"overloaded"}` cevapları. 3. adımda `atılan: 0`, özet satırında 503 yok ama kabul edilenlerin tepe
p99'u 2. adımdakinden yüksek: her şey kabul edildiği için herkes yavaşladı. Scriptin hükmü bu: yük atma açıkken kabul
edilenlerin p99'u ≤ kapalıyken. 2. adımda hiçbir istek atılmadıysa (Redis'in bulkhead'i doygunluğu shedder'dan önce
karşılamış olabilir) karşılaştırma yük atma hakkında değildir — 4. adımı dene.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-30m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl10&from=now-30m&to=now&refresh=10s) — scripti başlatınca aç; `redis-delay-200ms` altında iki `stairs` fazı (~3'er dk), toplam ~8 dk (giriş: admin / ladder)
- "Atılan yük / sn" → birinci fazda (yük atma açık, eşik 40) merdivenin üst basamaklarında sıfırdan ayrılır; ikinci fazda **düz 0**.
- "Kabul edilen isteklerin p99 süresi" → birinci fazda merdiven boyunca alçak kalır; ikinci fazda basamaklarla birlikte **tırmanır**: her şey kabul edildiği için herkes yavaşlıyor.
- "Şu an işlenen istek (pod'a göre)" → birinci fazda `redirect-…` pod'ları eşik (40) civarında tavan yapar; ikinci fazda sınırsız yükselir.
- "Dönen durum kodları" (k6) → birinci fazda hızlı `503`'ler (`{"error":"overloaded"}`): atılan istekler. `02 · App RED` bu 503'leri **saymaz** — shedder uygulamanın metrik katmanının önünde duruyor; atılanları yalnızca istemci ve "Atılan yük / sn" görür. Bkz. [Grafana'yı okumak](../README.md#grafanayı-okumak).

**Dikkat — iki koruma aynı yükü paylaşıyor:** Redis kendi guard'ının arkasında. Bulkhead'i (pod
başına `DEP_MAX_CONCURRENT` eşzamanlı Redis çağrısı) dolduğunda ya da devresi açıldığında fazla
istekler önbelleği atlayıp DB'den hızlıca döner; doygunluğu bazen shedder'dan (eşik 40) **önce**
bu karşılar. Hiçbir istek atılmadıysa script hüküm vermez (çıkış 2) — o durumda ölçülen şey yük
atma değil, bulkhead'dir.

**Doğru metrik:** Toplam p99'a bakarsan shedding kötü görünür (çok 503); **kabul edilenlere**
bakarsan iyi görünür. *Hangi soruyu sorduğun, hangi cevabı alacağını belirler.*
**Sınırı:** Yük atma bir **kalite** aracıdır, kapasite aracı değil — kapasite için ölçekleme (07).
Sağlık uçları asla atılmaz (kodda ayrık): yük altında probe düşerse pod öldürülür (P01-07).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_NAIVE_RETRY` | 3 deneme, bütçe ve jitter yok | `make repro P=P10-01` | Bayrağı kapat |
| `TRAP_READY_CHECKS_REDIS` | readiness Redis'e ping atar | `CONFIRM=1 make repro P=P10-02` | Bayrağı kapat |
| `TRAP_NO_BREAKER` | Devre kesiciyi etkisizleştirir | `make repro P=P10-04` | Bayrağı kapat |
| `TRAP_NO_DEP_TIMEOUT` | Bağımlılık timeout'unu kaldırır | `make repro P=P10-05` | Bayrağı kapat |

Elle denemeye değer:
- `BREAKER_OPEN=1s` + `BREAKER_THRESHOLD=2` yap ve `pg-loss-30` uygula: **flapping** üret.
  Grafana'da "Devre kesici durumu" testere dişi olur. Sonra `BREAKER_OPEN=30s` ile karşılaştır —
  *eşik ayarı bir tahmin değil, bir ölçüm işidir.*
- `DEP_MAX_CONCURRENT=2` yap: bulkhead çok dar olunca sağlıklı bağımlılıkta bile reddetmeye başlar.
  **Korumanın kendisi bir arıza kaynağı olabilir.**
- `make chaos C=redis-kill` + `make load S=mixed`: Redis guard'ının devresi açılır ve
  `degraded_mode{mode="no_cache"}` 1 olur (önbellek atlanır, okumalar DB'den); Redis dönünce 0.
  Karşılığını `make chaos C=pg-loss-50` ile gör: bu kez Postgres devresi açılır ve `cache_only`
  1 olur — isabetler cevaplanmaya devam eder, yalnızca ıskalar 503 alır. Degrade, bağımlılık
  başınadır: hangisinin gittiğine göre farklı bir "yarım hizmet".
- İki chaos'u birlikte uygula (`pg-delay-2s` + `redis-delay-200ms`): korumalar **birlikte**
  çalıştığında toplam etkinin parçaların toplamından farklı olduğunu gör.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl10&from=now-15m&to=now) | **Dolu** ✨ | devre kesici durumu, bağımlılık gecikmesi/hatası (`postgres` ve `redis` ayrı), retry, atılan yük, in-flight, degrade modu (`cache_only` / `no_cache`) |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl10&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl10&from=now-15m&to=now) · [`01 · Pods`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl10&from=now-15m&to=now) | Dolu | Chaos deneylerinin etkisi burada okunur. `06 · Redis` → "Uygulama → Redis gecikmesi (p99)" bu seviyede **ilk kez dolu**: Redis kendi guard'ıyla (`dep="redis"`) ölçülüyor |
| [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl10&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl10&from=now-15m&to=now) | Boş | 11 ve 12'de |

Bu seviyenin panel okuma kuralı: **breaker state ile dependency latency'yi birlikte oku.**
Breaker açık ve latency düşük → koruma çalışıyor. Breaker kapalı ve latency yüksek → eşik çok tembel.
Breaker testere dişi → eşik çok hassas. Tek başına hiçbiri bir şey söylemez.

## 9. Bilerek bırakılanlar

- **Kafka korumasız**: Postgres ve Redis'in (önbellek çağrıları) kendi `Guard`'ı var; Kafka üreticisi
  zaten asenkron ve sınırlı tamponlu (P05-02), ayrı bir guard kurulmadı. Redis'e giden diğer iki
  çağrı — hız sınırlayıcı ve yapışkan okuma işareti — da guard'sız: ikisinin de kendi kısa
  timeout'u ve fail-open'ı var.
- **Degrade modu sınırlı**: `cache_only` yalnızca önbellekte olanı sunar (ıska 503 alır); DB'siz
  **yazma** yolu için bir degrade yok (create 503 döner).
- **Adaptif shedding yok**: sabit in-flight eşiği. Gerçekte gecikmeye göre uyarlanır (CoDel, PID).
- **`statement_timeout` hâlâ boş** (P02-06): client tarafı timeout var, sunucu tarafı yok.
- **Chaos deneyleri elle**: otomatik chaos (sürekli, zamanlanmış) yok — game day 14'te.
- **09'dan devreden**: nesne deposu/PITR yok, tek Redis, kimlik yok.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 09 ile farkı gösterir:

1. **`internal/resilience/breaker.go`** (yeni): tek bir `Guard` beş mekanizmayı birleştiriyor.
   Yorumlarda her birinin **ayrı sorusu** yazıyor — birbirinin yerine geçmedikleri buradan okunur.
2. **`internal/resilience/shed.go`**: sağlık uçlarının atlanması 5 satır. *Bir korumanın hangi
   isteği kapsamadığını yazmak, kapsadığını yazmak kadar önemlidir.*
3. **`internal/store/guarded.go`**: aynı `Store` arayüzünün **dördüncü** sarmalaması
   (Cached → ReadWrite → Guarded → Postgres). Her katman diğerini bilmiyor — bu yüzden herhangi
   birini kapatıp ne satın aldığını ölçebiliyoruz. `GuardCall` aynı korumayı Redis'e de
   uyguluyor (`cache.Config.Guard`): her bağımlılığa kendi devresi, kendi degrade modu.
4. **`Guarded.Get` içindeki `ErrNotFound` ayrımı**: üç satır, ama olmadan devre kesici 404'lerle
   açılırdı.
5. **`Guarded.Ping` devre kesiciden geçmiyor**: sağlık kontrolleri ham gerçeği görmeli.
6. **`deploy/*-svc.yaml`**: sekiz yeni env değişkeni. Her biri bir **karar**, her karar bir takas —
   ve hepsi `make repro` ile ölçülebilir.
