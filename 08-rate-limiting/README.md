# 08 — rate-limiting · "Gürültülü komşu"

> **Bu seviyede ne yaşayacaksın?**
> - Hız sınırının Redis'teki paylaşılan bir sayaca taşınması: limit artık replika sayısından bağımsız (P01-05 → P02-04 borcu kapanır)
> - Limiter'ın kendi bağımlılığı: Redis ölünce istekler geçsin mi, reddedilsin mi? (P08-01); her isteğe iki ağ çağrısı (P08-02)
> - Tuzak: `X-Forwarded-For`'u yanlış okumanın iki yolu — başlığı yazan herkesin limiti aşması ya da bütün istemcilerin tek IP sanılması (P08-03)
> - Sabit pencere sınırında 2× burst (P08-04); tuzak: global anahtarın Redis hot key olması (P08-05); gürültülü komşunun gerçekten izole edilip edilmediği (P08-06)
>
> **Bu seviye olmasa ne olur?** Süreç içi limit N replikada N katına çıkar ve tek bir kiracı herkesi yavaşlatır.
>
> **Yeni gelen teknolojiler:** Redis üzerinde Lua ile atomik sayaç, kiracı + IP anahtarları, ingress-nginx `limit-rps`, `10 · Rate limit` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Hız sınırı süreç belleğinden Redis'e taşındı: tek bir Lua betiğiyle atomik olarak güncellenen, bütün pod'ların
paylaştığı bir sayaç. İki anahtar var — **kiracı** ve **IP** — ve ingress'te kaba bir ilk hat. Bedeli: her isteğe iki
ağ çağrısı ve limiter'ın kendi bağımlılığı.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I["ingress<br/>limit-rps: 400<br/>(kaba ilk hat)"]
  I --> RS & AS
  subgraph RS["redirect-svc × N"]
    M["middleware:<br/>tenant → IP"]
  end
  subgraph AS["api-svc × 2"]
    M2["aynı middleware"]
  end
  M & M2 -->|"EVALSHA (atomik)"| R[("redis<br/>rl:tenant:* · rl:ip:*")]
  RS --> R
```

Katmanlı: ingress kaba (yalnızca IP'yi bilir), uygulama ince (kiracıyı, ucu bilir). Tek katman ya çok gevşek ya çok sıkı olur.

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P07-06 | N+1: liste maliyeti sonuç kümesiyle orantılı | **Çözülmüş sayılmaz:** `TRAP_` alıştırması, tuzak 08'de de duruyor; bu yüzden `SOLVES`'ta yok. Kalıcı çözüm 14'te |

Asıl kapanan borç üç seviyedir taşınan süreç içi limit (P01-05, P02-04, 07'de iki serviste ayrı); `SOLVES` yalnızca
bir önceki seviyeyi kapsadığı için orada görünmez.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/08-rate-limiting"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl08.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl08.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl08 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P08-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

Redis'teki limit anahtarlarını (kovaları) görmek için:
```bash
cd "$LADDER/08-rate-limiting"
kubectl -n lvl08 exec -it $(kubectl -n lvl08 get pod -l app.kubernetes.io/name=redis -o name) -c redis -- redis-cli --scan --pattern 'rl:*' | head
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl08 ayakta` yazar:
```bash
cd "$LADDER/07-services-autoscaling"
make down
cd "$LADDER/08-rate-limiting"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/08-rate-limiting"
make up
```
2. 07'nin sorunlarını burada koş (sekiz script, uzun sürer; koşarken başka komut çalıştırma). 08, 07'nin
   sorunlarından hiçbirini çözmüyor (`problems/SOLVES` gerekçe satırı taşır, bkz. §3); bu yüzden `BEKLENEN` sütununda
   `NOT-REPRODUCED` isteyen satır yok. `CONFIRM=1` isteyen P07-07 (düğüm dondurma) `SKIPPED` görünür:
```bash
cd "$LADDER/08-rate-limiting"
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P08-01 → P08-06): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç. Bu seviyedeki yük komutları `LIMITS_ENFORCED=1` ile başlar:
   deneyler limiter'ı sınadığı için k6 muafiyet jetonu olmadan herkese açık girişten gider.
4. Bitince ayarları geri al ve seviyeyi kapat:
```bash
cd "$LADDER/08-rate-limiting"
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Yeni yanıt başlıkları: `429`'da `Retry-After`, `X-RateLimit-Limit` ve `X-RateLimit-Scope` (`ip` mi `tenant` mı
reddetti). "Ne zaman tekrar dene" demeyen bir limit istemciyi daha sık denemeye iter.

## 6. Reproduce edilebilir sorunlar

Her sorun aynı düzende: **Ne deniyoruz** (deneyin sorusu) → **Neden** → adımlar (her adım ne yaptığını söyler)
→ **Terminalde ne görmelisin** → **Grafana'da gör** (giriş: admin / ladder) → **Nerede çözülüyor**.
`make repro` hükmü: `REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` = ölçülemedi.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P08-01 | Limiter'ın kendi bağımlılığı: fail-open mı closed mı | `CONFIRM=1 make repro P=P08-01` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Sınırlayıcı arka uç hatası / sn" | karar + alarm (11) |
| P08-02 | Her isteğe +2 Redis gidiş-gelişi | `make repro P=P08-02` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Kararlar (anahtar türüne göre)" | seviye içi (pipeline) |
| P08-03 | **TRAP** XFF: adaletsiz mi, etkisiz mi? | `make repro P=P08-03` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Kararlar (anahtar türüne göre)" | seviye içi |
| P08-04 | Sabit pencere sınırında 2× burst | `make repro P=P08-04` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Kararlar (anahtar türüne göre)" | seviye içi (kayan pencere) |
| P08-05 | **TRAP** global anahtar = Redis hot key | `make repro P=P08-05` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Redis CPU" | seviye içi (parçalama) |
| P08-06 | Gürültülü komşu izole ediliyor mu? | `make repro P=P08-06` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Normal ve kötü niyetli kullanıcının gecikmesi (k6)" | 13 (tier kotaları) |

---

### P08-01 · Limiter'ın kendi bağımlılığı

**Ne deniyoruz:** Redis durunca limiter ne yapar: istekleri geçirir mi (fail-open), reddeder mi (fail-closed)?
**Neden:** Koruma paylaşılan duruma (Redis) taşındı; artık koruma da arızalanabilir. `RATE_LIMIT_FAIL_OPEN=true` ile
hizmet sürer ama koruma kalkar, `false` ile koruma sürer ama herkes reddedilir.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P08-01` (normal, fail-open ve fail-closed davranışını
sırayla ölçer: Redis'i durdurur, ayarı değiştirir, sonunda ikisini de geri alır). Elle — 2. adım Redis'i (önbellekle
birlikte) durdurur; 4. adımı atlama:

1. Temiz başla; Redis ayaktayken kötü istemciyi 30 sn koştur, reddedilen istekleri say:
```bash
cd "$LADDER/08-rate-limiting"
make fresh
LIMITS_ENFORCED=1 make load S=abuser K6_ARGS="--duration 30s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(ratelimit_decisions_total{namespace="lvl08",decision="reject"}[3m]))' | jq -r '"reddedilen: " + .data.result[0].value[1]'
```
2. Fail-open (varsayılan): Redis'i durdur, aynı kötü istemciyi koştur, limiter hatalarını say:
```bash
cd "$LADDER/08-rate-limiting"
kubectl -n lvl08 scale statefulset redis --replicas=0
sleep 12
LIMITS_ENFORCED=1 make load S=abuser K6_ARGS="--duration 30s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(ratelimit_errors_total{namespace="lvl08"}[3m]))' | jq -r '"limiter hatası: " + .data.result[0].value[1]'
```
3. Fail-closed: Redis hâlâ kapalıyken redirect'e "Redis yoksa reddet" de (pod'lar yeniden başlar), normal bir yük ver:
```bash
cd "$LADDER/08-rate-limiting"
make set E="RATE_LIMIT_FAIL_OPEN=false" W=redirect
sleep 10
LIMITS_ENFORCED=1 make load S=redirect K6_ARGS="--vus 10 --duration 25s"
```
4. Geri al: Redis'i başlat, hazır olmasını bekle, ayarı manifestteki hâline döndür:
```bash
cd "$LADDER/08-rate-limiting"
kubectl -n lvl08 scale statefulset redis --replicas=1
kubectl -n lvl08 rollout status statefulset/redis --timeout=180s
make reset
```

**Terminalde ne görmelisin:** 1. adımda k6 özetinin altındaki `normal client p99=… · sınırlanan: normal=…% kötü=…%`
satırında kötü istemcinin payı yüksek, `reddedilen` > 0: limit çalışıyor. 2. adımda aynı kötü istemci için `429=0`
(koruma kalktı) ve `5xx=0` (hizmet sürdü); `limiter hatası` > 0: her kontrol Redis'e ulaşamadı. 3. adımda `429`
neredeyse `reqs` kadar: koruma çalışıyor ama normal kullanıcılar da reddediliyor. 4. adımda `make reset`
`✔ deploy/…: ortam manifestteki hâline döndü` basar.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) — üç faz (normal, fail-open, fail-closed), ~4 dk
- "Sınırlayıcı arka uç hatası / sn" → normal fazda 0; Redis durunca sıfırın üstüne çıkar ve iki Redis'siz fazda orada kalır.
- "Reddedilen / sn" → normal fazda > 0; fail-open fazında kötü istemci koşarken **0'a düşer** (koruma kalktı); fail-closed fazında yeniden yükselir, bu kez herkes için.
- "Kararlar (anahtar türüne göre)" → fail-open fazında kararlar `allow` sayılmaya devam eder: hata panelini izlemezsen her şey normal görünür. Fail-closed fazında retler `tenant reject` (ilk kontrol kiracı).
- "429 oranı" → fail-closed fazında neredeyse %100.
- "Redis ayakta mı" → 0'a inmez, **kesilir**: exporter Redis pod'unun içinde, pod gidince ölçen de gider.

**Nerede çözülüyor:** bir karardır: fail-open **+ alarm** (korumayı kaybetmek telafi edilir, hizmeti kaybetmek
edilmez); "limiter devre dışı" alarmı 11'de SLO'lardan türer. Azaltma: pod içinde daha gevşek bir yedek limiter.

---

### P08-02 · Her isteğe iki ağ çağrısı

**Ne deniyoruz:** Limit kontrolü isteğin süresinin ne kadarını alıyor?
**Neden:** 07'de bellekteki bir map'ti (~100 ns); şimdi her istek kiracı ve IP için iki Redis çağrısı yapıyor.

**Reproduce (adım adım):** Otomatik: `make repro P=P08-02` (limit kontrolü süresini toplam istek süresiyle ve istek
başına Redis komut sayısını beklenen ~3 ile karşılaştırır: 1 önbellek + 2 limit). Elle:

1. Temiz başla; limiter'ın önünden (herkese açık giriş, jetonsuz) 20 kullanıcıyla 40 sn yük ver:
```bash
cd "$LADDER/08-rate-limiting"
make fresh
LIMITS_ENFORCED=1 make load S=redirect K6_ARGS="--vus 20 --duration 40s"
```
2. Kazıma yetişsin diye 10 sn bekle; limit kontrolü süresini, istek süresini ve istek başına Redis komutunu oku:
```bash
cd "$LADDER/08-rate-limiting"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.50, sum(rate(ratelimit_check_duration_seconds_bucket{namespace="lvl08"}[2m])) by (le))' | jq -r '"limit kontrolü p50 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(ratelimit_check_duration_seconds_bucket{namespace="lvl08"}[2m])) by (le))' | jq -r '"limit kontrolü p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace="lvl08",route="/{code}"}[2m])) by (le))' | jq -r '"istek p50 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(redis_commands_processed_total{namespace="lvl08"}[2m])) / sum(rate(http_requests_total{namespace="lvl08",route="/{code}"}[2m]))' | jq -r '"istek başına Redis komutu: " + .data.result[0].value[1]'
```

**Terminalde ne görmelisin:** `limit kontrolü p50` milisaniyenin kesri ve `istek p50`'nin ölçülebilir bir yüzdesi —
izin verilen istek bu kontrolden iki tane yapar. `istek başına Redis komutu` ~3; yük IP limitini (300 / 10 sn) aşarsa
(k6 özetinde `429=` büyükse) reddedilenler önbelleğe gitmediği için 3'ün altına düşer.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s), [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl08&from=now-15m&to=now&refresh=10s) — yük 40 sn; bittikten sonra aç
- Explore'da: `histogram_quantile(0.5, sum(rate(ratelimit_check_duration_seconds_bucket{namespace="lvl08"}[2m])) by (le))` → tek limit kontrolünün p50'si (panel yok); App RED'deki "Gecikme (p50 / p95 / p99)" panelinin `p50`'siyle karşılaştır.
- "Kararlar (anahtar türüne göre)" → her istek iki karar üretir: `tenant allow` ile `ip allow` + `ip reject` aynı hızda ilerler — iki ağ çağrısı bu iki çizgi.
- "Komut / sn" → App RED'deki "Saniyedeki istek"e böl: istek başına ~3 Redis komutu.

**Nerede çözülüyor:** seviye içi — iki kontrolü tek gidiş-gelişte yapmak (pipeline), pod'da kısa ömürlü token tamponu,
ucuz reddi ingress'e bırakmak.

---

### P08-03 · TRAP · X-Forwarded-For'u yanlış okumanın iki yolu

**Ne deniyoruz:** Limiter istemcinin adresini `X-Forwarded-For` (XFF) başlığından yanlış okursa ne olur?
**Neden:** XFF, istemcinin de yazabildiği bir listedir; güvenilir tek kısmı **senin** proxy'lerinin eklediği girdiler.

| Okuma | Sonuç |
|---|---|
| `TRAP_IGNORE_XFF` — soket adresini oku | Herkes ingress'in adresinde tek kovada: bir kötü istemci herkesi limitler → **adaletsiz** |
| `TRAP_TRUST_ANY_XFF` — ilk girdiye güven | İstemci kendi kovasını seçer → limit **etkisiz** |
| **Doğru** — sağdan `TRUSTED_PROXY_HOPS` kadar geri say | Yalnızca kendi proxy'lerinin eklediğine güvenilir |

**Reproduce (adım adım):** Otomatik: `make repro P=P08-03` (üç modu aynı `abuser` yüküyle koşar, her fazda Redis'teki IP
kovalarını ve kimin sınırlandığını ölçer). k6'nın bütün istemcileri tek makineden gelir; bu yüzden k6 güvenilir bir yük
dengeleyiciyi oynar: her istemcinin adresini XFF'e yazar (kötü `203.0.113.66`, normal `198.51.100.<n>`) ve uygulamaya
`TRUSTED_PROXY_HOPS=2` denir. Kötü istemci her isteğin önüne yeni bir sahte adres (`198.18.x.y`) ekler: doğru okuyucu
onu görmez, ilk girdiye güvenen kanar. Elle — her fazın sonunda kovaları hemen oku (kova 20 sn sonra silinir):

1. Temiz başla; redirect'e "önümde iki proxy var" de (k6 yük dengeleyiciyi, ingress ikincisini oynar; pod'lar yeniden başlar):
```bash
cd "$LADDER/08-rate-limiting"
make fresh
make set E="TRUSTED_PROXY_HOPS=2" W=redirect
sleep 10
```
2. **(0) Doğru mod:** kötü + normal istemcileri 40 sn koştur, IP kovalarını adrese göre say:
```bash
cd "$LADDER/08-rate-limiting"
LIMITS_ENFORCED=1 make load S=abuser K6_ARGS="--duration 40s"
kubectl -n lvl08 exec redis-0 -c redis -- redis-cli --scan --pattern 'rl:ip:*' | sed 's/^rl:ip://; s/:[0-9]*$//' | sort | uniq -c | sort -rn | head
```
3. **(a) `TRAP_IGNORE_XFF`:** XFF'i yok say (soket adresi), aynı yük, aynı sayım:
```bash
cd "$LADDER/08-rate-limiting"
make set E="TRAP_IGNORE_XFF=true" W=redirect
sleep 10
LIMITS_ENFORCED=1 make load S=abuser K6_ARGS="--duration 40s"
kubectl -n lvl08 exec redis-0 -c redis -- redis-cli --scan --pattern 'rl:ip:*' | sed 's/^rl:ip://; s/:[0-9]*$//' | sort | uniq -c | sort -rn | head
```
4. **(b) `TRAP_TRUST_ANY_XFF`:** ilk tuzağı kapat, XFF'in ilk girdisine güven, aynı yük; kaç ayrı kova açıldığını da say:
```bash
cd "$LADDER/08-rate-limiting"
make set E="TRAP_IGNORE_XFF=false TRAP_TRUST_ANY_XFF=true" W=redirect
sleep 10
LIMITS_ENFORCED=1 make load S=abuser K6_ARGS="--duration 40s"
kubectl -n lvl08 exec redis-0 -c redis -- redis-cli --scan --pattern 'rl:ip:*' | sed 's/^rl:ip://; s/:[0-9]*$//' | sort | uniq -c | sort -rn | head
kubectl -n lvl08 exec redis-0 -c redis -- redis-cli --scan --pattern 'rl:ip:*' | sed 's/^rl:ip://; s/:[0-9]*$//' | sort -u | wc -l
```
5. Geri al (tuzaklar kapanır, `TRUSTED_PROXY_HOPS` 1'e döner):
```bash
cd "$LADDER/08-rate-limiting"
make reset
```

**Terminalde ne görmelisin:** kova listesinde her satır `<sayı> <adres>`. (0) doğru modda kovalar ayrı:
`203.0.113.66` (kötü) ve bir sürü `198.51.100.<n>` (normal); kötü istemcinin sınırlanan payı yüksek, normalinki sıfıra
yakın. (a) ignore-xff'te tek kova kalır (ingress'in adresi) ve normal istemcinin sınırlanan payı belirgin yükselir:
**adaletsiz**. (b) trust-any-xff'te `203.0.113.66` kaybolur, `198.18.x.y` kovaları gelir ve son komut yüzlerce adres
sayar (script en az 20 arar): kötü istemci IP limitinden kaçıyor — **etkisiz**. Kiracı limiti adrese bakmadığı için kötü
istemcinin payı sıfıra inmeyebilir.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl08&from=now-15m&to=now&refresh=10s) — üç faz (doğru, `TRAP_IGNORE_XFF`, `TRAP_TRUST_ANY_XFF`), her biri 40 sn
- "Kararlar (anahtar türüne göre)" → her mod için bir tümsek. Doğru ve ignore-xff fazlarında `ip reject` belirgin; trust-any-xff fazında `ip reject` neredeyse **sıfır** (kötü istemci her istekte yeni kova seçiyor), `tenant reject` sürer.
- "Dönen durum kodları" → `302` ignore-xff fazında en düşük (normal istemci de reddediliyor), trust-any-xff fazında en yüksek. `503` ingress'in kaba sınırıdır (`limit-rps`).
- "Normal ve kötü niyetli kullanıcının gecikmesi (k6)" → gecikmede büyük fark bekleme (429 hızlı bir cevap); fark **kimin** reddedildiğinde.
- Explore'da: `k6_normal_client_limited_rate{level="lvl08"}` → normal istemcinin sınırlanan payı (0–1): ignore-xff fazında yükselir, diğerlerinde sıfıra yakın.

**Nerede çözülüyor:** seviye içi (bayrakları kapat) — kaç proxy olduğunu ve hangisinin senin olduğunu yazıya dök;
gerisi veridir, kanıt değil.

---

### P08-04 · Sabit pencere sınırında 2× burst

**Ne deniyoruz:** Sabit pencereli sayaç, iki pencerenin sınırında limitin iki katını geçiriyor mu?
**Neden:** 10 sn'de 300 limitte, 9.9. saniyede 300 ve 10.1. saniyede 300 daha geçebilir: 0.2 saniyede 600.

**Reproduce (adım adım):** Otomatik: `make repro P=P08-04` (redirect'i tek pod'a indirir, IP limitini geçici olarak
60 / 10 sn'ye çeker, önce kayan sonra sabit pencereyle `burst` koşar, pod'un `/metrics` ucunu saniyede bir okuyup
10 sn'lik en yoğun aralıkta kabul edilen isteği basar; yük sınıra dayanmazsa `PEAK=800 make repro P=P08-04`). Elle —
taşma 1 sn'den kısa sürer, Prometheus göremez; bu yüzden sayaç uygulamanın `/metrics` ucundan saniyede bir okunur:

1. Temiz başla; pencereye ve limite bak, redirect'i tek pod'a indir, IP limitini 60 / 10 sn'ye çek (yük sınıra dayansın):
```bash
cd "$LADDER/08-rate-limiting"
make fresh
make env W=redirect | grep -E 'RATE_LIMIT_WINDOW|RATE_LIMIT_PER_IP'
kubectl -n lvl08 scale deploy/redirect --replicas=1
make set E="RATE_LIMIT_PER_IP=60" W=redirect
sleep 10
```
2. **Kayan pencere (varsayılan):** ikinci bir terminalde `burst` yükünü başlat (~70 sn):
```bash
cd "$LADDER/08-rate-limiting"
LIMITS_ENFORCED=1 make load S=burst
```
   Hemen ardından ilk terminalde 70 sn boyunca her saniye kabul edilen IP kararlarını say (bütün hazır pod'lar
   toplanır), sonra 10 sn'lik en yoğun aralığı bul:
```bash
cd "$LADDER/08-rate-limiting"
rm -f /tmp/p0804.txt; prev=; for i in $(seq 1 70); do cur=$(for p in $(kubectl -n lvl08 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].targetRef.name}'); do kubectl -n lvl08 get --raw "/api/v1/namespaces/lvl08/pods/$p:8080/proxy/metrics"; done | awk '/^ratelimit_decisions_total\{/ && /decision="allow"/ && /key_type="ip"/ {s += $2} END {print s + 0}'); [ -n "$prev" ] && awk -v a="$prev" -v b="$cur" 'BEGIN {d = b - a; print (d < 0 ? 0 : d)}' | tee -a /tmp/p0804.txt; prev=$cur; sleep 1; done
awk '{a[NR]=$1} END {best=0; for (i=1; i<=NR; i++) {s=0; for (j=i; j<i+10 && j<=NR; j++) s+=a[j]; if (s>best) best=s}; print "10 sn içinde en çok kabul: " best}' /tmp/p0804.txt
```
3. **Sabit pencere:** tuzağı aç (pod'lar yeniden başlar), sonra 2. adımı aynen tekrarla — ikinci terminalde aynı yük,
   ilk terminalde aynı sayım:
```bash
cd "$LADDER/08-rate-limiting"
make set E="TRAP_FIXED_WINDOW=true" W=redirect
sleep 10
```
```bash
cd "$LADDER/08-rate-limiting"
LIMITS_ENFORCED=1 make load S=burst
```
```bash
cd "$LADDER/08-rate-limiting"
rm -f /tmp/p0804.txt; prev=; for i in $(seq 1 70); do cur=$(for p in $(kubectl -n lvl08 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].targetRef.name}'); do kubectl -n lvl08 get --raw "/api/v1/namespaces/lvl08/pods/$p:8080/proxy/metrics"; done | awk '/^ratelimit_decisions_total\{/ && /decision="allow"/ && /key_type="ip"/ {s += $2} END {print s + 0}'); [ -n "$prev" ] && awk -v a="$prev" -v b="$cur" 'BEGIN {d = b - a; print (d < 0 ? 0 : d)}' | tee -a /tmp/p0804.txt; prev=$cur; sleep 1; done
awk '{a[NR]=$1} END {best=0; for (i=1; i<=NR; i++) {s=0; for (j=i; j<i+10 && j<=NR; j++) s+=a[j]; if (s>best) best=s}; print "10 sn içinde en çok kabul: " best}' /tmp/p0804.txt
```
4. Geri al (tuzak ve limit manifestteki hâline, replika 2'ye):
```bash
cd "$LADDER/08-rate-limiting"
make reset
kubectl -n lvl08 scale deploy/redirect --replicas=2
```

**Terminalde ne görmelisin:** başta `RATE_LIMIT_PER_IP=300`, `RATE_LIMIT_WINDOW=10s`. İki modda da k6 özetinde `429=`
büyük (yük limiti aşıyor — deneyin ön koşulu). Kayan pencerede 10 sn'lik en yoğun aralık limit (60) civarında; sabit
pencerede pencere sonu ile sonrakinin başı aynı 10 sn'ye düşünce limitin üstüne, en fazla iki katına (~120) çıkar
(script `sabit > kayan` ve `sabit > limit` görünce REPRODUCED der). Sabit pencere her koşuda 2× geçirmez: yalnızca yük
sınıra denk gelirse.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) — iki faz (kayan, sabit), her biri ~70 sn `burst`
- "Kararlar (anahtar türüne göre)" → iki fazda da `ip reject` > 0 olmalı (yük limiti aşıyor); `ip allow` iki fazda da limite yakın (≈6/s) düz bir çizgi.
- "Sınırdan geçen istek / sn (10 sn çözünürlük)" → büyük olasılıkla boş ya da kesik: 1 sn'den kısa taşma 10 sn'lik kazımada ortalamaya karışır; kanıt terminaldeki saniyelik sayım.

**Nerede çözülüyor:** seviye içi — kayan pencere sayacı (önceki pencerenin sayımı, mevcut pencerede ne kadar ilerlendiğine
göre ağırlıklandırılır; `internal/ratelimit/redis.go`'daki Lua). Alternatifler: sliding window log (kesin ama pahalı),
token bucket (patlamaya izin verir, ortalamayı korur).

---

### P08-05 · TRAP · Global anahtar = Redis hot key

**Ne deniyoruz:** "Bütün sistem için saniyede N istek" kuralı (tek global anahtar) limitin tavanını neye bağlar?
**Neden:** Her istek aynı tek Redis anahtarına yazar ve Redis komutları tek iş parçacığında çalıştırır: tavan tek bir
çekirdektir, pod eklemek yükseltmez. Bu kümenin yükünde fark küçüktür — sorun yavaşlama değil, henüz çarpılmayan bir tavan.

**Reproduce (adım adım):** Otomatik: `make repro P=P08-05` (önce Redis pod'unda `redis-benchmark` ile 100 bin anahtara
dağılmış ve tek anahtardaki `INCR` tavanını ölçer — ikisi yakınsa sınır instance'ta, hüküm bu; sonra dağıtık ve global
modları 40'ar sn yükle koşup limit kontrolü p99'u ve Redis CPU'sunu bilgi için basar). Elle:

1. Temiz başla; tavanı Redis pod'unun içinde ölç: `INCR` önce 100 bin anahtara dağılmış, sonra tek anahtarda:
```bash
cd "$LADDER/08-rate-limiting"
make fresh
kubectl -n lvl08 exec redis-0 -c redis -- redis-benchmark -q -t incr -n 100000 -c 50 -r 100000
kubectl -n lvl08 exec redis-0 -c redis -- redis-benchmark -q -t incr -n 100000 -c 50 -r 0
```
2. Anahtar başına limit (varsayılan): 40 kullanıcıyla 40 sn yük, sonra limit kontrolü p99'u ve Redis CPU tepesi:
```bash
cd "$LADDER/08-rate-limiting"
LIMITS_ENFORCED=1 make load S=redirect K6_ARGS="--vus 40 --duration 40s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(ratelimit_check_duration_seconds_bucket{namespace="lvl08"}[2m])) by (le))' | jq -r '"limit kontrolü p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="lvl08",pod=~"redis.*",image!="",image!~".*pause.*"}[30s]))[3m:15s]) * 100' | jq -r '"Redis CPU tepesi (100 = bir çekirdek): " + .data.result[0].value[1]'
```
3. Tuzağı aç (her istek tek global anahtara da yazar; pod'lar yeniden başlar), aynı yük ve ölçüm; global anahtarı gör:
```bash
cd "$LADDER/08-rate-limiting"
make set E="TRAP_GLOBAL_LIMIT=true" W=redirect
sleep 10
LIMITS_ENFORCED=1 make load S=redirect K6_ARGS="--vus 40 --duration 40s"
kubectl -n lvl08 exec redis-0 -c redis -- redis-cli --scan --pattern 'rl:global:*'
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(ratelimit_check_duration_seconds_bucket{namespace="lvl08"}[2m])) by (le))' | jq -r '"limit kontrolü p99 (sn): " + .data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="lvl08",pod=~"redis.*",image!="",image!~".*pause.*"}[30s]))[3m:15s]) * 100' | jq -r '"Redis CPU tepesi (100 = bir çekirdek): " + .data.result[0].value[1]'
```
4. Tuzağı kapat:
```bash
cd "$LADDER/08-rate-limiting"
make reset
```

**Terminalde ne görmelisin:** 1. adımda iki `INCR: … requests per second` satırı aynı mertebede — tek anahtar dağıtıktan
belirgin hızlı değil (script tek anahtar dağıtığın 1.5 katının altındaysa REPRODUCED der): sınır anahtarda değil
instance'ta, global limitin tavanı tek çekirdek. 3. adımda `--scan` pencere başına tek bir `rl:global:all:<pencere>`
basar: bütün istekler aynı anahtarda. İki fazın `limit kontrolü p99` ve `Redis CPU` değerleri yakın: uygulama tavanın
çok altında — "sorun yok" değil, "henüz oraya gelmedin".

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) — önce tavan ölçümü, sonra iki 40 sn'lik faz (dağıtık, global)
- "Redis CPU" → önce `redis-benchmark`'ın kısa, yüksek tepesi; sonra iki benzer tümsek (dağıtık, global), aralarındaki fark küçük.
- "Komutlar (türe göre)" → benchmark'ta `incr` tepesi; yük fazlarında `evalsha`, global fazda daha yüksek (her istek bir kontrol daha yapıyor).
- "Kararlar (anahtar türüne göre)" → `global allow` / `global reject` yalnızca tuzak fazında belirir.

**Nerede çözülüyor:** seviye içi — anahtarı parçala (`global:0..15`, rastgele seç, limiti 16'ya böl). Aynı fizik 02'de
DB satırında (P02-08), 04'te önbellek anahtarında (P04-03) görüldü.

---

### P08-06 · Gürültülü komşu izole ediliyor mu?

**Ne deniyoruz:** Açgözlü bir istemci 429 alırken normal istemcilerin deneyimi bozulmadan kalıyor mu?
**Neden:** Hız sınırının amacı kapasiteyi değil **adaleti** korumaktır; bu seviyenin asıl sorusu bu.

**Reproduce (adım adım):** Otomatik: `make repro P=P08-06` (`abuser`: 1 açgözlü + N normal istemci; P08-03'teki gibi
k6 yük dengeleyiciyi oynar ve `TRUSTED_PROXY_HOPS=2` denir — yoksa hepsi tek IP kovasında olur ve izolasyon
ölçülemez. Hüküm: kötü istemcinin en az %30'u, normal istemcinin %5'ten azı sınırlanır). Elle:

1. Temiz başla; redirect'e "önümde iki proxy var" de (pod'lar yeniden başlar):
```bash
cd "$LADDER/08-rate-limiting"
make fresh
make set E="TRUSTED_PROXY_HOPS=2" W=redirect
sleep 10
```
2. Kötü ve normal istemcileri aynı anda 60 sn koştur; hemen ardından IP kovalarını adrese göre say:
```bash
cd "$LADDER/08-rate-limiting"
LIMITS_ENFORCED=1 make load S=abuser K6_ARGS="--duration 60s"
kubectl -n lvl08 exec redis-0 -c redis -- redis-cli --scan --pattern 'rl:ip:*' | sed 's/^rl:ip://; s/:[0-9]*$//' | sort | uniq -c | sort -rn | head
```
3. Kazıma yetişsin diye bekle, retleri anahtar türüne göre oku:
```bash
cd "$LADDER/08-rate-limiting"
sleep 12
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (key_type) (increase(ratelimit_decisions_total{namespace="lvl08",decision="reject"}[2m]))' | jq -r '.data.result[] | "\(.metric.key_type) reddi: \(.value[1])"'
```
4. Geri al (`TRUSTED_PROXY_HOPS` 1'e döner):
```bash
cd "$LADDER/08-rate-limiting"
make reset
```

**Terminalde ne görmelisin:** `normal client p99=…ms · sınırlanan: normal=…% kötü=…%` satırında kötü istemcinin payı
%30'un üstünde, normalinki %5'in altında, normal p99 düşük. Kova listesinde `203.0.113.66` ile bir sürü
`198.51.100.<n>` ayrı ayrı: iki taraf gerçekten ayrı kovalarda. `ip reddi` büyük; kötü istemci kiracı limitini
(2000 / 10 sn) de aştığı için `tenant reddi` > 0.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl08&from=now-15m&to=now&refresh=10s) — `abuser` 60 sn; başlatınca aç
- "Normal ve kötü niyetli kullanıcının gecikmesi (k6)" → `normal kullanıcı p99` düşük ve düz: normal istemcinin deneyimi bozulmuyor. Kötü istemcinin p99'u da düşük: 429 hızlı bir cevap.
- "Kararlar (anahtar türüne göre)" → `ip reject` belirgin yükselir; `tenant reject` de görünür (kiracı limiti aşıldı).
- "429 oranı" → sıfırın belirgin üstüne çıkar.
- "Dönen durum kodları" → `429` baskın, yanında `302`; `503` kötü istemcinin ingress'in kaba sınırını (400/sn) aşması — normal istemci 503 almaz.
- Explore'da: `k6_normal_client_limited_rate{level="lvl08"}` → normal istemcinin sınırlanan payı: sıfıra yakın kalmalı.

**Nerede çözülüyor:** 13 (kimliğe göre müşteri kotaları). IP limiti tek saldırganı, kiracı limiti bir müşterinin
bütün altyapısını sınırlar; ikisi birlikte gerekir.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_IGNORE_XFF` | XFF'i yok sayar (herkes tek kovada) | `make repro P=P08-03` | Bayrağı kapat |
| `TRAP_TRUST_ANY_XFF` | XFF'in ilk girdisine güvenir | `make repro P=P08-03` | Bayrağı kapat |
| `TRAP_GLOBAL_LIMIT` | Tek global anahtar kullanır | `make repro P=P08-05` | Bayrağı kapat / parçala |
| `TRAP_FIXED_WINDOW` | Kayan pencere yerine sabit pencere sayacı (sınırda 2× burst) | `make repro P=P08-04` | Bayrağı kapat (kayan pencere) |
| `TRAP_LIST_N_PLUS_ONE` · `TRAP_READY_ALWAYS` | (07'den devam) | 07'de | — |

Elle denemeye değer:
- `RATE_LIMIT_PER_IP=20` yap ve tarayıcıyla gez: kendi limitine takılmak limitin nasıl hissettirdiğini gösterir; `Retry-After` başlığına bak.
- `RATE_LIMIT_WINDOW=60s` yap: uzun pencere daha adil ama daha geç tepki verir.
- Ingress'in `limit-rps` annotasyonunu sil, `abuser` koş: uygulamaya ulaşan istek farkını ölç — en ucuz ret, hiç gelmeyen istek.
- `make load S=create` ile api-svc'yi zorla: sayaç paylaşımlı olduğu için iki servis aynı limiti paylaşır.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now) | **Dolu** ✨ | `decision` × `key_type` kırılımı, limiter hataları; kontrol süresi paneli yok (Explore, P08-02). Toplama değil `key_type` kırılımına bak: IP mi kiracı mı reddetti |
| [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now) | Dolu | Önbellek ve limiter aynı Redis'te — komut dağılımına bak |
| [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl08&from=now-15m&to=now) · [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl08&from=now-15m&to=now) · [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl08&from=now-15m&to=now) · [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl08&from=now-15m&to=now) | Dolu | — |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl08&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl08&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl08&from=now-15m&to=now) | Boş | — |

## 9. Bilerek bırakılanlar

- Redis hem önbellek hem limiter: tek arıza iki işi birden düşürür (P08-01 → 14).
- Kimlik yok: kiracı hâlâ `X-Tenant-ID` başlığından; müşteri kotaları için gerçek kimlik şart (13).
- Her kiracıya aynı sabit limit.
- Ingress limiti kaba: yol/metot ayrımı yok.
- 404 taramasına özel limit yok (13, P13-06).
- Pod içi yedek limiter yok: Redis düşünce koruma tamamen kalkar.
- 07'den devreden: tek Postgres + havuz aritmetiği (09), tek partition (06), tek Redis (14).

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 07 ile farkı gösterir:

1. `internal/ratelimit/redis.go`: asıl ders Lua betiği — oku-değiştir-yaz'ı istemci tarafında yapmak yapısı gereği yarıştır.
2. `internal/httpapi/clientip.go`: 20 satırda üç farklı güvenlik sonucu (P08-03); limiter, yedek limiter ve access
   log aynı istemci adresini kullanır.
3. `internal/ratelimit/ratelimit.go` duruyor: süreç içi limiter testler ve Redis'siz çalıştırma için yedek.
4. `deploy/ingress.yaml`: `limit-rps`, savunmanın ucuz yarısı. XFF davranışı controller ConfigMap'inde:
   [`platform/manifests/ingress-nginx-config.yaml`](../platform/manifests/ingress-nginx-config.yaml).
5. `deploy/*-svc.yaml`: `RATE_LIMIT_PER_IP` artık pod başına değil, pencere başına.
