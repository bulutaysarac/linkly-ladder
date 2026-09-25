# 04 — redis-cache · "Paylaşılan önbellek"

> **Bu seviyede ne yaşayacaksın?**
> - 03'ün tutarsızlıklarının tek hamlede kapanması: tek kopya, tek geçersiz kılma, dağıtımlardan sağ çıkan sıcak önbellek
> - Redis ölünce bütün yükün DB'ye inmesi (P04-01); her okumaya bir ağ adımı eklenmesi (P04-02)
> - Tek sıcak linkin Redis'in tek çekirdeğine dayanması (P04-03); tuzak: jitter yokluğunun paylaşılan önbellekte daha keskin olması (P04-04)
> - Cache-aside yarışında bayat kaydın geri yazılması (P04-05); `noeviction` ile dolan önbelleğin sessizce önbelleklemeyi bırakması (P04-06); tuzak: `KEYS *`'in bütün Redis'i kilitlemesi (P04-07)
>
> **Bu seviye olmasa ne olur?** Silinen link pod'larda yaşar, her rollout önbelleği soğutup DB'yi yakar, ıska replika sayısıyla artar (P03-01 … P03-04).
>
> **Yeni gelen teknolojiler:** Redis 7, go-redis, redis_exporter, Chaos Mesh ile Redis öldürme ve geciktirme ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Önbellek pod'un dışına çıkar: bütün replikaların paylaştığı tek bir Redis. 03'ün tutarlılık sorunları kapanır;
karşılığında her okumaya bir ağ adımı ve yavaşlayabilen, dolabilen, ölebilen yeni bir bağımlılık eklenir.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress-nginx<br/>lvl04.localtest.me]
  I --> A1 & A2 & A3

  subgraph APP["linkly · 3 replika · önbelleksiz"]
    A1[pod 1]
    A2[pod 2]
    A3[pod 3]
  end

  A1 & A2 & A3 -->|GET / SET / DEL<br/>~0.3-1 ms| R[("redis:7 × 1<br/>maxmemory 64mb<br/>noeviction")]
  A1 & A2 & A3 -.->|yalnızca MISS| PG[("postgres:17 × 1")]
  A1 & A2 & A3 -->|her tıklama UPDATE| PG
```

Artık iki tek arıza noktası var: Postgres (P02-03) ve Redis (P04-01). Redis ölünce istekler DB'ye düşer (fail-open);
bu, DB'nin o yükü kaldırabileceğine yapılan bir bahistir.

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P03-01 | Silinen link diğer pod'larda yaşıyor | Tek paylaşılan önbellek: `DEL` herkesi etkiler |
| P03-02 | Rollout = soğuk önbellek | Önbellek pod'un dışında; pod ölse de yaşar |
| P03-03 | Aynı veri N kopya | Bellek bir kez ödenir (pod bellek limiti 384Mi → 256Mi) |
| P03-04 | Hit oranı replika sayısıyla düşer | Tek önbellek; replika sayısı ıskayı artırmaz |

P03-05 (singleflight) listede yok: pod içi birleştirme sürer, süreçler arası birleştirme dağıtık kilit ister (gerekçe `internal/cache/redis.go`'da).

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/04-redis-cache"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl04.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl04.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl04 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P04-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

Redis'e elle bakmak için (etkileşimli `redis-cli`; `exit` ile çık):
```bash
cd "$LADDER/04-redis-cache"
kubectl -n lvl04 exec -it $(kubectl -n lvl04 get pod -l app.kubernetes.io/name=redis -o name) -c redis -- redis-cli
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl04 ayakta` yazar:
```bash
cd "$LADDER/03-local-cache"
make down
cd "$LADDER/04-redis-cache"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/04-redis-cache"
make up
```
2. 03'ün sorunlarını burada koş (yedi script art arda, uzun sürer; koşarken başka komut çalıştırma). `CONFIRM=1`,
   replika sayısını değiştiren P03-04'ün de koşmasını sağlar. `BEKLENEN` sütunu `NOT-REPRODUCED` olan satırlar
   (P03-01 … P03-04) 04'ün çözdüğünü iddia ettikleri; sonuç uymazsa satır `✘` alır:
```bash
cd "$LADDER/04-redis-cache"
CONFIRM=1 make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P04-01 → P04-07): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç.
4. Bitince ayarları geri al ve seviyeyi kapat:
```bash
cd "$LADDER/04-redis-cache"
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). Davranış değişikliği yok.

Yalnızca `TRAP_DEBUG_KEYS` açıkken ek bir uç belirir: `GET /debug/keys` (P04-07). Varsayılan kapalı.

## 6. Reproduce edilebilir sorunlar

Her sorun aynı düzende: **Ne deniyoruz** (deneyin sorusu) → **Neden** → adımlar (her adım ne yaptığını söyler)
→ **Terminalde ne görmelisin** → **Grafana'da gör** (giriş: admin / ladder) → **Nerede çözülüyor**.
`make repro` hükmü: `REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` = ölçülemedi.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P04-01 | Redis düşünce yük DB'ye iner | `CONFIRM=1 make repro P=P04-01` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl04&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Veritabanı sorguları (türe göre)" | 10 · 14 |
| P04-02 | Önbellek isabeti artık ağ üzerinden | `make repro P=P04-02` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Komut / sn" | 14 (L1+L2) |
| P04-03 | Sıcak anahtar = tek Redis çekirdeği | `make repro P=P04-03` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Komutlar (türe göre)" | 14 |
| P04-04 | **TRAP** jitter yok → dalga birleşiyor | `make repro P=P04-04` | görünmez — kanıt terminalde ↓ | seviye içi |
| P04-05 | Cache-aside yarışı: bayat kayıt geri yazılıyor | `make repro P=P04-05` | görünmez — kanıt terminalde ↓ | tartışma |
| P04-06 | maxmemory + noeviction → sessizce durur | `make repro P=P04-06` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Bellek ve üst sınır" | seviye içi |
| P04-07 | **TRAP** `KEYS *` Redis'i kilitler | `make repro P=P04-07` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Komutlar (türe göre)" | seviye içi |

---

### P04-01 · Redis düşünce bütün yük DB'ye iner

**Ne deniyoruz:** Redis ölünce hizmet sürüyor mu, ve bedelini kim ödüyor?
**Neden:** Uygulama Redis'e ulaşamazsa DB'ye düşer (fail-open): hizmet kesilmez, ama önbelleğin sakladığı bütün okuma
yükü birden DB'ye iner (%95 isabette ~20 kat).

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P04-01` (önbellek çalışırken 25 kullanıcıyla 40 sn yük
verip DB okumasını ölçer, Redis pod'unu siler, aynı yükü tekrarlar; DB tepesini, önbellek hatalarını, 5xx'i ve p99'u
basar). Elle:

1. Temiz başla; önbellek çalışırken 40 sn yük ver, sonra DB'nin saniyedeki okuma (`get`) sayısına ve isabet oranına
   bak:
```bash
cd "$LADDER/04-redis-cache"
make fresh
make load S=redirect K6_ARGS="--vus 25 --duration 40s"
sleep 12
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(db_queries_total{namespace="lvl04",op="get"}[1m]))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(cache_ops_total{namespace="lvl04",layer="l2",result="hit"}[1m])) / sum(rate(cache_ops_total{namespace="lvl04",layer="l2"}[1m]))' | jq -r '.data.result[0].value[1]'
```
2. **Yıkıcı adım:** Redis pod'unu sil ve hemen aynı yükü ver; sonra DB okumasının tepesini ve önbellek hatalarını oku:
```bash
cd "$LADDER/04-redis-cache"
kubectl -n lvl04 delete pod -l app.kubernetes.io/name=redis --wait=false
sleep 3
make load S=redirect K6_ARGS="--vus 25 --duration 40s"
sleep 12
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(rate(db_queries_total{namespace="lvl04",op="get"}[30s]))[3m:15s])' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(cache_errors_total{namespace="lvl04"}[5m]))' | jq -r '.data.result[0].value[1]'
```
3. Redis'in geri geldiğini bekle (sonraki deneyler onu arıyor):
```bash
cd "$LADDER/04-redis-cache"
kubectl -n lvl04 rollout status statefulset/redis --timeout=180s
```

**Terminalde ne görmelisin:** 1. adımda k6 özeti `5xx=0`, DB `get`/sn küçük (yalnızca ıskalar DB'ye iniyor), isabet
oranı `0.9…`. 2. adımda yine `5xx=0` — hizmet sürdü — ama DB `get` tepesi 1. adımın kat kat üstünde (script en az 2
katını arar) ve önbellek hatası sıfırdan büyük: Redis'e ulaşamayan her okuma DB'ye düştü. Redis birkaç saniyede geri
gelir ama boş doğar; DB yükü önbellek ısınana kadar yüksek kalır.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl04&from=now-15m&to=now&refresh=10s), [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl04&from=now-15m&to=now&refresh=10s) — iki yük fazı (önbellekli, Redis silinmiş) bitince aç
- "Veritabanı sorguları (türe göre)" → `get` ilk fazda yere yakın; Redis silinince kat kat yükselir ve Redis boş döndüğü için önbellek ısınana kadar yüksek kalır. `increment_clicks` iki fazda aynı.
- "Önbellek yazma/okuma hatası" → Redis yokken `get` ve `set` serileri belirir: uygulama Redis'e ulaşamayıp DB'ye düşüyor. (`06 · Redis` → "Redis ayakta mı" bunu 0 olarak göstermez: exporter Redis'le aynı pod'da, onunla birlikte ölür; yalnızca kısa bir boşluk görürsün.)
- "Önbellek işlemleri (katman ve sonuca göre)" → Redis ölünce `l2 hit` 0'a düşer, yerini `l2 miss` alır; Redis dönünce `l2 hit` yavaşça geri gelir.
- "Dönen durum kodları" → `302` kesintisiz sürer, `5xx` çıkmaz: bedeli kullanıcı değil DB ödedi.

**Nerede çözülüyor:** 10 (bulkhead: DB'ye giden eşzamanlılığı sınırla, fazlasını hızlıca reddet) · 14 (L1+L2: pod içi
küçük önbellek, Redis düşse de en sıcak anahtarlar ayakta). Asıl soru: DB o anki yükü kaldırabilir mi?

---

### P04-02 · Paylaşılan önbelleğin bedeli: bir ağ gidiş-gelişi

**Ne deniyoruz:** Önbelleğe sormak artık ne kadar sürüyor?
**Neden:** 03'te bir isabet pod içi bir map aramasıydı (~1 µs); 04'te her isabet bir Redis `GET`, yani bir ağ
gidiş-gelişi (yüzlerce µs). Hit oranı aynı, bedel farklı.

**Reproduce (adım adım):** Otomatik: `make repro P=P04-02` (ısıtır, sabit yük altında önbellek aramasının süresini
`cache_lookup_duration_seconds{layer="l2"}` histogramından ölçer; hüküm: aramaların ≥%90'ı ağda ve p50 ≥ 50 µs;
Prometheus'ta 03'ün bir koşusu duruyorsa onun `l1` p50'sini de basar). Elle:

1. Temiz başla, önbelleği ısıt:
```bash
cd "$LADDER/04-redis-cache"
make fresh
make load S=redirect K6_ARGS="--vus 20 --duration 30s"
```
2. Sabit yük ver; sonra önbelleğe sormanın p50 ve p99'unu (µs) ve aramaların ağ katmanına (`l2`) giden payını oku
   (uçtan uca istek süresi değil: onun en küçük kovası 1 ms, fark ondan küçük):
```bash
cd "$LADDER/04-redis-cache"
make load S=redirect K6_ARGS="--vus 20 --duration 45s"
sleep 12
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1e6 * histogram_quantile(0.50, sum(rate(cache_lookup_duration_seconds_bucket{namespace="lvl04",layer="l2"}[1m])) by (le))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1e6 * histogram_quantile(0.99, sum(rate(cache_lookup_duration_seconds_bucket{namespace="lvl04",layer="l2"}[1m])) by (le))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(cache_lookup_duration_seconds_count{namespace="lvl04",layer="l2"}[1m])) / sum(rate(cache_lookup_duration_seconds_count{namespace="lvl04"}[1m]))' | jq -r '.data.result[0].value[1]'
```

**Terminalde ne görmelisin:** p50 yüzlerce mikrosaniye (eşik 50 µs; 03'teki map araması ~1 µs), p99 daha büyük; pay
`1`: her arama Redis'e, yani ağa gidiyor. k6 özetindeki `p95`/`p99` milisaniye cinsinden; fark orada görünmez.

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s), [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl04&from=now-15m&to=now&refresh=10s) — deneyden sonra aç; asıl sayı Explore'da
- Explore'da: `histogram_quantile(0.5, sum by (le, namespace, layer) (rate(cache_lookup_duration_seconds_bucket{namespace=~"lvl03|lvl04"}[1m])))` → `lvl04 l2` yüzlerce µs'de; 03'ün koşusu duruyorsa `lvl03 l1` ~1 µs'de: aynı isabet, iki-üç büyüklük mertebesi fark.
- "Komut / sn" → redirect hızıyla birlikte artar: her isabet bir Redis `GET`.
- "İsabet oranı (toplam)" → yüksek: fark ıskadan değil, isabetin nerede olduğundan geliyor.
- "Gecikme (p50 / p95 / p99)" → `lvl03` ile `lvl04` arasında zor ayrışır: fark 1 ms'nin altında ve p50'nin çoğu iki seviyede ortak tıklama UPDATE'i. Bu panelden hüküm çıkmaz.
- "Uygulama → Redis gecikmesi (p99)" → bu seviyede **boş**: bu metrik 10'dan itibaren yayınlanır.

**Nerede çözülüyor:** 14 (L1+L2). L1'i geri getirmek P03-01'i de geri getirir; bu yüzden 14'te pub/sub ile geçersiz
kılma yayını gelir.

---

### P04-03 · Sıcak anahtar: tek link, tek çekirdek

**Ne deniyoruz:** Trafiğin çoğu tek linke giderse Redis'in tavanı nerede?
**Neden:** Redis tek iş parçacıklıdır; bir anahtara erişim tek bir çekirdeğin sınırına dayanır. Anahtarları başka
sunuculara dağıtmak (sharding) tek sıcak anahtarı kurtarmaz.

**Reproduce (adım adım):** Otomatik: `make repro P=P04-03` (Redis'in tavanını `redis-benchmark` ile doğrudan ölçer —
100k anahtara dağıtılmış GET ve tek anahtara GET —, sonra %95'i tek linke giden yükte uygulamanın o tavanın yüzde
kaçını kullandığını basar; hüküm: iki tavan birbirinin ±%30'u içinde). Elle:

1. Temiz başla; Redis'in tavanını iki kez ölç: 100 000 farklı anahtara GET, sonra hep aynı anahtara GET (CPU'yu
   kıyaslamak işe yaramaz: iki yük de aynı sayıda komut üretir; tavanın kendisi ölçülür):
```bash
cd "$LADDER/04-redis-cache"
make fresh
rpod=$(kubectl -n lvl04 get pod -l app.kubernetes.io/name=redis -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "redis pod: $rpod"
kubectl -n lvl04 exec "$rpod" -c redis -- redis-benchmark -q -t get -n 100000 -c 50 -r 100000
kubectl -n lvl04 exec "$rpod" -c redis -- redis-benchmark -q -t get -n 100000 -c 50 -r 0
```
2. Uygulamanın tarafı: trafiğin %95'ini tek linke gönder; sonra Redis'e yaptırılan en yüksek komut hızını ve Redis'in
   en yüksek CPU'sunu (bir çekirdeğin %'si) oku:
```bash
cd "$LADDER/04-redis-cache"
HOT_SHARE=0.95 make load S=hot-key K6_ARGS="--vus 60 --duration 40s"
sleep 12
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(rate(redis_commands_processed_total{namespace="lvl04"}[30s]))[3m:15s])' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=100 * max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="lvl04",pod=~"redis.*",image!="",image!~".*pause.*"}[30s]))[3m:15s])' | jq -r '.data.result[0].value[1]'
```

**Terminalde ne görmelisin:** 1. adımda iki `GET: … requests per second` satırı birbirine yakın: sınır anahtarda değil,
instance'ta. 2. adımda uygulamanın komut hızı tek anahtar tavanının çok altında ve Redis CPU'su 100'ün altında: bu
kümede tavana çarpmıyoruz. Sorun "şu an yavaşız" değil, "büyüyünce çare yok".

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) — deneyden sonra aç; tavan terminalde ölçülür
- "Komutlar (türe göre)" → hot-key yükü boyunca `get`'te bir plato: uygulamanın Redis'e yaptırdığı GET hızı; terminaldeki `TEK anahtar GET tavanı` ile kıyasla. Başındaki kısa tepe `redis-benchmark`'tır.
- "Redis CPU" → sıcak yükte bile tek çekirdeğin %100'ünün altında.
- "Komut / sn" → küçük eğri aynı platoyu çizer; büyük rakam yalnızca son değer.

**Nerede çözülüyor:** 14 (L1: en sıcak anahtar hiç ağa çıkmaz). Redis cluster bunu çözmez (sıcak anahtar tek shard'a
düşer); diğer seçenekler anahtarı çoğaltmak (`key:1..N`) ya da CDN.

---

### P04-04 · TRAP · Jitter yokluğu paylaşılan önbellekte daha kötü

**Ne deniyoruz:** TTL'ler aynı anda dolunca paylaşılan önbellekte dalga ne kadar keskin?
**Neden:** 03'te her pod kendi dalgasını üretiyordu; 04'te tek önbellek var ve bütün pod'lar aynı anahtarların aynı
anda dolduğunu aynı anda görür: dalga bölünmez, birleşir.

**Reproduce (adım adım):** Otomatik: `make repro P=P04-04` (TTL'i 30 sn'ye çeker, 300 kodu ısıtır, jitter açık/kapalı
150'şer sn yük verip **tepe/ortalama** oranını kıyaslar; ~8 dk; seriler `/tmp/p0404-jitter.txt` ve
`/tmp/p0404-nojitter.txt`; hüküm: jitter'sız oran en az 1,8 kat ve 3'ten büyük). Elle — iki terminal gerekir; darbe 1-2
sn sürdüğü için pod'un kendi `/metrics` ucu saniyede bir okunur:

1. Temiz başla; TTL'i 30 sn'ye çek (jitter açık, pod'lar yeniden başlar), örneklenecek pod'u seç:
```bash
cd "$LADDER/04-redis-cache"
make fresh
make set E="CACHE_TTL=30s"
pod=$(kubectl -n lvl04 get pod -l app.kubernetes.io/name=linkly -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "örneklenen pod: $pod"
```
2. İkinci bir terminalde 300 linklik kümeyle 150 sn yük başlat:
```bash
cd "$LADDER/04-redis-cache"
SEED=300 make load S=redirect K6_ARGS="--vus 20 --duration 150s"
```
   Hemen ardından ilk terminalde pod'un ıska sayacını 150 sn boyunca saniyede bir oku, saniyelik farkı dosyaya yaz ve
   ilk 35 sn'lik ısınmayı atlayıp tepe/ortalama oranını hesapla (TTL Redis'te dolduğu için uygulama bunu ıska görür):
```bash
cd "$LADDER/04-redis-cache"
for i in $(seq 1 150); do kubectl -n lvl04 get --raw "/api/v1/namespaces/lvl04/pods/${pod}:8080/proxy/metrics" | awk '/^cache_ops_total\{.*result="miss"/ {s += $2} END {print s + 0}'; sleep 1; done > /tmp/p0404-jitter.raw
awk 'NR > 1 {d = $1 - p; print (d < 0 ? 0 : d)} {p = $1}' /tmp/p0404-jitter.raw > /tmp/p0404-jitter.txt
awk 'NR > 35 {n++; s += $1; if ($1 > m) m = $1} END {a = (n ? s / n : 0); printf "jitter açık: tepe=%d ort=%.1f tepe/ortalama=%.1f\n", m, a, (a ? m / a : 0)}' /tmp/p0404-jitter.txt
```
3. Jitter'ı kapat (TTL 30 sn kalır, pod'lar yeniden başlar), yeni pod'u seç:
```bash
cd "$LADDER/04-redis-cache"
make set E="TRAP_NO_TTL_JITTER=true"
pod=$(kubectl -n lvl04 get pod -l app.kubernetes.io/name=linkly -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "örneklenen pod: $pod"
```
   İkinci terminalde aynı yükü tekrar başlat:
```bash
cd "$LADDER/04-redis-cache"
SEED=300 make load S=redirect K6_ARGS="--vus 20 --duration 150s"
```
   Hemen ardından ilk terminalde aynı örneklemeyi başka dosyalara yaz:
```bash
cd "$LADDER/04-redis-cache"
for i in $(seq 1 150); do kubectl -n lvl04 get --raw "/api/v1/namespaces/lvl04/pods/${pod}:8080/proxy/metrics" | awk '/^cache_ops_total\{.*result="miss"/ {s += $2} END {print s + 0}'; sleep 1; done > /tmp/p0404-nojitter.raw
awk 'NR > 1 {d = $1 - p; print (d < 0 ? 0 : d)} {p = $1}' /tmp/p0404-nojitter.raw > /tmp/p0404-nojitter.txt
awk 'NR > 35 {n++; s += $1; if ($1 > m) m = $1} END {a = (n ? s / n : 0); printf "jitter kapalı: tepe=%d ort=%.1f tepe/ortalama=%.1f\n", m, a, (a ? m / a : 0)}' /tmp/p0404-nojitter.txt
```
4. İki seriyi yan yana gör, sonra TTL'i ve tuzağı geri al:
```bash
cd "$LADDER/04-redis-cache"
paste /tmp/p0404-jitter.txt /tmp/p0404-nojitter.txt | head -90
make reset
```

**Terminalde ne görmelisin:** `jitter kapalı` satırının tepe/ortalama oranı `jitter açık`'tan belirgin büyük (en az 1,8
kat ve 3'ten büyük). `paste` çıktısında her satır bir saniyedeki ıska sayısı: sol sütun küçük, dağınık sayılar; sağ
sütun çoğunlukla 0 ve ~30 satırda bir büyük sayı — aynı anda dolan anahtarlar aynı saniyede DB'den yeniden okunuyor.

**Grafana'da gör:** Grafana'da görünmez — darbe 1-2 sn sürer, Prometheus seyrek okur ve paneller 1 dk'lık `rate` çizer; tepe düzlenir. `05 · Postgres` → "Veritabanı sorguları (türe göre)" ve `06 · Redis` → "Silinen / süresi dolan anahtar" iki fazda da benzer, düz çizgilerdir. Kanıt terminalde:
- `make repro P=P04-04` → `jitter'lı: tepe=… ort=… → tepe/ortalama=…` ve `jitter'sız: …`; jitter'sız oran belirgin büyük
- `paste /tmp/p0404-jitter.txt /tmp/p0404-nojitter.txt | head -90` → sol sütun dağınık küçük sayılar, sağ sütun ~30 satırda bir büyük sayı

**Nerede çözülüyor:** Seviye içi — `TRAP_NO_TTL_JITTER` kapalıyken koruma açık. Paylaşmak, hizalanmayı da paylaşmaktır.

---

### P04-05 · Cache-aside yarışı: bayat kayıt geri yazılıyor

**Ne deniyoruz:** Paylaşılan önbellekte bile, silinmiş bir link önbelleğe geri yazılabilir mi?
**Neden:** Bir okuma önbelleği ıskalar ve DB'den eski değeri alır; tam o sırada link silinir (önbellekte anahtar henüz
yok, geçersiz kılma bir şey silmez); okuma sonra önbelleğe yazar ve silinmiş kayıt TTL boyunca yaşar. Pencere normalde
mikrosaniyeler, ama yeterli trafikte yakalanır.

**Reproduce (adım adım):** Otomatik: `make repro P=P04-05` (`TRAP_READ_FILL_DELAY_MS=1500` ile okuma yolundaki "DB'den
al → önbelleğe yaz" penceresini ölçülebilir yapar, 6 kez tam ortasında siler ve kaçında silinmiş linkin hâlâ
yönlendirdiğini sayar). Elle:

1. Temiz başla; okuma yolunda DB'den alma ile önbelleğe yazma arasına 1,5 sn koy (yarışan iki olay bunlar; pod'lar
   yeniden başlar), Redis pod'unu bul:
```bash
cd "$LADDER/04-redis-cache"
make fresh
make set E="TRAP_READ_FILL_DELAY_MS=1500"
sleep 10
rpod=$(kubectl -n lvl04 get pod -l app.kubernetes.io/name=redis -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "redis pod: $rpod"
```
2. 6 kez: link oluştur, ilk okumayı arka planda başlat, 0,4 sn sonra linki sil, okumanın bitmesini bekle, linki tekrar
   iste ve Redis'teki anahtarın kalan ömrüne (TTL) bak:
```bash
cd "$LADDER/04-redis-cache"
for i in 1 2 3 4 5 6; do
  code=$(curl -s -XPOST http://lvl04.localtest.me/api/links -H 'Content-Type: application/json' -d "{\"url\":\"https://example.com/race/${i}/${RANDOM}\"}" | jq -r .code)
  curl -s -o /dev/null http://lvl04.localtest.me/${code} &
  sleep 0.4
  curl -s -o /dev/null -w "deneme ${i}: kod=${code} silme=%{http_code}" -XDELETE http://lvl04.localtest.me/api/links/${code}
  wait
  sleep 1
  curl -s -o /dev/null -w " sonra=%{http_code}" http://lvl04.localtest.me/${code}
  echo " TTL=$(kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli TTL "linkly:link:${code}")"
done
```
3. Tuzağı kapat:
```bash
cd "$LADDER/04-redis-cache"
make reset
```

**Terminalde ne görmelisin:** çoğu satır `deneme 1: kod=… silme=204 sonra=302 TTL=…`: link DB'den silindi (`204`) ama
hâlâ yönlendiriyor (`302`); TTL pozitif (~60 sn): okuma bayat kaydı silmeden sonra yazdı. `sonra=404` olan deneme
pencereyi kaçırmıştır (TTL ~10 sn: "yok" negatif önbelleklendi). Arada kabuğun iş bildirimleri de görünür.

**Grafana'da gör:** Grafana'da görünmez — bayat isabet geçerli isabetle aynı sayaçlara yazılır (`04 · Cache` → `l2 hit`, `03 · App Business` → `ok`); hiçbir metrik "bu kayıt DB'de yok" demez. Kanıt terminalde:
- `make repro P=P04-05` → `deneme i: kod=… → 302 (SİLİNMİŞ ama hâlâ yönlendiriyor)` satırları
- `kubectl -n lvl04 exec redis-0 -c redis -- redis-cli TTL linkly:link:<kod>` (kod script çıktısından, ilk dakika içinde) → pozitif sayı: `DELETE` 204 döndüğü hâlde kayıt Redis'te (`-2` olsaydı anahtar yoktu)

**Nerede çözülüyor:** Tartışma — bedava çözüm yok: yazmadan sonra bir kez daha silmek (pencereyi daraltır), sürümlü
anahtar (bellek maliyeti), write-through + kısa TTL (yazma yavaşlar). Sırayı ters çevirmek yarışın yerini değiştirir.

---

### P04-06 · maxmemory + noeviction → önbellek sessizce önbelleklemeyi bırakır

**Ne deniyoruz:** Redis'in belleği dolunca ne olur?
**Neden:** `noeviction` politikası bellek dolunca yazmayı reddeder: Redis ayakta, `PING` cevap veriyor, okumalar
çalışıyor, ama yeni hiçbir şey önbelleğe girmiyor — görünürde sağlıklı, işlevsiz.

**Reproduce (adım adım):** Otomatik: `make repro P=P04-06` (`maxmemory`'yi deney süresince 4 MB'a çeker, 1200 link ×
~6 KB URL üretip okur, `cache_errors_total{op="set"}` ile `redis_evicted_keys_total`'ı karşılaştırır, sonunda ayarı
geri alır). Elle:

1. Temiz başla; Redis'in ayarlarına bak, sınırı deney için 4 MB'a çek (64 MB'ı küçük linklerle doldurmak dakikalar
   sürer; politika aynı kalır: `noeviction`) ve önbelleği boşalt:
```bash
cd "$LADDER/04-redis-cache"
make fresh
rpod=$(kubectl -n lvl04 get pod -l app.kubernetes.io/name=redis -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "redis pod: $rpod"
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli CONFIG GET maxmemory
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli CONFIG GET maxmemory-policy
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli CONFIG SET maxmemory 4mb
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli FLUSHDB
```
2. Önbelleği doldur: 1200 link, her biri ~6 KB URL; her birini oluştur ve bir kez oku (okuma önbelleğe yazar):
```bash
cd "$LADDER/04-redis-cache"
export PAD=$(head -c 6000 /dev/zero | tr '\0' 'x')
seq 1 1200 | xargs -P 20 -n 1 sh -c 'c=$(curl -s -XPOST http://lvl04.localtest.me/api/links -H "Content-Type: application/json" -d "{\"url\":\"https://example.com/fill/$1?p=$PAD\"}" | jq -r .code); curl -s -o /dev/null --max-time 5 http://lvl04.localtest.me/$c' _
```
3. 15 sn bekle; Redis doluluğunu, anahtar sayısını, SET hatalarını, atılan anahtarları ve logdaki OOM satırlarını oku:
```bash
cd "$LADDER/04-redis-cache"
sleep 15
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli INFO memory | grep -E '^(used_memory|maxmemory):'
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli DBSIZE
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(cache_errors_total{namespace="lvl04",op="set"}[10m]))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(redis_evicted_keys_total{namespace="lvl04"}[10m]))' | jq -r '.data.result[0].value[1]'
kubectl -n lvl04 logs -l app.kubernetes.io/name=linkly --tail=400 | grep -ci 'OOM command not allowed'
```
4. Geri al: sınırı 64 MB'a döndür ve önbelleği boşalt:
```bash
cd "$LADDER/04-redis-cache"
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli CONFIG SET maxmemory 64mb
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli FLUSHDB
```

**Terminalde ne görmelisin:** 1. adımda `maxmemory` → `67108864` (64 MB), politika `noeviction`, iki `OK`. 3. adımda
`used_memory` `maxmemory:4194304`'e dayanmış; `DBSIZE` 1200'ün altında (yalnızca sığanlar girdi); SET hatası sıfırdan
büyük, atılan anahtar `0`; logda `OOM command not allowed` satırları. `eviction = 0` ile `SET hatası > 0` yan yana =
`noeviction` imzası (`allkeys-lru` olsaydı eviction olur, SET hatası olmazdı). 4. adımda iki `OK`.

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) — doldurma saniyeler sürer; deneyden sonra aç
- "Bellek ve üst sınır" → `üst sınır` deney süresince 64 MB'tan **4 MB**'a iner; `kullanılan` ona dayanıp **düz** kalır. Geri alınınca `üst sınır` 64 MB'a döner, `kullanılan` düşer.
- "Silinen / süresi dolan anahtar" → `yer açmak için silindi` **0**'da kalır: Redis dolu ama hiçbir şey atmıyor.
- "Önbellek yazma/okuma hatası" → `set` serisi yükselir: her yeni kayıt reddediliyor.
- "Redis ayakta mı" → deney boyunca **1**: bir sağlık kontrolü bu arızayı yakalamaz.

**Nerede çözülüyor:** Seviye içi — `redis-cli CONFIG SET maxmemory-policy allkeys-lru`. Asıl karar: önbelleğin boyutu
çalışma kümesini karşılıyor mu? Karşılamıyorsa LRU yalnızca düşüşü kibarlaştırır.

---

### P04-07 · TRAP · `KEYS *` tek komutla tüm Redis'i kilitler

**Ne deniyoruz:** "Sadece debug için" bir `KEYS *` çağrısı bütün redirect'leri yavaşlatır mı?
**Neden:** Redis tek iş parçacıklıdır: bir komut çalışırken diğerleri sırada bekler. `KEYS` bütün anahtar uzayını tarar
(O(N)); milyon anahtarda saniyelerce tam durma.

**Reproduce (adım adım):** Otomatik: `make repro P=P04-07` (tuzağı açar, Redis'e 300 bin anahtar yazar — `FILL=` ile
değişir —, aynı yükü iki kez 45'er sn verir, ikincisinin ortasında `/debug/keys`'i 20 sn aralıksız çağırır — `KEYS_SECS=`
—, iki fazın tepe p99'unu kıyaslar; hüküm: KEYS fazı tabanın 1,5 katından büyük). Elle — iki terminal gerekir:

1. Temiz başla; tuzağı aç (`GET /debug/keys` ucu `KEYS *` çalıştırır; pod'lar yeniden başlar):
```bash
cd "$LADDER/04-redis-cache"
make fresh
make set E="TRAP_DEBUG_KEYS=true"
```
2. Redis'i üretim boyutuna getir (bu kümenin kendi trafiği birkaç bin anahtar tutar, o boyutta `KEYS` milisaniyenin
   altında biter): tek bir Lua komutuyla 300 bin süresiz anahtar yaz (~20 MB), 200 gerçek link oluşturup oku, anahtar
   sayısına bak:
```bash
cd "$LADDER/04-redis-cache"
rpod=$(kubectl -n lvl04 get pod -l app.kubernetes.io/name=redis -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "redis pod: $rpod"
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli EVAL "for i=1,tonumber(ARGV[1]) do redis.call('SET','fill:'..i,'x') end return 1" 0 300000
seq 1 200 | xargs -P 20 -n 1 sh -c 'c=$(curl -s -XPOST http://lvl04.localtest.me/api/links -H "Content-Type: application/json" -d "{\"url\":\"https://example.com/k/$1\"}" | jq -r .code); curl -s -o /dev/null http://lvl04.localtest.me/$c' _
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli DBSIZE
```
3. Taban: 45 sn yük ver, 20 sn bekle, pencere içi tepe redirect p99'unu (ms) oku:
```bash
cd "$LADDER/04-redis-cache"
make load S=redirect K6_ARGS="--vus 20 --duration 45s"
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1000 * max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl04",route="/{code}"}[30s])) by (le))[70s:15s])' | jq -r '.data.result[0].value[1]'
```
4. İkinci terminalde aynı yükü başlat:
```bash
cd "$LADDER/04-redis-cache"
make load S=redirect K6_ARGS="--vus 20 --duration 45s"
```
   Yük başladıktan ~15 sn sonra ilk terminalde `/debug/keys`'i 20 sn aralıksız çağır (durmadan soran bir izleme betiği
   gibi; her satır o çağrıda Redis'in kilitli kaldığı ms), yük bitince aynı tepe p99'u oku:
```bash
cd "$LADDER/04-redis-cache"
end=$((SECONDS + 20)); while [ $SECONDS -lt $end ]; do curl -s --max-time 30 http://lvl04.localtest.me/debug/keys | jq -r .took_ms; done
sleep 30
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1000 * max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl04",route="/{code}"}[30s])) by (le))[70s:15s])' | jq -r '.data.result[0].value[1]'
```
5. Doldurma anahtarlarını sil ve tuzağı kapat:
```bash
cd "$LADDER/04-redis-cache"
kubectl -n lvl04 exec "$rpod" -c redis -- redis-cli EVAL "for i=1,tonumber(ARGV[1]) do redis.call('DEL','fill:'..i) end return 1" 0 300000
make reset
```

**Terminalde ne görmelisin:** 2. adımda `(integer) 1` ve `DBSIZE` 300 binin biraz üstü. 4. adımdaki döngü her çağrıda
`took_ms` basar: onlarca milisaniye — Redis'in o sürede başka hiçbir komut çalıştırmadığı süre (uç yalnızca
`linkly:link:*` döndürür ama `KEYS` bütün uzayı tarar). Son tepe p99, 3. adımdaki tabanın üstünde (script 1,5 katından
fazlasını arar): Redis, `KEYS` sürerken GET'leri sıraya aldı.

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl04&from=now-15m&to=now&refresh=10s) — iki faz (temiz, `KEYS *`'li) 45'er sn; bitince aç
- "Komutlar (türe göre)" → `keys` serisi yalnızca ikinci fazda belirir; `get`'in yanında görünmeyecek kadar küçük, lejantta `keys`'e tıkla. Üretimde bu seri hiç olmamalı.
- "p99 süre (uç noktaya göre)" → `/{code}` p99'u ikinci fazda, `KEYS` anlarında birinci fazın tepesinin üstüne çıkar.
- "Uygulama → Redis gecikmesi (p99)" → bu seviyede **boş** (10'dan itibaren ölçülür); gecikmeyi yukarıdaki p99'dan oku.
- Explore'da: `redis_commands_duration_seconds_total{namespace="lvl04",cmd="keys"} / redis_commands_total{namespace="lvl04",cmd="keys"}` → tek bir `KEYS` çağrısının ortalama süresi (sn); `cmd="get"` ile kıyasla: kat kat uzun.

**Nerede çözülüyor:** Seviye içi — `TRAP_DEBUG_KEYS` kapalıyken uç yok. Güvenli karşılığı `SCAN` (imleçli, çağrı başına
sınırlı iş); akrabaları `FLUSHALL`, büyük `HGETALL`, sınırsız `SMEMBERS`.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_NO_TTL_JITTER` | TTL'e rastgelelik eklemez | `make repro P=P04-04` | Bayrağı kapat |
| `TRAP_READ_FILL_DELAY_MS` | Okuma yolunda DB'den alma ile önbelleğe yazma arasına gecikme koyar | `make repro P=P04-05` | Pencereyi daralt (yapısal olarak kapatılamaz) |
| `TRAP_DEBUG_KEYS` | `GET /debug/keys` ucunu açar (`KEYS *`) | `make repro P=P04-07` | Ucu kaldır; `SCAN` kullan |
| `TRAP_NO_NEGATIVE_CACHE` | (03'ten devam) "yok" cevabını önbelleklemez | `make repro P=P03-06` (03'te) | Bayrağı kapat |

Elle denemeye değer:
- `redis-cli CONFIG SET maxmemory-policy allkeys-lru` sonra P04-06'yı tekrar koş: SET hatası biter, eviction başlar — aynı dolu önbellek, farklı arıza.
- `make set E="REDIS_TIMEOUT=5s"` + `make chaos C=redis-delay-3s`: yavaş bir önbelleği beklemek DB'ye gitmekten kötüdür.
- `make load S=scan` ve `06 · Redis` → "Redis'te bulundu / bulunamadı": negatif önbellek Redis'te de çalışıyor mu?
- `kubectl -n lvl04 scale statefulset redis --replicas=0` + `make load S=mixed`: sistem 02 davranışına döner — önbellek bir katman, bağımlılık değil.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now) | **Dolu** | redis_exporter: komutlar, bulundu/bulunamadı, bellek, atılan anahtar |
| [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now) | Dolu | `layer="l2"` (03'te `l1`: aynı panel, farklı katman); arama süresi yalnızca Explore'da (P04-02) |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl04&from=now-15m&to=now) | Dolu | Çok daha az okuma |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl04&from=now-15m&to=now) · [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl04&from=now-15m&to=now) · [`01 · Pods`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl04&from=now-15m&to=now) · [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl04&from=now-15m&to=now) · [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl04&from=now-15m&to=now) | Dolu | — |
| [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl04&from=now-15m&to=now) · [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl04&from=now-15m&to=now) · [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl04&from=now-15m&to=now) · [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl04&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl04&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl04&from=now-15m&to=now) | Boş | Bu seviyede o bileşenler yok |

Asıl egzersiz: `level` seçicisini `lvl03` ↔ `lvl04` arasında değiştirip aynı yükte hit oranını ve DB sorgularını kıyasla.

## 9. Bilerek bırakılanlar

- Redis tek kopya; Sentinel/cluster yok, kalıcılık kapalı (P04-01 → 14).
- `maxmemory 64mb` + `noeviction` (P04-06).
- Süreçler arası singleflight yok (gerekçe `internal/cache/redis.go`'da).
- Cache-aside yarışı açık (P04-05): azaltılabilir, yok edilemez.
- L1 yok: her isabet ağ üzerinden (P04-02, P04-03 → 14).
- Tıklama sayacı hâlâ istek yolunda ve DB'de (P02-08 → 05).
- 02'den devreden: tek Postgres, havuz limiti, düz metin sırlar, süreç içi hız sınırı.

## 10. `make diff-prev` okuma rehberi

`cd "$LADDER/04-redis-cache" && make diff-prev` 03 ile farkı gösterir; şunlara bak:

1. `internal/cache/redis.go` (yeni); `cache.go` duruyor ama bağlı değil — L1 14'te geri gelir.
2. `internal/store/cached.go`: dekoratör neredeyse aynı; değişen önbelleğin nerede durduğu ve `Invalidate`'in `ctx` alması.
3. `deploy/redis.yaml` (yeni): tek replika, `maxmemory 64mb`, `noeviction`, kalıcılık kapalı — her biri bir sorunun kaynağı.
4. `deploy/deployment.yaml`: pod bellek limiti 384Mi → 256Mi; P03-03'ün çarpanı kalktı.
5. `internal/httpapi/handlers.go`: `/debug/keys` yalnızca tuzak açıkken kayıtlı — tehlikeli şey varsayılan olarak kapalı.
