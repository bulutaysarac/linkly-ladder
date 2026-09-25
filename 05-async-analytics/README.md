# 05 — async-analytics · "Yazmayı okuma yolundan çıkar"

> **Bu seviyede ne yaşayacaksın?**
> - Tıklama sayacı istek yolundan çıkınca sıcak satır kilidinin kalkması (P02-08 kapanır)
> - Pod sert öldürülünce tampondaki tıklamaların kaybolması (P05-01); kuyruk dolunca tıklamaların düşürülmesi — ve beklemenin neden daha kötü olduğu (P05-02)
> - Yazıcının okumayla aynı süreci ve bağlantı havuzunu paylaşması (P05-03); günlük toplamanın ölçeklenip ayrıntının ölçeklenmemesi (P05-04)
> - Kısa `terminationGracePeriodSeconds`'ın boşaltmayı yarıda kesmesi (P05-05); tuzak: 301'in tarayıcıda sayılamayan tıklama üretmesi (P05-06)
>
> **Bu seviye olmasa ne olur?** Popüler bir linkin her tıklaması aynı satırı kilitler ve her redirect bu yazmayı bekler (P02-08).
>
> **Yeni gelen teknolojiler:** Go channel ile sınırlı kuyruk, toplu (batch) yazıcı, `clicks_daily` toplama tablosu, `07 · Analytics` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Her yönlendirme artık tıklamayı sınırlı bir süreç içi kuyruğa bırakıp döner; ayrı bir goroutine olayları toplayıp
toplu olarak `clicks_daily` tablosuna yazar. Sıcak satır kilidi kalkar. Bedeli: kuyruk **en fazla bir kez**
teslim eder — dolu kuyruk tıklama düşürür, sert ölüm tampondakini kaybeder.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress] --> A

  subgraph A["linkly pod (× 3)"]
    direction TB
    H["redirect handler<br/>Record() — bloklamaz"]
    Q["bounded channel<br/>20 000 olay"]
    W["batch writer<br/>500 olay / 1 sn"]
    H -->|"non-blocking send"| Q --> W
  end

  A -->|"GET (cache-aside)"| R[(redis)]
  W -->|"tek UPSERT / parti"| PG[("postgres<br/>clicks_daily")]
  A -.->|"yalnızca MISS"| PG
```

Okuma yolu DB'ye hiç yazmaz; yazıcı geri kalsa bile kullanıcı beklemez (`TestRecordNeverBlocks` bunu sabitler).

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P02-08 | Sıcak link → satır kilidi kuyruğu | Yazma istek yolundan çıktı ve toplanıyor: aynı koda gelen 1000 tıklama tek satır güncellemesi. Anahtar ne kadar sıcaksa toplama o kadar iyi |

`links.clicks` yerine `(code, day)` başına tek satır tutan `clicks_daily` geldi (`migrations/003`).

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/05-async-analytics"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl05.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl05 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P05-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl05 ayakta` yazar:
```bash
cd "$LADDER/04-redis-cache"
make down
cd "$LADDER/05-async-analytics"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/05-async-analytics"
make up
```
2. 04'ün sorunlarını burada koş (yedi script art arda, uzun sürer; koşarken başka komut çalıştırma). `CONFIRM=1`,
   Redis pod'unu silen P04-01'in de koşmasını sağlar. `BEKLENEN` sütunu burada hep `(açık kalabilir)` der: 05, 04'ün
   önbellek sorunlarını değil tıklama yazımını değiştirir; `SONUÇ` hangilerinin sürdüğünü gösterir:
```bash
cd "$LADDER/05-async-analytics"
CONFIRM=1 make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P05-01 → P05-06): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç. Yıkıcı scriptler `CONFIRM=1` ister.
4. Bitince ayarları geri al ve seviyeyi kapat:
```bash
cd "$LADDER/05-async-analytics"
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyede yeni: **`GET /api/links/{code}/stats`** → `{"code","clicks","by_day":[…]}`. Yanıt
`X-Stats-Freshness: eventual` taşır: kuyruk boşalmadıysa son saniyelerin tıklamaları henüz görünmez.

## 6. Reproduce edilebilir sorunlar

Her sorun aynı düzende: **Ne deniyoruz** (deneyin sorusu) → **Neden** → adımlar (her adım ne yaptığını söyler)
→ **Terminalde ne görmelisin** → **Grafana'da gör** (giriş: admin / ladder) → **Nerede çözülüyor**.
`make repro` hükmü: `REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` = ölçülemedi.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P05-01 | At-most-once: sert ölümde tampon kaybolur | `CONFIRM=1 make repro P=P05-01` | görünmez — kanıt terminalde ↓ | 06 |
| P05-02 | Kuyruk dolunca düşürme (ve sınırsızın daha kötü olması) | `make repro P=P05-02` | [07 · Analytics](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl05&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl05&from=now-15m&to=now&refresh=10s) → "Kuyruk doluluğu (pod'a göre)" | 06 · 07 |
| P05-03 | Yazıcı, okumayla aynı süreç ve havuzu paylaşıyor | `make repro P=P05-03` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl05&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl05&from=now-15m&to=now&refresh=10s) → "Veritabanı sorguları (türe göre)" | 06 · 07 |
| P05-04 | Toplama ölçeklenir, ayrıntı ölçeklenmez | `make repro P=P05-04` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl05&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl05&from=now-15m&to=now&refresh=10s) → "Sorgu süresi p99 (türe göre)" | 09 (partition) |
| P05-05 | Kısa grace → drain yarıda kalır | `CONFIRM=1 make repro P=P05-05` | görünmez — kanıt terminalde ↓ | seviye içi |
| P05-06 | **TRAP** 301 → sayılamayan tıklama | `make repro P=P05-06` | görünmez — kanıt terminalde ↓ | seviye içi |

---

### P05-01 · At-most-once: sert ölümde tampondaki tıklamalar kaybolur

**Ne deniyoruz:** Pod sert öldürülünce (SIGKILL) kuyruktaki tıklamalar yazılıyor mu?
**Neden:** Kuyruk süreç belleğinde. Düzgün kapanışta `Stop()` kuyruğu boşaltır; sert ölümde boşaltacak kimse kalmaz.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P05-01` (tamponu 15 sn'ye açar, bir linke 400 tıklama
üretip pod'ları `--force` ile öldürür, aynısını `rollout restart` ile tekrarlar; sert ölümde kayıp %10'u geçerse
`REPRODUCED`). Elle:

1. Temiz başla; tamponu görünür yap (flush 15 sn, parti 5000 — varsayılan 1 sn'lik tampon hep boş yakalanır), pod'lar
   yeniden başlarken 10 sn bekle:
```bash
cd "$LADDER/05-async-analytics"
make fresh
make set E="ANALYTICS_FLUSH_INTERVAL=15s ANALYTICS_BATCH_SIZE=5000"
sleep 10
```
2. **Yıkıcı:** bir linke 400 tıklama, sonra kuyruk boşalmadan bütün uygulama pod'larını sert öldür (birkaç saniyelik
   kesinti); yeni pod'lar hazır olunca sayaca bak:
```bash
cd "$LADDER/05-async-analytics"
code=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/atmostonce"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 400); do curl -s -o /dev/null http://lvl05.localtest.me/$code; done
kubectl -n lvl05 delete pod -l app.kubernetes.io/name=linkly --force --grace-period=0
sleep 5
kubectl -n lvl05 wait --for=condition=Ready pod -l app.kubernetes.io/name=linkly --timeout=90s
sleep 6
curl -s http://lvl05.localtest.me/api/links/$code/stats | jq .clicks
```
3. Karşılaştırma: aynı senaryo düzgün kapanışla (`rollout restart`: her pod önce kuyruğunu boşaltır):
```bash
cd "$LADDER/05-async-analytics"
code2=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/graceful"}' | jq -r .code); echo "kod: $code2"
for i in $(seq 1 400); do curl -s -o /dev/null http://lvl05.localtest.me/$code2; done
kubectl -n lvl05 rollout restart deploy/linkly
kubectl -n lvl05 rollout status deploy/linkly --timeout=180s
sleep 8
curl -s http://lvl05.localtest.me/api/links/$code2/stats | jq .clicks
```
4. Ayarları geri al:
```bash
cd "$LADDER/05-async-analytics"
make reset
```

**Terminalde ne görmelisin:** 2. adımda 400'ün belirgin biçimde altında bir sayı; bir dakika sonra da yükselmez —
son flush'tan sonraki tıklamalar ölen pod'ların belleğindeydi. 3. adımda `400` ya da çok yakını: kapanan her pod
kuyruğunu yazıp çıktı. Boşaltma planlı kapanışı kurtarır, plansız ölümü kurtaramaz.

**Grafana'da gör:** Grafana'da görünmez — kaybolan tıklamalar ölen pod'un belleğindeydi ve o pod'un sayaçları da onunla gitti; tampon hiçbir panelde yok. Gerçeğin tek kaynağı DB. Kanıt terminalde:
- `CONFIRM=1 make repro P=P05-01` → `sert ölüm: 400 tıklama üretildi, kaydedilen … → KAYIP …` satırında büyük kayıp, `graceful: … → KAYIP …` satırında sıfıra yakın
- `curl -s http://lvl05.localtest.me/api/links/<kod>/stats | jq .clicks` → sert ölümden sonra gönderilenin altında kalır ve yükselmez

**Nerede çözülüyor:** 06 — olaylar dayanıklı bir loga yazılır (en az bir kez); yeni sorun çift sayma olur.

---

### P05-02 · Kuyruk dolunca düşürme — ve alternatifinin neden daha kötü olduğu

**Ne deniyoruz:** Yazıcı yavaşlayınca ne olur: tıklamalar mı düşer, redirect'ler mi yavaşlar?
**Neden:** Kuyruk dolunca `Record()` tıklamayı düşürür ve sayar. Bu kasıtlı: bekleyen bir gönderim redirect'i yine
DB'ye bağlardı.

**Reproduce (adım adım):** Otomatik: `make repro P=P05-02` (kuyruğu 500'e küçültür, önce ısıtır, sonra Postgres'e 2 sn
gecikme ekleyip 80 kullanıcıyla 45 sn tek linke yük verir; düşürülen > 0 ise `REPRODUCED`). Elle:

1. Temiz başla; kuyruğu 500'e küçült ve gecikme yokken ısıt:
```bash
cd "$LADDER/05-async-analytics"
make fresh
make set E="ANALYTICS_QUEUE_SIZE=500"
make load S=hot-key K6_ARGS="--vus 20 --duration 20s"
```
2. Postgres'e 2 sn gecikme ekle (yazıcı yetişemez) ve yoğun tıklama ver (`SEED=1`: gecikmede link oluşturma yavaş
   olduğu için tek link; `HOT_SHARE=1`: bütün tıklamalar ona). Sonra düşürülen, kuyruğa alınan, tepe derinlik ve
   redirect p99'unu (ms) oku:
```bash
cd "$LADDER/05-async-analytics"
make chaos C=pg-delay-2s
SEED=1 HOT_SHARE=1 make load S=hot-key K6_ARGS="--vus 80 --duration 45s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(analytics_events_total{namespace="lvl05",result="dropped"}[5m]))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(analytics_events_total{namespace="lvl05",result="enqueued"}[5m]))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(analytics_queue_depth{namespace="lvl05"})[5m:15s])' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1000 * histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl05",route="/{code}"}[2m])) by (le))' | jq -r '.data.result[0].value[1]'
```
3. Gecikmeyi kaldır, kuyruk boyunu geri al:
```bash
cd "$LADDER/05-async-analytics"
make unchaos C=pg-delay-2s
make reset
```
4. İstersen alternatifi gör: kuyruk sınırsız (`TRAP_UNBOUNDED_QUEUE=true`), aynı gecikme ve yük; düşürme yerine
   tıklamalar pod belleğinde birikir. Düşürme hızına, derinliğe ve belleğe bak, sonra geri al:
```bash
cd "$LADDER/05-async-analytics"
make set E="ANALYTICS_QUEUE_SIZE=500 TRAP_UNBOUNDED_QUEUE=true"
make chaos C=pg-delay-2s
SEED=1 HOT_SHARE=1 make load S=hot-key K6_ARGS="--vus 80 --duration 45s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(analytics_events_total{namespace="lvl05",result="dropped"}[30s]))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(max(analytics_queue_depth{namespace="lvl05"})[1m:5s])' | jq -r '.data.result[0].value[1]'
kubectl -n lvl05 top pod -l app.kubernetes.io/name=linkly
make unchaos C=pg-delay-2s
make reset
```

**Terminalde ne görmelisin:** 2. adımda k6 özeti `5xx=0`; düşürülen sıfırdan büyük, kuyruğa alınan binlerce, tepe
derinlik kapasiteye dayanır (pod başına 500, toplam en fazla 1500) ve redirect p99 düşük kalır: yazıcı boğulurken
okuma yolu etkilenmedi — tasarımın vaadi. 4. adımda düşürme hızı `0` ve derinlik 500'de durmaz; fazlası pod
belleğinde bekliyor (`kubectl top pod`, sınır 256 MiB). Sınırsız kuyruk ertelenmiş bir çöküştür.

**Grafana'da gör:** [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl05&from=now-15m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl05&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl05&from=now-15m&to=now&refresh=10s) — yük bitince aç
- "Kuyruk doluluğu (pod'a göre)" → `kapasite` çizgisi 20 000'den 500'e iner, pod çizgileri ona dayanır: kuyruk dolu. Eksen büyük kalırsa lejantta bir pod'a tıkla.
- "Tıklama olayları (sonuca göre)" → `dropped` serisi belirir; `written` yükle artmaz, yazıcının hızında takılı kalır.
- "p99 süre (uç noktaya göre)" → `/{code}` düşük kalır (okuma yolu etkilenmedi); `/api/links` yükselir (oluşturma DB'ye 2 sn gecikmeyle yazılıyor).
- "Bellek: sınırın yüzde kaçı" → yalnızca 4. adımda yükselir: bekleyen tıklamalar bellekte birikiyor; %100'e değen konteyner öldürülür.
- "Son sonlanma nedeni" → 4. adımda sınıra çarpan konteyner `OOMKilled` (kırmızı): tampondaki her şey gider.

**Nerede çözülüyor:** 06 (dayanıklı log) · 07 (ayrı tüketici).

---

### P05-03 · Yazıcı, okumayla aynı süreci ve havuzu paylaşıyor

**Ne deniyoruz:** Tıklamaları DB'ye yazan iş, redirect'i servis eden pod'ların içinden mi çıkıyor?
**Neden:** Yazma istek yolundan çıktı ama süreçten çıkmadı: aynı pod CPU'su, aynı bağlantı havuzu (`pgxpool`), aynı
veritabanı. Yazıcıyı ayrı ölçekleyemez, ayrı sınırlayamazsın.

**Reproduce (adım adım):** Otomatik: `make repro P=P05-03` (aynı yükü iki kez verir: A'da yazıcının DB işi durdurulmuş,
B'de açık; B'de `write_clicks` uygulama pod'larından çıkıyor ve A'da sıfırlanıyorsa `REPRODUCED`; iki fazın p99'unu da
yan yana basar). Elle:

1. Temiz başla. A fazı: yazıcının DB işini durdur (tıklamalar kuyruğa girer ama yazılmaz), 10 sn bekle, yükü ver:
```bash
cd "$LADDER/05-async-analytics"
make fresh
make set E="ANALYTICS_FLUSH_INTERVAL=1h ANALYTICS_BATCH_SIZE=100000000"
sleep 10
make load S=hot-key K6_ARGS="--vus 80 --duration 45s"
sleep 12
```
2. A'nın ölçüsü: pod başına saniyedeki `write_clicks` sorgusu, redirect p99 ve havuzdan bağlantı alma beklemesi p99 (ms):
```bash
cd "$LADDER/05-async-analytics"
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (pod) (rate(db_queries_total{namespace="lvl05",op="write_clicks"}[1m]))' | jq -r '.data.result[] | "\(.metric.pod) \(.value[1])"'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1000 * histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl05",route="/{code}"}[1m])) by (le))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1000 * histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace="lvl05"}[1m])) by (le))' | jq -r '.data.result[0].value[1]'
```
3. B fazı: yazıcıyı varsayılana döndür, aynı yükü ver:
```bash
cd "$LADDER/05-async-analytics"
make reset
sleep 10
make load S=hot-key K6_ARGS="--vus 80 --duration 45s"
sleep 12
```
4. B'nin ölçüsü, aynı üç sorgu:
```bash
cd "$LADDER/05-async-analytics"
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (pod) (rate(db_queries_total{namespace="lvl05",op="write_clicks"}[1m]))' | jq -r '.data.result[] | "\(.metric.pod) \(.value[1])"'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1000 * histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl05",route="/{code}"}[1m])) by (le))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=1000 * histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace="lvl05"}[1m])) by (le))' | jq -r '.data.result[0].value[1]'
```

**Terminalde ne görmelisin:** 2. adımda ilk sorgu satır basmaz ya da yalnızca `0`: yazıcı durunca uygulama
pod'larından yazma çıkmıyor. 4. adımda her satır bir `linkly-…` pod'u ve değeri sıfırdan büyük: yazma sorguları
redirect'i servis eden süreçlerden çıkıyor. İki fazın p99'ları yakın kalabilir; bu ölçekte bedel gürültü mertebesinde,
hükmün yapıya bakmasının sebebi bu.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl05&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl05&from=now-15m&to=now&refresh=10s) — iki faz bitince aç
- "Veritabanı sorguları (türe göre)" → `write_clicks` A fazında sıfıra iner, B'de yeniden belirir.
- "Uygulama havuzu: bağlantı bekleme (p99)" → iki fazda benzer ve düşük: havuz paylaşılıyor ama bu ölçekte dar boğaz değil.
- "p99 süre (uç noktaya göre)" → `/{code}` iki fazda yakın; küçük fark gürültüden ayırt edilemez.
- Explore'da: `sum by (pod) (rate(db_queries_total{namespace="lvl05",op="write_clicks"}[1m]))` → B'de her seri bir uygulama pod'u (`linkly-…`).

**Nerede çözülüyor:** 06 + 07 — tüketici ayrı bir süreç ve deployment olur: kendi havuzu, CPU sınırı ve ölçeklenmesi.

---

### P05-04 · Toplama ölçeklenir, ayrıntı ölçeklenmez

**Ne deniyoruz:** "Bu kod kaç kez tıklandı?" sorusu, toplama tablosunda ve tıklama başına satır tutan bir ayrıntı
tablosunda ne kadar sürer?
**Neden:** Toplama veriyi yazarken küçültür (kod ve gün başına tek satır); ayrıntı okurken büyür (her tıklama bir satır).

**Reproduce (adım adım):** Otomatik: `make repro P=P05-04` (bir linke 200 tıklama üretip `stats` süresini ölçer; geçici
`clicks_detail`'e aynı koda 2 M satır yazıp iki sorgunun planını karşılaştırır; ayrıntı planı tam taramaysa
`REPRODUCED`). Elle:

1. Temiz başla; Postgres pod'unu bul, bir linke 200 tıklama üret, `stats` süresini ve `clicks_daily` satır sayısını oku:
```bash
cd "$LADDER/05-async-analytics"
make fresh
pgpod=$(kubectl -n lvl05 get pod -l app.kubernetes.io/name=postgres -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "postgres pod: $pgpod"
code=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/stats-scale"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 200); do curl -s -o /dev/null http://lvl05.localtest.me/$code; done
sleep 4
curl -s -o /dev/null -w 'stats süresi: %{time_total} sn\n' http://lvl05.localtest.me/api/links/$code/stats
kubectl -n lvl05 exec "$pgpod" -c postgres -- psql -U linkly -d linkly -tAc 'SELECT count(*) FROM clicks_daily'
```
2. Karşı senaryo: aynı koda 2 milyon satırlık geçici bir `clicks_detail` tablosu kur (Postgres birkaç saniye meşgul):
```bash
cd "$LADDER/05-async-analytics"
kubectl -n lvl05 exec "$pgpod" -c postgres -- psql -U linkly -d linkly -c 'CREATE TABLE IF NOT EXISTS clicks_detail (id bigserial, code text, at timestamptz)'
kubectl -n lvl05 exec "$pgpod" -c postgres -- psql -U linkly -d linkly -c "INSERT INTO clicks_detail (code, at) SELECT '$code', now() - (i || ' seconds')::interval FROM generate_series(1, 2000000) i"
kubectl -n lvl05 exec "$pgpod" -c postgres -- psql -U linkly -d linkly -c 'ANALYZE clicks_detail'
```
3. Aynı soruyu iki tabloya sor; planları ve süreleri karşılaştır:
```bash
cd "$LADDER/05-async-analytics"
kubectl -n lvl05 exec "$pgpod" -c postgres -- psql -U linkly -d linkly -c "EXPLAIN ANALYZE SELECT count(*) FROM clicks_detail WHERE code='$code'"
kubectl -n lvl05 exec "$pgpod" -c postgres -- psql -U linkly -d linkly -c "EXPLAIN ANALYZE SELECT sum(count) FROM clicks_daily WHERE code='$code'"
```
4. Geçici tabloyu düşür:
```bash
cd "$LADDER/05-async-analytics"
kubectl -n lvl05 exec "$pgpod" -c postgres -- psql -U linkly -d linkly -c 'DROP TABLE clicks_detail'
```

**Terminalde ne görmelisin:** 1. adımda `stats süresi` milisaniyeler mertebesinde, `clicks_daily` birkaç satır.
2. adımda `INSERT 0 2000000`. 3. adımda `clicks_detail` planı `Seq Scan` (çoğunlukla `Parallel Seq Scan`) ile 2 milyon
satır tarar; `clicks_daily` planı birkaç satır okur ve `Execution Time`'ı kat kat kısadır. 4. adımda `DROP TABLE`.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl05&from=now-15m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl05&from=now-15m&to=now&refresh=10s) ve [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl05&from=now-15m&to=now&refresh=10s) — deneyden sonra aç; asıl karşılaştırma terminalde (`clicks_detail`'i uygulama değil `psql` sorguluyor)
- "Sorgu süresi p99 (türe göre)" → `stats` serisi düşük; tek çağrı olduğu için bir dakika kadar görünür.
- "İstatistik ucu süresi (p99)" → aynı `stats` çağrısı (kendi etiketi `/api/links/{code}/stats`): düşük.
- "p99 süre (uç noktaya göre)" → `/api/links/{code}/stats` çizgisi düşük.
- "Veritabanı CPU" → deneyin ortasında postgres pod'unda tepe: 2 M satırı üretmek ve taramak. Ayrıntının bedeli yazarken de ödenir.

**Nerede çözülüyor:** Ayrıntı gerçekten gerekiyorsa 09 (güne göre partition, eskileri düşürme). Asıl karar ürün
kararı: ayrıntıdan toplam sonradan türetilir, ama yalnızca toplam yazıldıysa ayrıntı geri gelmez.

---

### P05-05 · Kısa `terminationGracePeriodSeconds` → drain yarıda kalır

**Ne deniyoruz:** Kapanış süresi (grace) kısalınca rollout başına kaybolan tıklama artıyor mu?
**Neden:** Boşaltma kodu doğru olsa da kubelet süre dolunca süreci SIGKILL ile bitirir; boşaltma yarıda kalır.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P05-05` (tamponu 15 sn'ye açar; mevcut ayarla — grace
60 sn, preStop 5 sn, `SHUTDOWN_GRACE=20s` — ve `grace=3s` ile birer linke 2000 tıklama üretip rollout sonrası kaybı
ölçer; kısa grace'te kayıp büyükse `REPRODUCED`). Elle:

1. Temiz başla; tamponu görünür yap (P05-01'deki sebeple), 10 sn bekle:
```bash
cd "$LADDER/05-async-analytics"
make fresh
make set E="ANALYTICS_FLUSH_INTERVAL=15s ANALYTICS_BATCH_SIZE=5000"
sleep 10
```
2. Mevcut ayarla: bir linke 2000 tıklama (20 paralel), rollout, sonra sayacı 5 sn arayla 8 kez oku:
```bash
cd "$LADDER/05-async-analytics"
code=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/grace/ok"}' | jq -r .code); echo "kod: $code"
seq 1 2000 | xargs -P 20 -I{} curl -s -o /dev/null --max-time 5 http://lvl05.localtest.me/$code
kubectl -n lvl05 rollout restart deploy/linkly
kubectl -n lvl05 rollout status deploy/linkly --timeout=200s
for i in $(seq 1 8); do curl -s http://lvl05.localtest.me/api/links/$code/stats | jq .clicks; sleep 5; done
```
3. **Riskli:** grace'i 3 sn'ye, preStop'u 1 sn'ye indir (tek patch'te — Kubernetes ara hâli reddeder); `SHUTDOWN_GRACE`
   hâlâ 20 sn olduğu için kubelet süreci boşaltmadan önce öldürür. Aynı ölçümü tekrarla:
```bash
cd "$LADDER/05-async-analytics"
kubectl -n lvl05 patch deploy/linkly --type=json -p '[{"op":"replace","path":"/spec/template/spec/terminationGracePeriodSeconds","value":3},{"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":1}]'
kubectl -n lvl05 rollout status deploy/linkly --timeout=200s
code2=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/grace/short"}' | jq -r .code); echo "kod: $code2"
seq 1 2000 | xargs -P 20 -I{} curl -s -o /dev/null --max-time 5 http://lvl05.localtest.me/$code2
kubectl -n lvl05 rollout restart deploy/linkly
kubectl -n lvl05 rollout status deploy/linkly --timeout=200s
for i in $(seq 1 8); do curl -s http://lvl05.localtest.me/api/links/$code2/stats | jq .clicks; sleep 5; done
```
4. Geri al (grace 60 sn, preStop 5 sn, tek patch), sonra ortamı:
```bash
cd "$LADDER/05-async-analytics"
kubectl -n lvl05 patch deploy/linkly --type=json -p '[{"op":"replace","path":"/spec/template/spec/terminationGracePeriodSeconds","value":60},{"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":5}]'
kubectl -n lvl05 rollout status deploy/linkly --timeout=200s
make reset
```

**Terminalde ne görmelisin:** 2. adımda sayı `2000`'de ya da çok yakınında durulur: her pod kuyruğunu yazıp çıktı.
3. adımda belirgin biçimde altında durulur ve yükselmez: boşaltma hiç başlamadı. Aynı kod, farklı YAML → farklı
veri kaybı. Kural: grace > preStop + `SHUTDOWN_GRACE` + boşaltma süresi.

**Grafana'da gör:** Grafana'da görünmez — boşaltma sunucu kapandıktan sonra çalışır, yazdığı artışlar `/metrics` kapanmışken sayılır ve Prometheus'a ulaşmaz; rollout pod'u sildiği için "Son sonlanma nedeni" de bir şey göstermez. Kanıt terminalde:
- `CONFIRM=1 make repro P=P05-05` → iki `kayıp: … tıklama` satırı; `grace=3s` fazındaki büyük
- `kubectl -n lvl05 logs -f -l app.kubernetes.io/name=linkly --prefix` (ikinci terminalde) → mevcut ayarda akış `analitik kuyruğu boşaltılıyor` ve `temiz kapandı` ile biter; `grace=3s`'de `readiness düşürüldü, endpoint yayılımı bekleniyor` satırında kesilir

**Nerede çözülüyor:** Seviye içi: grace'i kapanış adımlarının toplamından uzun tut.

---

### P05-06 · TRAP · 301 tarayıcı önbelleği, sayılamayan tıklama üretir

**Ne deniyoruz:** Tarayıcıda 5 kez açılan bir link 5 tıklama olarak sayılıyor mu?
**Neden:** 301 kalıcı yönlendirmedir; tarayıcı sonraki açılışları sunucuya hiç göndermez (P00-10'daki hata, burada
analitiği bozar).

**Reproduce (adım adım):** Otomatik: `make repro P=P05-06` (302 modunda 50 tıklamanın sayıldığını ölçer, tuzağı açıp
iki modun durum kodunu ve `Cache-Control`'ünü karşılaştırır; tarayıcı adımı yalnızca elle). Elle:

1. Temiz başla; varsayılan modda (302 + `no-store`) bir linke curl ile 50 kez git (curl önbellek tutmaz), sayaca ve
   başlıklara bak:
```bash
cd "$LADDER/05-async-analytics"
make fresh
code=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/counted"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 50); do curl -s -o /dev/null http://lvl05.localtest.me/$code; done
sleep 5
curl -s http://lvl05.localtest.me/api/links/$code/stats | jq .clicks
curl -sI http://lvl05.localtest.me/$code | grep -iE '^(HTTP|cache-control)'
```
2. Tuzağı aç (301; pod'lar yeniden başlarken 10 sn bekle), yeni bir linkin başlıklarına bak:
```bash
cd "$LADDER/05-async-analytics"
make set E="TRAP_REDIRECT_301=true"
sleep 10
code2=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/uncounted"}' | jq -r .code); echo "kod: $code2"
curl -sI http://lvl05.localtest.me/$code2 | grep -iE '^(HTTP|cache-control)'
```
3. Asıl kanıt tarayıcı: üçüncü bir linki tarayıcıda 5 kez aç (Chrome'da DevTools → Network ile izle), sayaca bak:
```bash
cd "$LADDER/05-async-analytics"
code3=$(curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/browser"}' | jq -r .code); echo "kod: $code3"
for i in 1 2 3 4 5; do open "http://lvl05.localtest.me/$code3"; sleep 2; done
sleep 5
curl -s http://lvl05.localtest.me/api/links/$code3/stats | jq .clicks
```
4. Tuzağı kapat:
```bash
cd "$LADDER/05-async-analytics"
make reset
```

**Terminalde ne görmelisin:** 1. adımda `50`, `HTTP/1.1 302 Found`, `Cache-Control: no-store, max-age=0`. 2. adımda
`HTTP/1.1 301 Moved Permanently` ve `Cache-Control` yok (hâlâ `302` ise birkaç saniye sonra tekrarla). 3. adımda
`1`: yalnızca ilk açılış sunucuya ulaştı, kalan dördü tarayıcı önbelleğinden (`(disk cache)`). 3. adım ayrı link
kullanır, çünkü 2. adımdaki `curl -sI` de bir tıklama sayılır.

**Grafana'da gör:** Grafana'da görünmez — sunucuya ulaşmayan istek hiçbir metriğe yazılamaz; eksik olan bir çizgi değil, hiç gelmemiş bir istek. Kanıt terminalde ve tarayıcıda:
- `curl -sI http://lvl05.localtest.me/<kod>` → tuzak kapalıyken `302` + `Cache-Control: no-store, max-age=0`; `TRAP_REDIRECT_301=true` iken `301` ve `Cache-Control` yok
- Chrome'da linki 5 kez aç → 2.–5. açılış `(disk cache)`; `curl -s http://lvl05.localtest.me/api/links/<kod>/stats | jq .clicks` → `1`

**Nerede çözülüyor:** Seviye içi: tuzağı kapat (`302` + `Cache-Control: no-store`).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_UNBOUNDED_QUEUE` | Kuyruğu sınırsız yapar (düşürme yerine büyüme) | `make repro P=P05-02` | Bayrağı kapat |
| `TRAP_REDIRECT_301` | 302 yerine 301 döner | `make repro P=P05-06` | Bayrağı kapat |
| `TRAP_DEBUG_KEYS` · `TRAP_NO_TTL_JITTER` · `TRAP_UPDATE_DELAY_MS` | (04'ten devam) | 04'te | — |

Elle denemeye değer:
- `ANALYTICS_FLUSH_INTERVAL=30s` → `stats` tazeliği 30 sn'ye çıkar: tazelik ile yazma yükü arasındaki düğme.
- `ANALYTICS_BATCH_SIZE=1` → toplama kapanır, `write_clicks` sayısı tıklama sayısına eşitlenir.
- `make load S=hot-key` ile `make load S=redirect` altında `analytics_batch_size` histogramını karşılaştır: sıcak anahtar toplamanın en iyi durumu.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl05&from=now-15m&to=now) | **Dolu** ✨ | Kuyruğa alınan/düşürülen/yazılan, kuyruk derinliği, parti süresi/boyutu, `stats` ucu süresi |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl05&from=now-15m&to=now) | Dolu | `op=write_clicks` ve `op=stats` yeni; `increment_clicks` yok |
| [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl05&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl05&from=now-15m&to=now) · [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl05&from=now-15m&to=now) · [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl05&from=now-15m&to=now) | Dolu | — |
| [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl05&from=now-15m&to=now) · [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl05&from=now-15m&to=now) | Boş | — |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl05&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl05&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl05&from=now-15m&to=now) | Boş | — |

En öğretici panel "k6 tıklama − DB tıklama" farkı: sıfır değilse ya düşürme (P05-02), ya kayıp (P05-01) ya da henüz
boşalmamış kuyruk. Ayırmak için "Atılan / sn" ve "Kuyrukta bekleyen" panellerine birlikte bak.

## 9. Bilerek bırakılanlar

- En fazla bir kez teslimat: sert ölümde kayıp (P05-01 → 06).
- Kuyruk süreç belleğinde, pod başına; tüketici ayrı süreç değil (P05-03 → 06/07).
- Ayrıntı tablosu yok, yalnızca günlük toplam (P05-04 → gerekirse 09).
- `WriteClicks` idempotent değil: yeniden deneme çift sayar (06'da sorun olur ve orada çözülür).
- `stats` önbelleklenmiyor, kiracı kontrolü yok (13).
- 04'ten devreden: tek Redis, tek Postgres, düz metin sırlar, süreç içi hız sınırı.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 04 ile farkı gösterir:

1. `internal/analytics/analytics.go` (yeni): `Record()`'un `select`/`default` bloğu — gönderebilirsen gönder,
   gönderemezsen düşür ve say. Bekleyen ile beklemeyen gönderim arasındaki fark bir `default:` satırı.
2. `internal/httpapi/handlers.go`: `IncrementClicks(ctx, code)` → `a.clicks.Record(code)`; DB çağrısı kanal
   gönderimine dönüştü.
3. `internal/store/migrations/003_clicks.sql`: `clicks_daily(code, day)`; `links.clicks` duruyor ama yazılmıyor
   (12'de expand/contract ile düşürülür).
4. `cmd/linkly/main.go`: kapanışta `clicks.Stop()` sunucudan **sonra** — önce boşaltmak yeni tıklamaları sahipsiz bırakırdı.
5. `deploy/deployment.yaml`: `terminationGracePeriodSeconds: 40 → 60` — yeni kapanış adımı, büyüyen bütçe (P05-05).
6. `internal/httpapi/server.go`: tek metotlu `ClickRecorder` arayüzü; 06'da arkasına Kafka üreticisi girer.
