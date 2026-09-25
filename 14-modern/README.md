# 14 — modern · "Son hal"

> **Bu seviyede ne yaşayacaksın?**
> - L1 (pod belleği) + L2 (Redis) önbelleğin ağ adımını ve sıcak anahtar yükünü geri alması (P14-01)
> - Tuzak: her L1 kopyasının bir geçersiz kılma kanalı gerektirmesi — Redis pub/sub yayını ve kısa TTL (P14-02)
> - 3 partition ile tüketici replikalarının gerçekten iş bölüşmesi (P14-03)
> - Bu kümede ölçülmüş bir kapasite modeli: kaç istek/sn, önce hangi kaynak tıkanıyor (P14-04)
> - Game day: arızaların üst üste enjekte edilip bütün korumaların birlikte sınanması (P14-05) ve bir "yolun devamı" listesi
>
> **Bu seviye olmasa ne olur?** Her koruma tek başına sınanmış olur ama birlikte hiç; sistemin gerçek tavanı tahmin olarak kalır.
>
> **Yeni gelen teknolojiler:** L1+L2 önbellek, Redis pub/sub ile geçersiz kılma, `allkeys-lru`, 3 partition, kapasite modeli, game day ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Merdivenin son basamağı. Kalan borçları kapatır (L1+L2 ve geçersiz kılma yayını, 3 partition, `allkeys-lru`),
kapasiteyi bu kümede ölçer ve game day ile bütün korumaları aynı anda sınar. Sonunda bir "yolun devamı" listesi var:
biten sistem yoktur, bilinen bir sonraki darboğaz vardır.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) -->|Bearer| I[ingress]
  I --> RS & AS
  subgraph RS["redirect (Rollout, canary)"]
    L1["L1: pod içi LRU<br/>TTL 10s"]
  end
  subgraph AS["api-svc"]
    L1b["L1"]
  end
  RS & AS -->|L1 ıskası| RD[("redis<br/>allkeys-lru<br/>+ pub/sub kanalı")]
  RD -.->|"invalidate yayını"| L1 & L1b
  RS & AS -->|L2 ıskası| PGP["pg-pooler-rw/ro"] --> PG[("CNPG: 1 primary + 1 replika")]
  RS ==>|clicks (3 partition)| K[("redpanda")] ==> CN["analytics ×1-3 (KEDA)"]
  CN --> PGP
```

Okuma önce pod belleğine (L1), ıskada Redis'e (L2), orada da yoksa veritabanına gider; bir link silinince Redis
pub/sub yayını her pod'un L1 kopyasını siler.

## 3. Önceki seviyeden çözülenler

**Hiçbiri** — `problems/SOLVES` bilerek boş. P13-06 (tarama) burada da açık: ölçüsü "tarama 404 üretti mi?"dir ve
tarama her zaman 404 üretir; L1'in negatif kayıtları 404'lerin maliyetini düşürür, varlığını değil. 14 bir düzeltme
değil sentez seviyesidir: katkısı sistemin tamamının aynı anda ayakta kalıp kalmadığını ölçmek (P14-05).

Kapatılan borçlar: P04-02/P04-03 (L1 ile ağ adımı ve sıcak anahtar), P06-03 (3 partition), P04-06 (`allkeys-lru`).

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG, Argo CD + Argo Rollouts, cert-manager + Kyverno**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/14-modern"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl14.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl14.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl14 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P14-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

**API anahtarı:** yönetim uçları (`/api/...`) 13'ten beri `Authorization: Bearer <anahtar>` ister (anahtarlar
`deploy/api-keys.yaml`'da; bu README acme'ninkini kullanır: `acme-key-9f2c`). `GET /{code}` anahtarsızdır.

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl14 ayakta` yazar:
```bash
cd "$LADDER/13-security-tenancy"
make down
cd "$LADDER/14-modern"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/14-modern"
make up
```
2. 13'ün sorunlarını burada koş (~10 dk; koşarken başka komut çalıştırma). 14, 13'ün hiçbir sorununu çözdüğünü iddia
   etmez: `BEKLENEN` sütununda her satır `(açık kalabilir)`; `SONUÇ` sütunu 13'ün deneylerinin (kimlik, RLS,
   NetworkPolicy, Kyverno …) 14'te ne verdiğini gösterir:
```bash
cd "$LADDER/14-modern"
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P14-01 → P14-05): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç. redirect bir Argo Rollout'tur: P14-01 ve P14-02'deki her ayar
   değişikliği bir canary dağıtımıdır ve `make wait` onun bitmesini bekler (~4 dk). P14-05 (game day) yıkıcıdır ve
   ~6 dk sürer; adımlarını ve temizliğini atlama.
4. Bitince ayarları geri al ve seviyeyi kapat:
```bash
cd "$LADDER/14-modern"
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). 13'e göre değişiklik yok.

## 6. Reproduce edilebilir sorunlar

Her sorun aynı düzende: **Ne deniyoruz** (deneyin sorusu) → **Neden** → adımlar (her adım ne yaptığını söyler)
→ **Terminalde ne görmelisin** → **Grafana'da gör** (giriş: admin / ladder) → **Nerede çözülüyor**.
`make repro` hükmü: `REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` = ölçülemedi.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P14-01 | L1'in kazancı: ağ adımı olmadan isabet | `make repro P=P14-01` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-30m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-30m&to=now&refresh=10s) → "Önbellek işlemleri (katman ve sonuca göre)" | seviye içi |
| P14-02 | **TRAP** her kopya bir kanal borçlanır | `make repro P=P14-02` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-30m&to=now&refresh=10s) · [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl14&from=now-30m&to=now&refresh=10s) → "Önbellekten çıkarılma sebepleri" | seviye içi (pub/sub + kısa TTL) |
| P14-03 | Partition tavanı kalktı | `make repro P=P14-03` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl14&from=now-15m&to=now&refresh=10s) → "Onaylama / sn ve tüketici pod sayısı" | seviye içi |
| P14-04 | Kapasite modeli (ölçümle) | `make repro P=P14-04` | [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s) · [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl14&from=now-15m&to=now&refresh=10s) → "İstek / saniye (uç noktaya göre)" | `docs-capacity.md` |
| P14-05 | **GAME DAY**: üç arıza üst üste | `CONFIRM=1 make repro P=P14-05` | [11 · Resilience](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl14&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s) → "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" | prova |

---

### P14-01 · L1'in geri dönüşü

**Ne deniyoruz:** Pod belleğindeki önbellek (L1) açılınca sıcak okumalar Redis'e (L2) gitmeyi bırakıyor mu?
**Neden:** En sıcak anahtarlar L1'den cevaplanınca ağa hiç çıkmaz; 04'teki ağ adımı (P04-02) ve Redis'in tek çekirdek
tavanı (P04-03) geç gelir.

**Reproduce (adım adım):** Otomatik: `make repro P=P14-01` (L1 kapalı ve açık iki fazda `hot-key` yükü verir; okuma
yolundaki L2 erişimini, L1 isabetini ve p50/p99'u karşılaştırır; her `L1_ENABLED` değişikliği bir canary dağıtımıdır
ve script onun bitmesini bekler; hüküm p50'ye değil L1 isabetine ve L2 düşüşüne bakar). Elle (iki canary yüzünden ~10 dk):

1. Temiz başla; L1'i yalnızca redirect'te kapat ve canary'nin bitmesini bekle:
```bash
cd "$LADDER/14-modern"
make fresh
make set E="L1_ENABLED=false" W=redirect
make wait
sleep 10
```
2. 1. faz (yalnızca L2, 04'ün hâli): trafiğin %90'ı tek koda giden 40 sn yük, sonra L2 ve L1 işlem hızını ve p50/p99'u
   (saniye) oku:
```bash
cd "$LADDER/14-modern"
HOT_SHARE=0.9 make load S=hot-key K6_ARGS="--vus 40 --duration 40s"
sleep 12
for q in \
  'sum(rate(cache_ops_total{namespace="lvl14",layer="l2"}[2m]))' \
  'sum(rate(cache_ops_total{namespace="lvl14",layer="l1"}[2m]))' \
  'histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[2m])) by (le))' \
  'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[2m])) by (le))'
do printf '%s → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "0"'; done
```
3. L1'i geri aç (redirect'in ortamı manifestteki hâline döner) ve yine canary'yi bekle:
```bash
cd "$LADDER/14-modern"
make reset W=redirect
make wait
sleep 10
```
4. 2. faz (L1+L2): aynı yük, aynı sayılar ve L1 isabet oranı:
```bash
cd "$LADDER/14-modern"
HOT_SHARE=0.9 make load S=hot-key K6_ARGS="--vus 40 --duration 40s"
sleep 12
for q in \
  'sum(rate(cache_ops_total{namespace="lvl14",layer="l2"}[2m]))' \
  'sum(rate(cache_ops_total{namespace="lvl14",layer="l1"}[2m]))' \
  'histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[2m])) by (le))' \
  'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[2m])) by (le))' \
  'sum(rate(cache_ops_total{namespace="lvl14",layer="l1",result="hit"}[2m])) / clamp_min(sum(rate(cache_ops_total{namespace="lvl14",layer="l1"}[2m])),0.001)'
do printf '%s → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "0"'; done
```

**Terminalde ne görmelisin:** 1. adımda `✔ rollout/redirect: L1_ENABLED=false`, `make wait`'in `… canary adımları
sürüyor (Progressing)...` satırı ve ~4 dk sonra `… sürüm tamam: …`. 2. adımda `layer="l2"` sıfırdan belirgin büyük
(okumaların hepsi Redis'e gidiyor), `layer="l1"` **0** — 0 değilse L1 henüz kapanmamıştır, `make wait`'i tekrar koş.
4. adımda `layer="l1"` yüksek, `layer="l2"` belirgin düşük ve son satır (L1 isabet oranı) 0.5'in belirgin üstünde.
p50 iki fazda aynı ya da biraz düşük: fark histogram kovasından küçük olabilir.

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-30m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-30m&to=now&refresh=10s) ve [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl14&from=now-30m&to=now&refresh=10s) — iki faz var (her biri ~4 dk canary + 40 sn yük), deney boyunca açık tut
- "Önbellek işlemleri (katman ve sonuca göre)" → asıl kanıt: 1. fazda okumalar `l2` serilerinde; 2. fazda `l1` `hit` baskın, `l2` neredeyse sıfır — sıcak okumalar ağa çıkmıyor. 1. fazda `l1` akıyorsa L1 kapanmamıştır.
- "Gecikme (p50 / p95 / p99)" → p50 2. fazda aynı ya da biraz aşağıda; fark kovadan küçükse iki faz aynı görünür.
- "Komut / sn" → Redis'in toplam komut hızı düşmeyebilir, artabilir de (ölçülen: 767 → 1560/s): L1 açıkken pub/sub geçersiz kılma trafiği de Redis komutudur. Okuma yolundaki azalmayı `l2` serileri gösterir.

**Nerede çözülüyor:** bu seviyede (L1+L2). L1 bedava değil; bedeli P14-02'de.

---

### P14-02 · TRAP · Her kopya bir geçersiz kılma kanalı borçlanır

**Ne deniyoruz:** Silinen bir link, her pod'un L1 kopyasından ne kadar hızlı kayboluyor?
**Neden:** L1, gerçeğin N kopyasıdır. Pub/sub yayını açıkken silme her pod'a duyurulur; kapalıyken
(`TRAP_NO_INVALIDATION_PUBSUB`, 03'ün hâli) kopya TTL dolana kadar yaşar — P03-01'in aynısı.

**Reproduce (adım adım):** Otomatik: `make repro P=P14-02` (deney süresince redirect'in `L1_TTL`'ini 90 sn'ye çıkarır
ki pencere ölçülebilsin; en az iki redirect replikası olduğunu doğrular; yayın açık ve kapalıyken "oluştur → 40 okuma
→ sil → 40 okuma" turunu koşar, bayat yönlendirmeleri sayar, bitince geri alır). Elle (üç canary yüzünden ~15 dk):

1. Temiz başla; L1 TTL'ini deney için 90 sn'ye çıkar, canary'yi bekle, replika sayısına bak (en az 2 olmalı: tek
   pod'da bayatlayacak ikinci kopya yoktur):
```bash
cd "$LADDER/14-modern"
make fresh
make set E="L1_TTL=90s" W=redirect
make wait
sleep 10
kubectl -n lvl14 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
```
2. 1. faz (yayın açık): link oluştur, 40 okumayla bütün pod'ların L1'ine sok, sil, aynı kodu 40 kez daha iste; bir
   kazıma bekleyip gönderilen/alınan geçersiz kılma mesajlarını say:
```bash
cd "$LADDER/14-modern"
code=$(curl -s -XPOST http://lvl14.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/inval"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 40); do curl -s -o /dev/null http://lvl14.localtest.me/$code; done
curl -s -o /dev/null -w 'silme: %{http_code}\n' -XDELETE http://lvl14.localtest.me/api/links/$code -H 'Authorization: Bearer acme-key-9f2c'
sleep 1
for i in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code} ' http://lvl14.localtest.me/$code; done; echo
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (direction) (increase(cache_invalidation_messages_total{namespace="lvl14"}[2m]))' | jq -r '.data.result[] | .metric.direction + ": " + .value[1]'
```
3. Tuzağı yalnızca redirect'te aç (L1 var, yayın yok) ve canary'yi bekle:
```bash
cd "$LADDER/14-modern"
make set E="TRAP_NO_INVALIDATION_PUBSUB=true" W=redirect
make wait
sleep 10
```
4. 2. faz (yayın kapalı): aynı tur, yeni bir linkle:
```bash
cd "$LADDER/14-modern"
code=$(curl -s -XPOST http://lvl14.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/inval"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 40); do curl -s -o /dev/null http://lvl14.localtest.me/$code; done
curl -s -o /dev/null -w 'silme: %{http_code}\n' -XDELETE http://lvl14.localtest.me/api/links/$code -H 'Authorization: Bearer acme-key-9f2c'
sleep 1
for i in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code} ' http://lvl14.localtest.me/$code; done; echo
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (direction) (increase(cache_invalidation_messages_total{namespace="lvl14"}[2m]))' | jq -r '.data.result[] | .metric.direction + ": " + .value[1]'
```
5. Geri al (`L1_TTL=10s`, tuzak yok) ve son canary'yi bekle:
```bash
cd "$LADDER/14-modern"
make reset
make wait
```

**Terminalde ne görmelisin:** 1. adımda `✔ rollout/redirect: L1_TTL=90s`, ~4 dk sonra `… sürüm tamam: …` ve `3`.
2. adımda `silme: 204`; sonraki 40 cevap `404` (en fazla birkaç `302`): yayını alan her pod kopyasını sildi. Mesaj
sayımında `sent` ve `received` ikisi de sıfırdan büyük, `received` daha büyük (her mesajı diğer pod'ların hepsi
alır). 4. adımda yine `silme: 204`, ama 40 cevabın çoğu `302`: link silindi, redirect pod'ları onu 90 sn'lik TTL
dolana kadar yönlendirmeye devam ediyor. `sent` yine sıfırdan büyük, `received` neredeyse sıfır.

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-30m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl14&from=now-30m&to=now&refresh=10s) — iki faz var (her biri ~4 dk canary ile başlar), deney boyunca açık tut
- "Önbellekten çıkarılma sebepleri" → 1. fazda silme anında kısa bir `invalidate` tepesi: her pod kopyasını siler. 2. fazda redirect pod'larında bu tepe yok: kopyalar ancak TTL dolunca düşer.
- "Yönlendirme sonuçları" → silinmiş koda yapılan okumalar 1. fazda `not_found`, 2. fazda `ok` — bayat cevap uygulamanın gözünden **başarıdır**.
- Explore'da: `sum by (direction) (increase(cache_invalidation_messages_total{namespace="lvl14"}[2m]))` → 1. fazda `sent` ve `received` birlikte artar; 2. fazda `sent` artar ama `received` neredeyse durur: gönderilen ile alınan arasındaki fark, yayını kaçıran kopyalardır.

**Nerede çözülüyor:** bu seviyede (pub/sub yayını + kısa TTL). Kanal en-iyi-çabadır: Redis yeniden başlarsa ya da mesaj
düşerse kimse fark etmez; kısa TTL (10 sn) bu yüzden bir yedek mekanizmadır ve kaçan bir yayında bayatlık penceresi
tam o kadardır. Alternatifler: sürüm damgalı anahtar · yazmada L1'i atlamak · dayanıklı akışla yayın.

---

### P14-03 · Partition tavanı kalktı

**Ne deniyoruz:** 3 partition ile üç tüketici replikası gerçekten iş bölüşüyor mu?
**Neden:** Bir partition'ı aynı anda tek tüketici okur; 06'da 1 partition vardı ve fazla replika boşta otururdu
(P06-03). 14'te `clicks` topic'i 3 partition, KEDA'nın üst sınırı da 3.

**Reproduce (adım adım):** Otomatik: `make repro P=P14-03` (partition sayısını ve KEDA tavanını okur, tüketiciyi KEDA'nın
`paused-replicas` anotasyonuyla 3 replikaya sabitler — `hot-key` yükünde lag KEDA eşiğinin altında kalır ve KEDA tek
pod'da dururdu —, 60 sn yük verir, kaç pod'un gerçekten kayıt işlediğini sayar ve anotasyonu kaldırır). Elle:

1. Temiz başla; broker hazır olunca `clicks` topic'inin partition'larına ve KEDA'nın üst sınırına bak:
```bash
cd "$LADDER/14-modern"
make fresh
kubectl -n lvl14 wait --for=condition=Ready pod -l app.kubernetes.io/name=redpanda --timeout=180s
rp=$(kubectl -n lvl14 get pod -l app.kubernetes.io/name=redpanda -o jsonpath='{.items[0].metadata.name}'); echo "broker: $rp"
kubectl -n lvl14 exec "$rp" -- rpk topic describe clicks -p
kubectl -n lvl14 get scaledobject analytics -o jsonpath='{.spec.maxReplicaCount}'; echo
```
2. Tüketiciyi 3 replikaya sabitle (KEDA duraklatılır) ve hazır olmasını bekle:
```bash
cd "$LADDER/14-modern"
kubectl -n lvl14 annotate scaledobject analytics autoscaling.keda.sh/paused-replicas=3 --overwrite
sleep 20
kubectl -n lvl14 rollout status deploy/analytics
```
3. İkinci bir terminalde tüketici pod'larını izle:
```bash
cd "$LADDER/14-modern"
kubectl -n lvl14 get pods -l app.kubernetes.io/name=analytics -w
```
4. İlk terminalde 60 sn yük ver, bir kazıma bekle; iş yapan pod sayısını, pod başına işleme hızını ve tepe lag'i oku:
```bash
cd "$LADDER/14-modern"
make load S=hot-key K6_ARGS="--vus 60 --duration 60s"
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=count(count by (pod) (rate(consumer_records_total{namespace="lvl14",result="ok"}[3m]) > 0))' | jq -r '"iş yapan pod: " + (.data.result[0].value[1] // "0")'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (pod) (rate(consumer_records_total{namespace="lvl14",result="ok"}[3m]))' | jq -r '.data.result[] | .metric.pod + ": " + .value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(redpanda_kafka_max_offset{namespace="lvl14"} - on(redpanda_topic, redpanda_partition) group_left redpanda_kafka_consumer_group_committed_offset{namespace="lvl14"})[5m:15s])' | jq -r '"tepe lag: " + (.data.result[0].value[1] // "0")'
```
5. Sabitlemeyi kaldır (KEDA yeniden devreye girer); ikinci terminali Ctrl+C ile kapat:
```bash
cd "$LADDER/14-modern"
kubectl -n lvl14 annotate scaledobject analytics autoscaling.keda.sh/paused-replicas- --overwrite
```

**Terminalde ne görmelisin:** 1. adımda `rpk` tablosunda `0`, `1`, `2` numaralı üç partition ve KEDA üst sınırı `3`
(partition sayısını aşmaz — fazlası boşta otururdu). 2. adımda `… annotated` ve `deployment "analytics" successfully
rolled out`; ikinci terminalde üç `analytics-…` pod'u `1/1 Running`. 4. adımda k6 özeti, `iş yapan pod: 3` ve üç
`analytics-…: …` satırı, üçü de sıfırdan büyük; biri belirgin yüksek — anahtar kısa kod olduğu için sıcak kodun bütün
olayları tek partition'a, yani tek pod'a gider. Tepe lag küçük: tüketiciler yetişiyor. 5. adımdan sonra KEDA'nın
bekleme süresi (`cooldownPeriod: 60`) dolunca pod sayısı düşebilir.

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl14&from=now-15m&to=now&refresh=10s) — tüketici sabitlenip yük başlayınca aç
- "Onaylama / sn ve tüketici pod sayısı" → pod çizgisi deney boyunca 3'te, commit/s yükle yükselir; deney bitince KEDA devreye girer ve pod sayısı düşebilir.
- "Tüketici gecikmesi (bölüme göre)" → üç ayrı çizgi (partition 0, 1, 2); tüketiciler yetiştikçe sıfıra yakın. Biri birikiyorsa o partition'ın tüketicisi darboğazdır.
- Explore'da: `sum by (pod) (rate(consumer_records_total{namespace="lvl14",result="ok"}[1m]))` → üç çizgi, üçü de sıfırın üstünde (tek partition'da yalnızca biri çizgi verirdi); biri belirgin yüksek — partition başına sıranın bedeli.

**Nerede çözülüyor:** bu seviyede (3 partition). Yeni sınır: sıra yalnızca partition içinde garantili, global sıra
yok; partition sayısı azaltılamaz ve artırıldığı an mevcut anahtarlar taşınır. Partition artırmak planlanan bir
değişikliktir.

---

### P14-04 · Kapasite modeli

**Ne deniyoruz:** Günde 100 milyon redirect için kaç pod ve ne kadar DB okuması gerekir — tahminle değil, bu kümede ölçülen sayıyla?
**Neden:** Model yalnızca ölçülen bir "pod başına istek/sn" üzerine kurulabilir; tek pod kademeli yükle doyurulur ve
tavanı okunur.

**Reproduce (adım adım):** Otomatik: `make repro P=P14-04` (redirect'i tek pod'a indirir, `stairs` yükü verir —
varsayılan `RATES=50,100,200,400`, basamak başına ~40 sn —, tepe kabul edilen rps'i, p99'u, CPU'yu, önbellek
isabetini ve DB okumasını okur, modeli basar ve replikayı geri alır) · tam model: [`docs-capacity.md`](docs-capacity.md). Elle (~5 dk):

1. Temiz başla; replika sayısını not et, redirect'i tek pod'a indir ve hazır adresin bire indiğini gör:
```bash
cd "$LADDER/14-modern"
make fresh
kubectl -n lvl14 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
kubectl -n lvl14 scale rollout/redirect --replicas=1
sleep 15
kubectl -n lvl14 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].targetRef.name}'; echo
```
2. Kademeli yük ver (~3 dk), bir kazıma bekle; tek pod'un tepe kabul edilen rps'ini, önbellek isabetini, tepe p99'unu
   (saniye), tepe CPU'sunu (çekirdek) ve DB okumasını oku:
```bash
cd "$LADDER/14-modern"
make load S=stairs
sleep 15
rps=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(rate(http_requests_total{namespace="lvl14",route="/{code}",code!="429",code!="503"}[30s]))[6m:15s])' | jq -r '.data.result[0].value[1] // "0"'); echo "tepe kabul edilen rps: $rps"
hit=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(cache_ops_total{namespace="lvl14",result=~"hit|negative_hit"}[3m])) / clamp_min(sum(rate(cache_ops_total{namespace="lvl14"}[3m])),0.001)' | jq -r '.data.result[0].value[1] // "0"'); echo "önbellek isabet oranı: $hit"
for q in \
  'max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[1m])) by (le))[6m:15s])' \
  'max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="lvl14",pod=~"redirect.*",image!="",image!~".*pause.*"}[30s]))[6m:15s])' \
  'sum(rate(db_queries_total{namespace="lvl14",op="get"}[3m]))'
do printf '%s → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "0"'; done
```
3. Modeli ölçülen sayıyla kur (100 milyon redirect/gün, tepe = ortalamanın 3 katı):
```bash
cd "$LADDER/14-modern"
awk -v rps="$rps" -v hit="$hit" 'BEGIN{avg=100000000/86400; peak=avg*3; printf "ortalama = %.0f rps · tepe (3x) = %.0f rps\n", avg, peak; if (rps>0) printf "gereken pod = %.0f (ölçülen %.0f rps/pod) + yedeklilik + burst tamponu\n", peak/rps+0.999, rps; printf "DB okuma (hit %.0f%%) = %.0f/s · SOĞUK anda = %.0f/s\n", hit*100, peak*(1-hit), peak}'
```
4. İstersen merdiveni tek pod'un tavanının üstüne uzat (bu kümede tek pod ~650 rps; daha yukarısı ölçüm değil yıkım
   üretir), ölçümü ve modeli tekrarla:
```bash
cd "$LADDER/14-modern"
RATES=100,200,400,800 make load S=stairs
sleep 15
rps=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(rate(http_requests_total{namespace="lvl14",route="/{code}",code!="429",code!="503"}[30s]))[6m:15s])' | jq -r '.data.result[0].value[1] // "0"'); echo "tepe kabul edilen rps: $rps"
hit=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(cache_ops_total{namespace="lvl14",result=~"hit|negative_hit"}[3m])) / clamp_min(sum(rate(cache_ops_total{namespace="lvl14"}[3m])),0.001)' | jq -r '.data.result[0].value[1] // "0"'); echo "önbellek isabet oranı: $hit"
awk -v rps="$rps" -v hit="$hit" 'BEGIN{avg=100000000/86400; peak=avg*3; printf "ortalama = %.0f rps · tepe (3x) = %.0f rps\n", avg, peak; if (rps>0) printf "gereken pod = %.0f (ölçülen %.0f rps/pod) + yedeklilik + burst tamponu\n", peak/rps+0.999, rps; printf "DB okuma (hit %.0f%%) = %.0f/s · SOĞUK anda = %.0f/s\n", hit*100, peak*(1-hit), peak}'
```
5. Replikayı `3`'e geri al ve hazır olmasını bekle:
```bash
cd "$LADDER/14-modern"
kubectl -n lvl14 scale rollout/redirect --replicas=3
make wait
```

**Terminalde ne görmelisin:** 1. adımda `3`, `rollout.argoproj.io/redirect scaled` ve tek bir `redirect-…` pod adı.
2. adımda `tepe kabul edilen rps` son basamağa (400) yakınsa pod doymamıştır, ölçtüğün tavan değil verdiğin yüktür
(4. adım); belirgin altındaysa tek pod'un tavanı odur. İsabet oranı yüksek, p99 küçük, CPU bir çekirdek kesri (0.31
çekirdek = Grafana'da %31), DB okuması düşük. 3. adımda `ortalama = 1157 rps · tepe (3x) = 3472 rps`, `gereken pod = …`
ve `DB okuma (hit …%) = …/s · SOĞUK anda = 3472/s`: önbellek soğukken DB tepe trafiğin tamamını görür. 5. adımda
`… hazır: 3/3` ve `… sürüm tamam: …`.

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s), [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl14&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-15m&to=now&refresh=10s) — `stairs` yükü başlayınca aç (~3 dk)
- "İstek / saniye (uç noktaya göre)" → `/{code}` basamak basamak yükselir; son basamakta hedefin altında kalıyorsa tek pod doymuştur — o tavan modelin "pod başına rps"i.
- "Gecikme (p50 / p95 / p99)" → alt basamaklarda düz; pod doymaya yaklaşınca p99 yukarı kıvrılır. Kıvrılmıyorsa `RATES` ile üstüne çık.
- "CPU kullanımı (bir çekirdeğin %'si)" → tek redirect pod'unun çizgisi basamaklarla tırmanır: yük gerçekten koştu.
- "İsabet oranı (toplam)" → yüksek; modelin "DB okuma = tepe × (1 − hit)" satırı buradan gelir. Soğuk anda oran 0'dır ve DB tepe trafiğin tamamını görür (P03-02).

**Nerede çözülüyor:** model [`docs-capacity.md`](docs-capacity.md)'de. En kritik satırı: önbellek soğukken DB tepe
trafiğin tamamını görür — kapasite ortalamaya göre planlanırsa ilk dağıtım sistemi devirir. Belgedeki darboğaz
sıralamasının sonuncusu (tek primary'ye yazma) aşılmadı; sharding ister.

---

### P14-05 · GAME DAY

**Ne deniyoruz:** Redis gecikmesi, DB paket kaybı ve pod ölümü tek bir yük altında üst üste gelince sistem kısmen mi,
tamamen mi bozulur?
**Neden:** Korumalar (breaker, retry, yük atma, önbellek) tek tek sınandı ama birlikte hiç; birlikte davranışları ayrı
bir sorudur ve yalnızca denenerek öğrenilir. Beklenen: kısmi bozulma, tam çöküş değil.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P14-05` (30 sn taban ölçümünden sonra sabit 300 istek/sn
yük altında üç arızayı üst üste bindirir; erişilebilirliği, breaker'ı, yük atmayı, retry'ı ve kalan hata bütçesini
raporlar; arızaları kaldırıp toparlanmayı bekler; kontrol düzlemi yeniden başladıysa hüküm vermez). Elle — **yıkıcı,
~6 dk**: lvl14'te Redis'e 200 ms gecikme, Postgres'e %30 paket kaybı ve bir redirect pod'unun zorla silinmesi; başka
namespace'e dokunulmaz. 4. adımın bloğu arızaları kendisi kaldırır; blok yarıda kesilirse arızalar kalır — **6. adımı
her durumda koş**:

1. Temiz başla; korumaların dinlenmede olduğunu (breaker ve degrade `0`) ve kontrol düzlemi pod'larının yeniden
   başlatma sayılarını gör (6. adımda karşılaştıracaksın):
```bash
cd "$LADDER/14-modern"
make fresh
for q in 'max(breaker_state{namespace="lvl14"})' 'max(degraded_mode{namespace="lvl14"})'; do printf '%s → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "seri yok"'; done
kubectl -n kube-system get pods -l tier=control-plane -o jsonpath='{range .items[*]}{.metadata.name}{" restart="}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```
2. Taban: her şey sağlıklıyken 30 sn sabit 300 istek/sn, sonra p99'u (saniye) oku:
```bash
cd "$LADDER/14-modern"
RATE=300 make load S=steady K6_ARGS="--duration 30s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[2m])) by (le))' | jq -r '"taban p99: " + (.data.result[0].value[1] // "0")'
```
3. Game day yükü: ikinci bir terminalde 150 sn sabit 300 istek/sn başlat:
```bash
cd "$LADDER/14-modern"
RATE=300 make load S=steady K6_ARGS="--duration 150s"
```
4. Yük başlar başlamaz ilk terminalde zaman çizelgesini yapıştır (~1 dk 50 sn): 00:15 Redis +200 ms, 00:45 Postgres %30
   paket kaybı, 01:15 bir redirect pod'u zorla silinir, 01:45 arızalar kalkar:
```bash
cd "$LADDER/14-modern"
sleep 15
echo "[00:15] Redis'e 200 ms gecikme"
make chaos C=redis-delay-200ms
sleep 30
echo "[00:45] Postgres'e %30 paket kaybı"
make chaos C=pg-loss-30
kubectl -n lvl14 get networkchaos
sleep 30
victim=$(kubectl -n lvl14 get pod -l app.kubernetes.io/name=redirect -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty'); echo "[01:15] öldürülen: $victim"
kubectl -n lvl14 delete pod "$victim" --force --grace-period=0
sleep 30
echo "[01:45] arızalar kaldırılıyor"
make unchaos C=redis-delay-200ms
make unchaos C=pg-loss-30
```
5. k6 özeti çıkınca sonuçları oku: istek, 5xx, 429, limiter muafiyeti, breaker/degrade tepesi, yük atma, retry,
   bağımlılık p99 tepeleri (saniye) ve kalan hata bütçesi:
```bash
cd "$LADDER/14-modern"
sleep 12
for q in \
  'sum(increase(http_requests_total{namespace="lvl14",service=~"redirect|api"}[3m]))' \
  'sum(increase(http_requests_total{namespace="lvl14",service=~"redirect|api",code=~"5.."}[3m]))' \
  'sum(increase(http_requests_total{namespace="lvl14",service=~"redirect|api",code="429"}[3m]))' \
  'sum(increase(ratelimit_decisions_total{namespace="lvl14",decision="exempt"}[3m]))' \
  'max_over_time(max(breaker_state{namespace="lvl14"})[5m:15s])' \
  'max_over_time(max(degraded_mode{namespace="lvl14"})[5m:15s])' \
  'sum(increase(load_shed_total{namespace="lvl14"}[5m]))' \
  'sum(increase(retry_total{namespace="lvl14"}[5m]))' \
  'max_over_time(histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace="lvl14",dep="redis"}[1m])) by (le))[5m:15s])' \
  'max_over_time(histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace="lvl14",dep="postgres"}[1m])) by (le))[5m:15s])' \
  'slo:period_error_budget_remaining:ratio{namespace="lvl14",sloth_slo="redirect-availability"}'
do printf '%s\n    → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "seri yok"'; done
```
6. Temizlik — her durumda koş: kalan chaos nesnelerini sil, kalmadığını doğrula, her şey hazır olana kadar bekle,
   kontrol düzlemi sayılarını 1. adımla karşılaştır:
```bash
cd "$LADDER/14-modern"
make unchaos
kubectl -n lvl14 get networkchaos
make wait
kubectl -n kube-system get pods -l tier=control-plane -o jsonpath='{range .items[*]}{.metadata.name}{" restart="}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```

**Terminalde ne görmelisin:** 1. adımda iki satır `→ 0` ve her kontrol düzlemi pod'u için `restart=` sayısı. 2. adımda
`taban p99: …` (küçük). 4. adımda iki `networkchaos… created`, ikisini listeleyen tablo, `[01:15] öldürülen: redirect-…`
ve `force deleted`. k6 özetinde `5xx` sıfırdan büyük ama `reqs`'in küçük bir payı: erişilebilirlik (1 − 5xx/reqs)
%50'nin üstünde — kısmi bozulma. 5. adımda uygulamanın 5xx'i k6'nınkinden küçük ya da eşit (fark ingress'in cevabı),
429 ~0, muafiyet sıfırdan büyük; breaker tepesi `0`–`2` (yalnızca `postgres`'inki hareket edebilir), yük atma çoğu
zaman `0`, `dep="redis"` p99 tepesi ~0.2 (0.15'in altındaysa gecikme Redis'e ulaşmamış), `dep="postgres"` tabandan
yüksek, kalan hata bütçesi aşağı (eksi bile olabilir). 6. adımda `No resources found in lvl14 namespace.`,
`pg hazır: 2/2`, `redirect hazır: 3/3` ve kontrol düzlemi sayıları aynı; artmışsa sonuç kümeyi ölçüyor, uygulamayı
değil — game day'i küme sakinken tekrarla.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl14&from=now-15m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s), [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl14&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl14&from=now-15m&to=now&refresh=10s) — game day başlamadan aç; arızalar 00:15, 00:45 ve 01:15'te gelir, 01:45'te kalkar
- "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" → başta **0**; `redis` ve `kafka` hep 0 (etraflarında breaker yok). Yalnızca `postgres` hareket edebilir: paket kaybı önbellek ıskalarının sorgularını düşürürse 1–2'ye çıkar; çıkmıyorsa önbellek yükü emmiştir — bu da bir sonuç.
- "Bağımlılık gecikmesi p99" → `redis` 00:15'te ~200 ms'ye sıçrar ve 01:45'e kadar kalır; `postgres` 00:45'ten sonra yükselir. Her bağımlılık kendi çizgisinde: biri diğerinin gecikmesini taşımaz.
- "Uygulama → Redis gecikmesi (p99)" (06 · Redis) → aynı ~200 ms platosu, uygulamanın gördüğü Redis gecikmesi.
- "Şu an işlenen istek (pod'a göre)" → 00:15'te yükselir ama yük atma eşiğinin (`SHED_MAX_INFLIGHT=200`) çok altında kalır; "Hazır pod adresi (endpoint) sayısı" 01:15'te bir basamak iner, yeni pod hazır olunca çıkar.
- "İstek / saniye (durum koduna göre)" (App RED) ile "Dönen durum kodları" (k6) → uygulamanın saydığı 5xx ile istemcinin gördüğü 5xx arasındaki fark, araya giren katmanın (ingress) cevabıdır.
- Explore'da: `slo:period_error_budget_remaining:ratio{namespace="lvl14",sloth_slo="redirect-availability"}` → game day'in 5xx'leri kalan bütçeyi aşağı çeker (`12 · SLO` → "Kalan hata bütçesi" aynı seri); Prometheus 48 saat tuttuğu için değer önceki deneylerin izini de taşır, eksi olabilir.

**Nerede çözülüyor:** bu bir test değil, provadır: amaç geçmek değil, hangi korumanın ne zaman devreye girdiğini
görmek ve runbook'u buna göre yazmak.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_NO_INVALIDATION_PUBSUB` | L1 var, yayın yok (03'ün hâli) | `make repro P=P14-02` | Bayrağı kapat |
| `L1_ENABLED` / `L1_TTL` | Tuzak değil, ayar düğmesi | P14-01 / P14-02 | Ölç, sonra karar ver |

Elle denemeye değer:
- `L1_TTL=5m` yap ve P14-02'yi tekrar koş: bayatlık penceresi 5 dakikaya çıkar — kısa TTL'in neden yedek mekanizma olduğunu gösterir.
- `tools/ladder-matrix/run.sh` ile bütün seviyelerin scriptlerini bu seviyede koş: çözülmüş her sorun `NOT-REPRODUCED`
  olmalı; olmayan ya bilerek bırakılmıştır ya da bir regresyondur.
- `make chaos C=redis-kill` + `make load S=mixed`: Redis ölse bile en sıcak anahtarlar L1'den cevaplanır; P04-01'i burada koş ve farkı gör.
- 00 ile 14'ü aynı panelde yan yana koy (`level` seçici): aynı yük, aynı paneller, on dört basamak fark.

## 8. Gözlemlenebilirlik: hangi paneller dolu

Neredeyse hepsi dolu (00'da yalnızca `Pods & Resources` ve `k6` doluydu). Bilinen boşluk: `05 · Postgres`'in
postgres_exporter panelleri (CNPG'de exporter yok; havuz ve sorgu panelleri uygulamadan geldiği için dolu).
`13 · Rollout`'un sürüme göre panelleri pod şablonu hash'iyle ayrılır; `11 · Resilience` → "Bağımlılık gecikmesi p99"
`postgres` ve `redis`'i ayrı çizer.

Yeni metrik `cache_invalidation_messages_total{direction}`: gönderilen ile alınan arasındaki fark, kaç pod'un yayını
kaçırdığını söyler; sessizce büyüyorsa tek savunma L1 TTL'idir.

## 9. Bilerek bırakılanlar — "yolun devamı"

Her madde gerçek bir sonraki adım:

| Alan | Eksik | Sonraki adım |
|---|---|---|
| Altyapı | Tek Redis (P04-01) | Sentinel/Valkey HA ya da cluster |
| Altyapı | Tek broker, RF=1 (P06-05) | Çok broker, replikasyon |
| Altyapı | Tek bölge, tek küme | Çok bölgeli aktif-aktif, DNS failover |
| Altyapı | Küme ölçekleyici yok (P07-05) | Karpenter / Cluster Autoscaler |
| Altyapı | Yedekleme/PITR yok (P09-06) | barman + nesne deposu + geri yükleme tatbikatı |
| Uygulama | Yazma yolu tek primary | Sharding (kapasite modelinin son darboğazı) |
| Uygulama | gRPC yok (P07-06), Gateway API yok | Batch + gRPC; Gateway API + service mesh (mTLS) |
| Uygulama | Tier kotaları bağlı değil (13), 404 oranı limiti yok (P13-06) | Limiter'ı kimliğe bağlamak |
| Süreç | CI imaj yayınlamıyor; tarama/imza/SBOM yok (P13-08) | Trivy, cosign, SBOM |
| Süreç | Argo CD Application tanımsız (P12-03) | GitOps'u bağlamak |
| Süreç | Sırlar düz metin (P13-04) | SealedSecret |
| Süreç | Alertmanager hedefi yok (11), sürekli profil yok (P11-08) | Bildirim hedefi, Pyroscope |
| Süreç | Maliyet modeli yok | Kapasite modeline bulut faturası |

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 13 ile farkı gösterir:

1. `internal/cache/tiered.go` (yeni): L1 + L2 + pub/sub; yorumdaki muhasebe — L1'in bedeli bir kanal, kısa bir TTL ve
   ölçülüp kabul edilen bir tutarsızlık penceresi.
2. `internal/store/cached.go`: `CacheLayer` arayüzü ve `invalidate`; dekoratör altındaki katmanın L2 mi Tiered mi
   olduğunu bilmez.
3. `deploy/redis.yaml`: `noeviction` → `allkeys-lru` (P04-06).
4. `deploy/redpanda.yaml`: 1 → 3 partition; `deploy/keda.yaml`: maxReplicas 6 → 3 (partition sayısını aşmak boşa gider).
5. `docs-capacity.md` (yeni): ölçülmüş sayılarla kapasite modeli ve darboğaz sıralaması.
6. `problems/P14-05.sh`: game day — bütün korumaları aynı anda sınayan tek script.
