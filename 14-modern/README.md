# 14 — modern · "Son hal"

> **Bu seviyede ne yaşayacaksın?**
> - L1 (pod belleği) + L2 (Redis) önbelleğin ağ adımını ve hot key'i geri alması (P14-01)
> - Tuzak: her L1 kopyasının bir geçersiz kılma kanalı borçlanması — Redis pub/sub yayını ve kısa TTL (P14-02)
> - 3 partition ile tüketici replikalarının gerçekten iş bölüşmesi (P14-03)
> - Bu kümede ölçülmüş bir kapasite modeli: kaç istek/sn, önce hangi kaynak tıkanıyor (P14-04)
> - Game day: arızaların aynı anda enjekte edilip bütün korumaların birlikte sınanması (P14-05) — ve sonunda dürüst bir "yolun devamı" listesi
>
> **Bu seviye olmasa ne olur?** Her koruma tek başına sınanmış olur ama birlikte hiç; sistemin gerçek tavanı tahmin olarak kalır.
>
> **Yeni gelen teknolojiler:** L1+L2 önbellek, Redis pub/sub ile geçersiz kılma, `allkeys-lru`, 3 partition, kapasite modeli, game day ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Merdivenin son basamağı. Üç şey yapıyor: **kalan teknik borçları kapatıyor** (L1+L2 ve
geçersiz kılma yayını, partition sayısı, eviction politikası), **kapasiteyi ölçüyor** (tahminle
değil, bu cluster'da alınmış sayılarla) ve **game day** ile bütün korumaları aynı anda sınıyor.
Sonunda dürüst bir *"yolun devamı"* listesi var — çünkü biten bir sistem yoktur, bilinen bir
sonraki darboğaz vardır.

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

## 3. Önceki seviyeden çözülenler

**Hiçbiri — ve bu tabloyu boş bırakmak bilinçli bir karar.**

P13-06 (enumeration) burada **yok**, çünkü "kısmen çözüldü" diye bir satır olamaz: bir sorun ya
çözülmüştür ya da çözülmemiştir, ve `problems/SOLVES` kontratı bunu `verify-prev` ile ÖLÇER.
P13-06'nın ölçüsü "tarama 404 üretti mi?"dir; tarama her zaman 404 üretir. L1'in negatif kayıtları
bu 404'lerin **maliyetini** düşürür, **varlığını** değil. Dolayısıyla P13-06'yı SOLVES'a yazmak iki
kötü seçenekten birine zorlardı: ya `verify-prev` kalıcı olarak kırık kalırdı, ya da ölçü iddiaya
uyacak şekilde gevşetilirdi — ki bu, merdivenin bütün amacının tersidir.

14 bir "düzeltme" seviyesi değil, bir **sentez** seviyesidir: katkısı önceki bir sorunu silmek
değil, sistemin tamamının aynı anda ayakta kalıp kalmadığını ölçmek (P14-05 game day).

**Kapatılan borçlar** (yeni sorun açmadıkları ve `SOLVES` kontratına girmedikleri için burada):
P04-02/P04-03 (L1 ile ağ adımı ve hot key), P06-03 (3 partition), P04-06 (`allkeys-lru`).
P13-06'nın maliyeti de düştü — ama düşmek ile bitmek farklı şeylerdir.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG, Argo CD + Argo Rollouts, cert-manager + Kyverno**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl14.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl14.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl14 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P14-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

Yönetim uçları kimlik ister (13'ten beri) — yukarıdaki POST bu yüzden anahtarlı (anahtarlar: `deploy/api-keys.yaml`).

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Önceki seviye açıksa kapat (aynı anda tek seviye çalışır), bu seviyeyi kur. `make up` Grafana'yı da temizler:
```bash
make -C ../13-security-tenancy down
make up
```
2. 13'ün sorunlarını bu seviyede koş (~10 dk). Koşarken başka komut çalıştırma: aynı pod'lara dokunurlar.
   14, 13'ün hiçbir sorununu çözdüğünü iddia etmez (§3, `problems/SOLVES`): `BEKLENEN` sütununda her satır
   `(açık kalabilir)` der; P13-06'nın neden burada da açık kaldığını §3 anlatır. `SONUÇ` sütunu 13'ün
   deneylerinin (kimlik, RLS, NetworkPolicy, Kyverno …) 14'ün ortamında ne verdiğini gösterir:
```bash
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P14-01 → P14-05). Her sorunda aynı düzen:
   **Elle** bloklarını sırayla yapıştır (ilk komut `make fresh`: Grafana bu deneye boş başlar) →
   **Terminalde ne görmelisin** ile karşılaştır → **Grafana'da gör** linklerini aç, her madde hangi panelde neyi
   göreceğini söyler. İstersen aynı deneyi `make repro P=…` ile otomatik koş: ölçer ve hükmünü basar.
   Her `/api/...` isteği `Authorization: Bearer acme-key-9f2c` taşır. redirect bir Argo Rollout'tur: P14-01 ve
   P14-02'deki her ayar değişikliği bir canary dağıtımıdır ve `make wait` onun bitmesini bekler (~4 dk).
   P14-05 (game day) yıkıcıdır ve ~6 dk sürer; adımlarını ve temizliğini atlama.
4. Bitince açık kalan ayarları geri al ve seviyeyi kapat:
```bash
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). 13'e göre değişiklik yok.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P14-01 | L1'in kazancı: ağ adımı olmadan isabet | `make repro P=P14-01` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-30m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-30m&to=now&refresh=10s) → "Önbellek işlemleri (katman ve sonuca göre)" | seviye içi |
| P14-02 | **TRAP** her kopya bir kanal borçlanır | `make repro P=P14-02` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-30m&to=now&refresh=10s) · [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl14&from=now-30m&to=now&refresh=10s) → "Önbellekten çıkarılma sebepleri" | seviye içi (pub/sub + kısa TTL) |
| P14-03 | Partition tavanı kalktı | `make repro P=P14-03` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl14&from=now-15m&to=now&refresh=10s) → "Onaylama / sn ve tüketici pod sayısı" | seviye içi |
| P14-04 | Kapasite modeli (ölçümle) | `make repro P=P14-04` | [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s) · [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl14&from=now-15m&to=now&refresh=10s) → "İstek / saniye (uç noktaya göre)" | `docs-capacity.md` |
| P14-05 | **GAME DAY**: üç arıza üst üste | `CONFIRM=1 make repro P=P14-05` | [11 · Resilience](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl14&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s) → "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" | prova |

---

### P14-01 · L1'in geri dönüşü

**Belirti/Kazanç:** Sıcak anahtar okumalarının çoğu L1'den (pod belleğinden) karşılanır; okuma yolunda
Redis'e (L2) giden istek L1 isabeti kadar azalır. Redis'in **toplam** komut hızı ise düşmeyebilir,
artabilir de — ölçümde 767 → 1560 komut/s: L1 açıkken gelen pub/sub geçersiz kılma trafiği de
Redis komutu sayılır. p50 farkı çoğu zaman histogram kovasından küçüktür.
**Neden:** En sıcak anahtarlar artık **hiç ağa çıkmıyor** — P04-02'deki RTT ve P04-03'teki tek
çekirdek tavanı bu sayede geç geliyor. [Topic · Konu: Çok katmanlı önbellek]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P14-01` — L1 kapalı/açık `hot-key` yükünde okuma yolundaki L2
erişimini, L1 isabet oranını ve p50/p99'u karşılaştırır. `L1_ENABLED` değişikliği bir canary dağıtımıdır: script
her fazdan önce yeni sürümün stable olmasını bekler (`make wait` ölçütü: `Healthy` ve
`stableRS == currentPodHash`, ~4 dk) ve 1. fazda L1'in gerçekten kapalı olduğunu doğrular — değilse
ölçemediğini söyler (exit 2). Hüküm L1 isabetine ve L2 erişimindeki düşüşe bağlıdır, p50'ye değil.

Elle — `14-modern` klasöründe, sırayla yapıştır (iki canary dağıtımı yüzünden ~10 dk):

1. Grafana'yı temizle, L1'i yalnızca redirect'te kapat ve canary'nin bitmesini bekle:
```bash
make fresh
make set E="L1_ENABLED=false" W=redirect
make wait
sleep 10
```
2. 1. faz (yalnızca L2, 04'ün davranışı): trafiğin %90'ı tek koda giden 40 sn'lik yük, sonra okuma yolundaki L2 ve L1
   işlem hızını ve p50/p99'u (saniye) oku:
```bash
HOT_SHARE=0.9 make load S=hot-key K6_ARGS="--vus 40 --duration 40s"
sleep 12
for q in \
  'sum(rate(cache_ops_total{namespace="lvl14",layer="l2"}[2m]))' \
  'sum(rate(cache_ops_total{namespace="lvl14",layer="l1"}[2m]))' \
  'histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[2m])) by (le))' \
  'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[2m])) by (le))'
do printf '%s → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "0"'; done
```
3. L1'i geri aç: redirect'in ortamını manifestteki hâline döndür (`L1_ENABLED=true`) ve yine canary'yi bekle:
```bash
make reset W=redirect
make wait
sleep 10
```
4. 2. faz (L1+L2): aynı yük, aynı sayılar ve L1 isabet oranı:
```bash
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

**Terminalde ne görmelisin:** 1. adımda `✔ rollout/redirect: L1_ENABLED=false`, ardından `make wait`'in
`rollout.argoproj.io/redirect canary adımları sürüyor (Progressing)...` satırı (aşama adı farklı olabilir) ve ~4 dk sonra
`rollout.argoproj.io/redirect sürüm tamam: …`. 2. adımda `layer="l2"` sıfırdan belirgin büyük (okumaların hepsi
Redis'e gidiyor) ve `layer="l1"` **0** — 0 değilse L1 henüz kapanmamıştır, ölçüm geçersizdir (`make wait`'i tekrar
koş). 3. adım 1. adımdaki gibi ~4 dk bekler. 4. adımda `layer="l1"` yüksek, `layer="l2"` 1. faza göre belirgin düşük;
sorgu çıktısının son satırı (L1 isabet oranı) 0.5'in belirgin üstünde: trafiğin %90'ı tek sıcak koda gidiyor. p50 iki
fazda aynı ya da 2. fazda biraz düşük: fark histogram kovasından küçük olabilir, hüküm bu yüzden p50'ye bakmaz.

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-30m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-30m&to=now&refresh=10s) ve [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl14&from=now-30m&to=now&refresh=10s) — iki faz var (önce L1 kapalı, sonra açık; her biri bir canary dağıtımı — ~4 dk — ve ardından 40 sn `hot-key` yükü), deney boyunca açık tut (giriş: admin / ladder)
- "Önbellek işlemleri (katman ve sonuca göre)" → asıl kanıt bu panel. 1. fazda okumaların hepsi `l2` serilerinde; 2. fazda `l1` `hit` baskın olur ve `l2` serileri neredeyse sıfıra iner: sıcak okumalar artık ağa çıkmıyor. 1. fazda da `l1` serisi akıyorsa L1 gerçekten kapanmamıştır — `L1_ENABLED=false` bir canary dağıtımıyla gelir; script bunu bekler ve 1. fazda L1 işlemi görürse ölçümü geçersiz sayar.
- "Gecikme (p50 / p95 / p99)" → p50 2. fazda aynı ya da biraz aşağıda. Fark histogram kovasından küçükse iki faz aynı görünür — script hükmü bu yüzden gecikmeye değil L1 isabetine bağlar.
- "Komut / sn" → Redis'in toplam komut hızı düşmeyebilir, hatta artabilir (ölçümde 767 → 1560/s): L1 açıkken pub/sub geçersiz kılma trafiği de Redis komutu sayılır. Okuma yolundaki azalmayı bu panel değil, yukarıdaki `l2` serileri gösterir.

**Ama bu "L1 artık bedava" demek değil.** Bedeli bir sonraki maddede.

---

### P14-02 · TRAP · Her kopya bir geçersiz kılma kanalı borçlanır

**Belirti:** Pub/sub açıkken silinen link neredeyse anında her pod'da kayboluyor; kapalıyken
L1 TTL'i boyunca yaşamaya devam ediyor — **03'teki P03-01'in aynısı**.
**Neden:** L1 = gerçeğin N kopyası. 03 bu borcu ödememişti; 14 Redis pub/sub ile ödüyor.
[Topic · Konu: Invalidation broadcast, en-iyi-çaba]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P14-02` (deney süresince redirect'in `L1_TTL`'ini 90 sn'ye çıkarır —
10 sn'lik pencere ölçüm döngüsünden kısa kalır ve biz bakmadan kapanır; en az iki redirect replikası olduğunu
doğrular; yayın açık ve kapalıyken aynı "oluştur → 40 okuma → sil → 40 okuma" turunu koşar, bayat yönlendirmeleri
sayar; bitince ayarları geri alır).

Elle — sırayla yapıştır (üç canary dağıtımı yüzünden ~15 dk):

1. Grafana'yı temizle, redirect'in L1 TTL'ini deney için 90 sn'ye çıkar, canary'yi bekle, replika sayısına bak (en
   az 2 olmalı: tek pod'da bayatlayacak ikinci bir kopya yoktur):
```bash
make fresh
make set E="L1_TTL=90s" W=redirect
make wait
sleep 10
kubectl -n lvl14 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
```
2. 1. faz (yayın açık): link oluştur, 40 okumayla bütün pod'ların L1'ine sok, sil, aynı kodu 40 kez daha iste; bir
   kazıma bekleyip gönderilen/alınan geçersiz kılma mesajlarını say:
```bash
code=$(curl -s -XPOST http://lvl14.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/inval"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 40); do curl -s -o /dev/null http://lvl14.localtest.me/$code; done
curl -s -o /dev/null -w 'silme: %{http_code}\n' -XDELETE http://lvl14.localtest.me/api/links/$code -H 'Authorization: Bearer acme-key-9f2c'
sleep 1
for i in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code} ' http://lvl14.localtest.me/$code; done; echo
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (direction) (increase(cache_invalidation_messages_total{namespace="lvl14"}[2m]))' | jq -r '.data.result[] | .metric.direction + ": " + .value[1]'
```
3. Tuzağı yalnızca redirect'te aç (L1 var, yayın yok — 03'ün hâli) ve canary'yi bekle:
```bash
make set E="TRAP_NO_INVALIDATION_PUBSUB=true" W=redirect
make wait
sleep 10
```
4. 2. faz (yayın kapalı): aynı tur, yeni bir linkle:
```bash
code=$(curl -s -XPOST http://lvl14.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/inval"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 40); do curl -s -o /dev/null http://lvl14.localtest.me/$code; done
curl -s -o /dev/null -w 'silme: %{http_code}\n' -XDELETE http://lvl14.localtest.me/api/links/$code -H 'Authorization: Bearer acme-key-9f2c'
sleep 1
for i in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code} ' http://lvl14.localtest.me/$code; done; echo
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (direction) (increase(cache_invalidation_messages_total{namespace="lvl14"}[2m]))' | jq -r '.data.result[] | .metric.direction + ": " + .value[1]'
```
5. Geri al: redirect'in ortamını manifestteki hâline döndür (`L1_TTL=10s`, tuzak yok) ve son canary'yi bekle:
```bash
make reset
make wait
```

**Terminalde ne görmelisin:** 1. adımda `✔ rollout/redirect: L1_TTL=90s`, ~4 dk sonra `… sürüm tamam: …` ve `3`.
2. adımda `silme: 204`; silmeden sonraki 40 cevap `404` (en fazla birkaç `302`): yayını alan her pod kendi kopyasını
sildi. Mesaj sayımında `sent` ve `received` ikisi de sıfırdan büyük, `received` daha büyük (her mesajı diğer
pod'ların hepsi alır; `increase` tahmin olduğu için küsuratlı çıkabilir). 4. adımda yine `silme: 204`, ama sonraki
40 cevabın çoğu `302`: link silindi, redirect pod'ları onu L1 TTL'i (90 sn) dolana kadar yönlendirmeye devam ediyor.
Sayımda `sent` yine sıfırdan büyüktür (silmeyi yapan api yayını göndermeye devam ediyor), `received` ise neredeyse
sıfırdır (redirect pod'ları o kanalı dinlemiyor).

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-30m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl14&from=now-30m&to=now&refresh=10s) — iki faz var (yayın açık, sonra kapalı; her faz bir canary dağıtımıyla başlar ve script onun bitmesini bekler, ~4 dk), deney boyunca açık tut (giriş: admin / ladder)
- "Önbellekten çıkarılma sebepleri" → 1. fazda silme anında kısa bir `invalidate` tepesi: yayını alan her pod kendi kopyasını siler. 2. fazda redirect pod'larında bu tepe yok: kopyalar yayınla silinmez, ancak TTL dolunca düşer (deney süresince `L1_TTL` 90 sn).
- "Yönlendirme sonuçları" → silinmiş koda yapılan okumalar 1. fazda `not_found`; 2. fazda `ok` sayılmaya devam eder — bayat cevap, uygulamanın gözünden **başarıdır**.
- Explore'da: `sum by (direction) (increase(cache_invalidation_messages_total{namespace="lvl14"}[2m]))` → 1. fazda `sent` ve `received` birlikte artar (`received` daha büyük: her mesajı diğer pod'ların hepsi alır). 2. fazda silmeyi yapan api pod'u yayını göndermeye devam eder (`sent` artar), ama redirect pod'ları başka bir kanalı dinlediği için `received` neredeyse durur — §8'deki "gönderilen ile alınan arasındaki fark" tam olarak bu.

**Kanal en-iyi-çabadır:** Redis yeniden başlarsa, bir pod abone olamazsa ya da mesaj düşerse
kimse fark etmez. Bu yüzden **kısa TTL (10 sn) bir yedek mekanizmadır, optimizasyon değil** —
kaçan bir yayında bayatlık penceresi tam olarak o kadardır.
**Alternatifler ve bedelleri:** sürüm damgalı anahtar (sürüm nerede tutulur?) · yazmada L1'i
atlamak (sıcak anahtar kazancını kaybedersin) · dayanıklı akışla yayın (garanti, karşılığında gecikme).
*Seçim: en-iyi-çaba yayın + kısa TTL. Pencereyi ölçtük ve kabul ettik — 03'ten farkı bu.*

---

### P14-03 · Partition tavanı kalktı

**Belirti:** 3 partition ile tüketici replikaları **gerçekten** iş bölüşüyor (P06-03'te 1 partition
tavanı vardı).
[Topic · Konu: Partition, paralellik]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P14-03` (topic'in partition sayısını ve KEDA tavanını okur, tüketiciyi
KEDA'nın `paused-replicas` anotasyonuyla 3 replikaya sabitler, 60 sn `hot-key` yükü verir, kaç pod'un gerçekten kayıt
işlediğini Prometheus'tan sayar ve anotasyonu kaldırır). Replikayı zorlamasının sebebi: `hot-key` yükünde lag 500
eşiğinin çok altında kalır, KEDA tek pod'da durur ve yalnızca partition sayısına bakan bir hüküm paralelliği hiç
göstermezdi.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, broker pod'unun hazır olmasını bekle, `clicks` topic'inin partition'larına ve KEDA'nın
   üst sınırına bak:
```bash
make fresh
kubectl -n lvl14 wait --for=condition=Ready pod -l app.kubernetes.io/name=redpanda --timeout=180s
rp=$(kubectl -n lvl14 get pod -l app.kubernetes.io/name=redpanda -o jsonpath='{.items[0].metadata.name}'); echo "broker: $rp"
kubectl -n lvl14 exec "$rp" -- rpk topic describe clicks -p
kubectl -n lvl14 get scaledobject analytics -o jsonpath='{.spec.maxReplicaCount}'; echo
```
2. Tüketiciyi 3 replikaya sabitle (KEDA duraklatılır) ve hazır olmasını bekle:
```bash
kubectl -n lvl14 annotate scaledobject analytics autoscaling.keda.sh/paused-replicas=3 --overwrite
sleep 20
kubectl -n lvl14 rollout status deploy/analytics
```
3. İKİNCİ bir terminalde `14-modern` klasöründe tüketici pod'larını canlı izle:
```bash
kubectl -n lvl14 get pods -l app.kubernetes.io/name=analytics -w
```
4. İLK terminalde 60 sn yük ver, bir kazıma bekle; iş yapan pod sayısını, pod başına işleme hızını ve tepe lag'i oku:
```bash
make load S=hot-key K6_ARGS="--vus 60 --duration 60s"
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=count(count by (pod) (rate(consumer_records_total{namespace="lvl14",result="ok"}[3m]) > 0))' | jq -r '"iş yapan pod: " + (.data.result[0].value[1] // "0")'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (pod) (rate(consumer_records_total{namespace="lvl14",result="ok"}[3m]))' | jq -r '.data.result[] | .metric.pod + ": " + .value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(redpanda_kafka_max_offset{namespace="lvl14"} - on(redpanda_topic, redpanda_partition) group_left redpanda_kafka_consumer_group_committed_offset{namespace="lvl14"})[5m:15s])' | jq -r '"tepe lag: " + (.data.result[0].value[1] // "0")'
```
5. Sabitlemeyi kaldır (KEDA yeniden devreye girer), ikinci terminaldeki izlemeyi Ctrl+C ile durdur:
```bash
kubectl -n lvl14 annotate scaledobject analytics autoscaling.keda.sh/paused-replicas- --overwrite
```

**Terminalde ne görmelisin:** 1. adımda `rpk` tablosunda `0`, `1`, `2` numaralı üç partition satırı ve KEDA üst sınırı
`3` (partition sayısını aşmıyor — fazlası boşta otururdu). 2. adımda `scaledobject.keda.sh/analytics annotated` ve
`deployment "analytics" successfully rolled out`. 3. adımda ikinci terminal üç `analytics-…` pod'unu `1/1 Running`
listelemeli. 4. adımda
k6 çıktısının sonundaki özet satırı (`k6 lvl14: reqs=… 5xx=… …`), ardından `iş yapan pod: 3` ve üç `analytics-…: …`
satırı, üçü de sıfırdan büyük; biri belirgin yüksektir — anahtar kısa kod olduğu için sıcak kodun bütün olayları tek
partition'a, yani tek pod'a gider. Tepe lag küçük kalır: tüketiciler yetişiyor. 5. adımda
`scaledobject.keda.sh/analytics annotated`; KEDA'nın bekleme süresinden (`cooldownPeriod: 60`) sonra pod sayısı düşebilir.

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl14&from=now-15m&to=now&refresh=10s) — tüketici 3 replikaya sabitlenip 60 sn'lik `hot-key` yükü başlayınca aç (giriş: admin / ladder)
- "Onaylama / sn ve tüketici pod sayısı" → pod çizgisi deney boyunca 3'te (KEDA duraklatıldı), commit/s yükle birlikte yükselir; deney bitince KEDA yeniden devreye girer ve pod sayısı düşebilir.
- "Tüketici gecikmesi (bölüme göre)" → üç ayrı çizgi (partition 0, 1, 2). Tüketiciler yetiştiği sürece hepsi sıfıra yakın kalır; biri birikiyorsa o partition'ın tüketicisi darboğazdır.
- Explore'da: `sum by (pod) (rate(consumer_records_total{namespace="lvl14",result="ok"}[1m]))` → üç ayrı çizgi, üçü de sıfırın üstünde: üç pod da gerçekten iş yapıyor (tek partition'da yalnızca biri çizgi verirdi). Biri belirgin yüksek olur: anahtar kısa kod olduğu için sıcak kodun bütün olayları tek partition'a, yani tek pod'a gider — partition başına sıranın bedeli.

**Yeni sınır ve bedeli:** partition başına sıra garantisi var, **global sıra yok** · partition
sayısı **azaltılamaz** · artırma anında mevcut anahtarlar yeni partition'lara taşınır ve o an
için sıra garantisi kırılır. *"Partition artır" bir düğme değil, planlanması gereken bir değişikliktir.*

---

### P14-04 · Kapasite modeli

**Soru:** "100 milyon redirect/gün için ne gerekir?"
**Yöntem:** Tahmin değil ölçüm. Script tek pod kapasitesini `stairs` yüküyle ölçer, sonra modeli
o sayıyla kurar. [Topic · Konu: Kapasite planlaması]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P14-04` (redirect'i tek pod'a indirir, `stairs` yükü verir — varsayılan
`RATES=50,100,200,400`, basamak başına ~40 sn —, tepe kabul edilen rps'i, p99'u, CPU'yu, önbellek isabetini ve DB
okumasını Prometheus'tan okur, 100 milyon redirect/gün modelini basar ve replikayı geri alır) · tam model:
[`docs-capacity.md`](docs-capacity.md)

Elle — sırayla yapıştır (~5 dk):

1. Grafana'yı temizle, redirect'in replika sayısını not et (geri alırken lazım), tek pod'a indir ve hazır adresin
   bire indiğini gör:
```bash
make fresh
kubectl -n lvl14 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
kubectl -n lvl14 scale rollout/redirect --replicas=1
sleep 15
kubectl -n lvl14 get endpointslice -l kubernetes.io/service-name=redirect -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].targetRef.name}'; echo
```
2. Kademeli yük ver (~3 dk), bir kazıma bekle, tek pod'un ölçümlerini oku: tepe kabul edilen rps, önbellek isabet
   oranı, tepe p99 (saniye), tepe CPU (çekirdek) ve DB okuması (sn başına):
```bash
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
3. Modeli ölçülen sayıyla kur (scriptin hesabının aynısı: 100 milyon redirect/gün, tepe = ortalamanın 3 katı):
```bash
awk -v rps="$rps" -v hit="$hit" 'BEGIN{avg=100000000/86400; peak=avg*3; printf "ortalama = %.0f rps · tepe (3x) = %.0f rps\n", avg, peak; if (rps>0) printf "gereken pod = %.0f (ölçülen %.0f rps/pod) + yedeklilik + burst tamponu\n", peak/rps+0.999, rps; printf "DB okuma (hit %.0f%%) = %.0f/s · SOĞUK anda = %.0f/s\n", hit*100, peak*(1-hit), peak}'
```
4. İstersen merdiveni tek pod'un tavanının üstüne uzat (`stairs.js`: bu kümede tek seviyenin redirect kapasitesi
   ~650 rps; daha yukarısı ölçüm değil yıkım üretir), ölçümü ve modeli tekrarla:
```bash
RATES=100,200,400,800 make load S=stairs
sleep 15
rps=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(rate(http_requests_total{namespace="lvl14",route="/{code}",code!="429",code!="503"}[30s]))[6m:15s])' | jq -r '.data.result[0].value[1] // "0"'); echo "tepe kabul edilen rps: $rps"
hit=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(cache_ops_total{namespace="lvl14",result=~"hit|negative_hit"}[3m])) / clamp_min(sum(rate(cache_ops_total{namespace="lvl14"}[3m])),0.001)' | jq -r '.data.result[0].value[1] // "0"'); echo "önbellek isabet oranı: $hit"
awk -v rps="$rps" -v hit="$hit" 'BEGIN{avg=100000000/86400; peak=avg*3; printf "ortalama = %.0f rps · tepe (3x) = %.0f rps\n", avg, peak; if (rps>0) printf "gereken pod = %.0f (ölçülen %.0f rps/pod) + yedeklilik + burst tamponu\n", peak/rps+0.999, rps; printf "DB okuma (hit %.0f%%) = %.0f/s · SOĞUK anda = %.0f/s\n", hit*100, peak*(1-hit), peak}'
```
5. Replikayı 1. adımda not ettiğin sayıya (manifestte `3`) geri al ve hazır olmasını bekle:
```bash
kubectl -n lvl14 scale rollout/redirect --replicas=3
make wait
```

**Terminalde ne görmelisin:** 1. adımda `3`, `rollout.argoproj.io/redirect scaled` ve tek bir `redirect-…` pod adı.
2. adımda k6 çıktısının sonundaki özet satırı (`k6 lvl14: reqs=… 5xx=… …`); `tepe kabul edilen rps` son basamağa
(400) yakınsa pod doymamıştır ve ölçtüğün tavan değil verdiğin yüktür (4. adım); belirgin altındaysa tek pod'un
tavanı odur. İsabet oranı yüksek (200 tohum link önbelleğe sığar), p99 saniye cinsinden küçük bir değer, CPU
sıfırdan büyük bir çekirdek kesri — `01 · Pods & Resources` → "CPU kullanımı (bir çekirdeğin %'si)" aynı değeri
yüzle çarpar (0.31 çekirdek = %31) —, DB okuması isabet oranı yüksek olduğu için düşük. 3. adımda `ortalama = 1157 rps · tepe (3x) = 3472 rps`,
`gereken pod = …` ve `DB okuma (hit …%) = …/s · SOĞUK anda = 3472/s`: önbellek soğukken DB tepe trafiğin tamamını
görür. 5. adımda `rollout.argoproj.io/redirect hazır: 3/3` ve `… sürüm tamam: …`.

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s), [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl14&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-15m&to=now&refresh=10s) — redirect tek pod'a indirilip `stairs` yükü başlayınca aç (~3 dk sürer) (giriş: admin / ladder)
- "İstek / saniye (uç noktaya göre)" → `/{code}` basamak basamak yükselir (varsayılan `RATES=50,100,200,400`, her basamak ~40 sn). Son basamakta çizgi hedefin altında kalıyorsa tek pod doymuştur — o tavan, modelin "pod başına rps"i.
- "Gecikme (p50 / p95 / p99)" → alt basamaklarda düz; pod doymaya yaklaşınca p99 yukarı kıvrılır. Kıvrılmıyorsa ölçtüğün tepe kapasite değil, verdiğin yüktür: `RATES` ile üstüne çık.
- "CPU kullanımı (bir çekirdeğin %'si)" → tek redirect pod'unun çizgisi basamaklarla birlikte tırmanır; script bunun sıfırdan büyük olmasını "yük gerçekten koştu" kanıtı sayar.
- "İsabet oranı (toplam)" → yüksek; modelin "DB okuma = tepe × (1 − hit)" satırı buradan gelir. Soğuk anda bu oran 0'dır ve DB tepe trafiğin tamamını görür (P03-02).

**Modelin en kritik satırı:** önbellek **soğukken** DB tepe trafiğin tamamını görür (P03-02).
*Kapasiteyi ortalamaya göre planlarsan ilk dağıtım seni devirir.*
Belgede ayrıca **darboğaz sıralaması** var: her biri aşıldığında bir sonraki ortaya çıkıyor —
ve sonuncusu (tek primary'ye yazma) **aşılmadı**, sharding ister.

---

### P14-05 · GAME DAY

**Senaryo:** Redis gecikmesi → DB paket kaybı → pod öldürme, üst üste, tek bir yük altında.
**Beklenen:** Sistem **kısmen** bozulur, tamamen değil. Her koruma kendi işini yapar.
[Topic · Konu: Chaos engineering, prova]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `CONFIRM=1 make repro P=P14-05` — 30 sn'lik taban ölçümünden sonra sabit 300 istek/sn
`steady` yükü altında üç arızayı üst üste bindirir, erişilebilirliği, breaker durumunu, yük atmayı, retry'ı ve kalan
hata bütçesini raporlar; arızaları kendisi kaldırır ve ortamın toparlanmasını bekler. Kontrol düzlemi deney
sırasında yeniden başladıysa hüküm vermez (sonuç kümeyi ölçer, uygulamayı değil).

Elle — sırayla yapıştır. **Yıkıcı ve uzun:** toplam ~6 dk (taban ~1 dk, game day 150 sn yük, ölçüm ~30 sn, temizlik ve
toparlanma genelde 1–2 dk). lvl14'te Redis'e 200 ms gecikme, Postgres pod'larına %30 paket kaybı enjekte edilir ve
bir redirect pod'u zorla silinir; kümenin başka bir namespace'ine dokunulmaz. Arızaları 4. adımın bloğu kendisi
kaldırır; blok yarıda kesilirse (Ctrl+C, terminal kapandı) arızalar kümede kalır — **6. adımı her durumda koş.**

1. Grafana'yı temizle; game day'den önce korumaların dinlenmede olduğunu (breaker ve degrade `0`) ve kontrol düzlemi
   pod'larının yeniden başlatma sayılarını gör (6. adımda karşılaştıracaksın):
```bash
make fresh
for q in 'max(breaker_state{namespace="lvl14"})' 'max(degraded_mode{namespace="lvl14"})'; do printf '%s → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "seri yok"'; done
kubectl -n kube-system get pods -l tier=control-plane -o jsonpath='{range .items[*]}{.metadata.name}{" restart="}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```
2. Taban: her şey sağlıklıyken 30 sn sabit 300 istek/sn (muafiyet jetonlu yük girişi), sonra p99'u (saniye) oku:
```bash
RATE=300 make load S=steady K6_ARGS="--duration 30s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl14",route="/{code}"}[2m])) by (le))' | jq -r '"taban p99: " + (.data.result[0].value[1] // "0")'
```
3. Game day yükü: İKİNCİ bir terminalde `14-modern` klasöründe 150 sn sabit 300 istek/sn başlat:
```bash
RATE=300 make load S=steady K6_ARGS="--duration 150s"
```
4. Yük başlar başlamaz İLK terminalde zaman çizelgesini yapıştır. Blok ~1 dk 50 sn sürer: 00:15'te Redis'e 200 ms
   gecikme, 00:45'te Postgres'e %30 paket kaybı, 01:15'te hazır bir redirect pod'u (scriptin `pod_name` seçimi) zorla
   silinir, 01:45'te iki arıza da kaldırılır. Pod öldüğünde ondaki istekler askıda kalabilir; yükün kalan ~75 sn'si
   k6'nın 60 sn'lik zaman aşımına yeter:
```bash
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
5. İkinci terminalde k6'nın özet satırı çıkınca İLK terminalde sonuçları oku: uygulamanın saydığı istek, 5xx ve 429,
   limiter muafiyeti, breaker/degrade tepesi, yük atma, retry, bağımlılık p99 tepeleri (saniye) ve kalan hata bütçesi:
```bash
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
6. Temizlik — her durumda koş: kalan bütün chaos nesnelerini sil (takılı finalizer'ları da düşürür), kalmadığını
   doğrula, veritabanı, Redis ve redirect hazır olana kadar bekle, kontrol düzlemi sayılarını 1. adımla karşılaştır:
```bash
make unchaos
kubectl -n lvl14 get networkchaos
make wait
kubectl -n kube-system get pods -l tier=control-plane -o jsonpath='{range .items[*]}{.metadata.name}{" restart="}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```

**Terminalde ne görmelisin:** 1. adımda iki satır da `→ 0` ve her kontrol düzlemi pod'u için bir `restart=` sayısı.
2. adımda k6 çıktısının sonundaki özet satırı ve `taban p99: …` (saniye; küçük bir değer). 4. adımda
`networkchaos.chaos-mesh.org/redis-delay-200ms created`, `networkchaos.chaos-mesh.org/pg-loss-30 created`, ikisini
listeleyen `kubectl get networkchaos` tablosu, `[01:15] öldürülen: redirect-…` ve `pod "redirect-…" force deleted`;
`make unchaos C=…` sessizdir. İkinci terminaldeki özet satırında (`k6 lvl14: reqs=… 5xx=… 404=… …`) `5xx` sıfırdan
büyük ama `reqs`'in küçük bir payı: erişilebilirlik (1 − 5xx/reqs) scriptin hükmü için %50'nin üstünde olmalı —
kısmi bozulma, tam çöküş değil. Öldürülen pod'da askıda kalan istekler için birkaç `request timeout` uyarısı da
görebilirsin. 5. adımda uygulamanın 5xx sayısı genelde k6'nınkinden küçük ya da eşit (aradaki fark ingress'in ya da hazır
pod'u kalmamış servisin cevabı), 429 ~0 ve muafiyet sayısı sıfırdan büyük (yük limiter'ı gerçekten atladı; 0 ise
ölçülen limiter'lardır). Breaker tepesi `0`, `1` ya da `2` (yalnızca `postgres`'in breaker'ı hareket edebilir),
yük atma çoğu zaman `0` (`SHED_MAX_INFLIGHT=200`'e ulaşılmaz), `dep="redis"` p99 tepesi ~0.2 (enjekte edilen
200 ms ± 50 ms jitter; 0.15'in altındaysa gecikme Redis'e ulaşmamış demektir), `dep="postgres"` p99 tepesi tabandan
yüksek; kalan hata bütçesi aşağı iner, eksi bile olabilir (aşağıdaki Explore maddesi nedenini söyler). 6. adımda `make unchaos` ne kaldıysa
siler, `kubectl get networkchaos` → `No resources found in lvl14 namespace.`, `make wait` →
`cluster.postgresql.cnpg.io/pg hazır: 2/2`, `rollout.argoproj.io/redirect hazır: 3/3` ve `… sürüm tamam: …`;
kontrol düzlemi sayıları 1. adımdakiyle aynı. Artmışsa deney sırasında kontrol düzlemi yeniden başlamıştır: sonuç
kümeyi ölçüyor, uygulamayı değil — game day'i küme sakinken tekrar et.

**Grafana'da gör:** [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl14&from=now-15m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s), [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl14&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl14&from=now-15m&to=now&refresh=10s) — game day başlamadan aç; arızalar 00:15 (Redis +200 ms), 00:45 (Postgres %30 paket kaybı) ve 01:15 (pod öldürme) anlarında gelir, 01:45'te kalkar (giriş: admin / ladder)
- "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)" → game day başlamadan **0** olmalı (değilse script uyarır: trafik almayan pod'un breaker'ı açıldığı anda donar). `redis` ve `kafka` çizgileri hep 0'da durur (etraflarında breaker yok); hareket edebilen tek çizgi `postgres`: yalnızca önbellek ıskaları veritabanına gittiği için paket kaybı ancak o sorguları düşürürse 1–2'ye çıkar, çıkmıyorsa önbellek yükü emmiştir — bu da bir sonuçtur.
- "Bağımlılık gecikmesi p99" → iki çizgi: `redis` 00:15'te ~200 ms'ye sıçrar ve 01:45'e kadar orada kalır (enjekte edilen gecikme, kendi etiketiyle); `postgres` 00:45'ten sonra yükselir. Her bağımlılığın kendi guard'ı var: L2 önbelleğin Redis çağrıları `redis` çizgisine, veritabanı çağrıları `postgres` çizgisine düşer — biri diğerinin gecikmesini taşımaz. (L1 isabetleri Redis'e hiç gitmez; `redis` çizgisi L1 ıskalarının L2 çağrılarıdır.)
- "Uygulama → Redis gecikmesi (p99)" (06 · Redis) → aynı ~200 ms platosu, yalnızca Redis için: uygulamanın gördüğü gecikme. Script tepe değeri de basar (`redis=… ms`).
- "Şu an işlenen istek (pod'a göre)" → Redis gecikmesiyle (00:15) yükselir ama yük atma eşiğinin (`SHED_MAX_INFLIGHT=200`) çok altında kalır; bu yüzden "Atılan yük / sn" düz kalabilir. "Hazır pod adresi (endpoint) sayısı" → 01:15'te bir basamak iner, yeni pod hazır olunca geri çıkar.
- "İstek / saniye (durum koduna göre)" (App RED) ile "Dönen durum kodları" (k6) → uygulamanın saydığı 5xx ile istemcinin gördüğü 5xx'i yan yana koy: aradaki fark, araya giren bir katmanın (ingress, hazır pod'u kalmamış servis) cevabıdır. Bkz. [Grafana'yı okumak](../README.md#grafanayı-okumak).
- Explore'da: `slo:period_error_budget_remaining:ratio{namespace="lvl14",sloth_slo="redirect-availability"}` → game day'in 5xx'leri kalan bütçeyi aşağı çeker; `12 · SLO` → "Kalan hata bütçesi" aynı seriyi çizer (kayıt kuralları `namespace` etiketini taşır). Pencere 30 gün yazılı ama Prometheus yalnızca 6 saat tutuyor: değer, eldeki birkaç saatin bütçesidir ve önceki deneylerin izi de içindedir (eksi olabilir).

**Bu bir test değil, bir provadır:** amacı geçmek değil, hangi korumanın ne zaman devreye
girdiğini **görmek** ve runbook'u buna göre yazmak. *Tek tek çalışan korumaların birlikte nasıl
davrandığı, ayrı bir sorudur ve yalnızca denenerek öğrenilir.*

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_NO_INVALIDATION_PUBSUB` | L1 var, yayın yok (03'ün hâli) | `make repro P=P14-02` | Bayrağı kapat |
| `L1_ENABLED` / `L1_TTL` | Tuzak değil, **ayar düğmesi** | P14-01 / P14-02 | Ölç, sonra karar ver |

Elle denemeye değer:
- `L1_TTL=5m` yap ve P14-02'yi tekrar koş: bayatlık penceresi 5 dakikaya çıkar.
  **Kısa TTL'in neden bir yedek mekanizma olduğunu bir kez hissetmek yeter.**
- `tools/ladder-matrix/run.sh` ile **tüm** seviyelerin tüm scriptlerini bu seviyeye koş:
  beklenen tablo, çözülmüş her sorunun NOT-REPRODUCED olması. Olmayanlar ya "bilerek bırakılan"
  ya da bir **regresyon**dur.
- `make chaos C=redis-kill` + `make load S=mixed`: L1 sayesinde Redis tamamen ölse bile en sıcak
  anahtarlar cevaplanmaya devam eder. **P04-01'i bu seviyede tekrar koş ve farkı gör.**
- 00 ile 14'ü aynı Grafana panelinde yan yana koy (`level` dropdown'ı): aynı yük, aynı paneller,
  on dört basamak fark.

## 8. Gözlemlenebilirlik: hangi paneller dolu

Bu seviyede neredeyse hepsi dolu — merdivenin ilk bakışta en görünür kazancı bu. 00'da yalnızca
`Pods & Resources` ve `k6` doluydu. Bilinen boşluklar, sebepleriyle: `05 · Postgres`'in
postgres_exporter panelleri (CNPG'de exporter yok; havuz ve sorgu panelleri uygulamadan geldiği için
dolu), `14 · Security` → "Ağ politikası hataları (Calico)" (felix kazınmıyor) ve `13 · Rollout` →
"Git ile uyumsuz uygulamalar (Argo CD)" (Application tanımlı değil, P12-03).
`13 · Rollout`'un sürüme göre panelleri pod şablonu hash'iyle ayrılır (stable hash:
`kubectl -n lvl14 get rollout redirect -o jsonpath='{.status.stableRS}'`); `11 · Resilience` →
"Bağımlılık gecikmesi p99" `postgres` ve `redis`'i ayrı çizer.

Yeni metrik: `cache_invalidation_messages_total{direction}`. *Gönderilen ile alınan arasındaki
fark, kaç pod'un yayını kaçırdığını söyler* — ve bu sayı sessizce büyüyorsa L1 TTL'in tek
savunman demektir.

## 9. Bilerek bırakılanlar — "yolun devamı"

Bu liste bir eksiklik itirafı değil, **kapsam beyanıdır**. Her madde gerçek bir sonraki adım:

**Altyapı**
- **Tek Redis** — Sentinel/Valkey HA ya da cluster. L1 etkiyi azalttı, kaldırmadı (P04-01).
- **Tek broker, RF=1** — bir broker kaybı = topic kaybı (P06-05).
- **Tek bölge, tek cluster** — çok bölgeli aktif-aktif; DNS failover; veri yerelliği.
- **Cluster autoscaler yok** (P07-05) — bulutta Karpenter/CA, node açma süresi dakikalar.
- **Yedekleme/PITR yapılandırılmadı** (P09-06) — barman + nesne deposu + **geri yükleme tatbikatı**.

**Uygulama**
- **Yazma yolu tek primary** — sharding olmadan yatay yazma ölçeklemesi yok (kapasite modelinin son darboğazı).
- **gRPC yok**: servisler arası çağrı yalnızca N+1 tuzağında (P07-06). Batch + gRPC 14'ün stretch'iydi.
- **Gateway API yok**: ingress-nginx yeterliydi; Gateway API + service mesh (Linkerd) mTLS getirirdi.
- **Tier kotaları bağlanmadı** (13): kimlik var, `TIER_LIMITS` var, limiter hâlâ sabit kota kullanıyor.
- **404 oranına özel limit yok** (P13-06).

**Süreç**
- **CI imaj yayınlamıyor**, imaj tarama/imza/SBOM yok (P13-08).
- **Argo CD Application tanımlı değil** (P12-03): kurulu, bağlanmadı.
- **Sırlar düz metin** (P13-04): sealed-secrets kurulu, kullanılmadı — gerekçesi yazılı.
- **Alertmanager hedefi yok** (11): alarmlar ateşliyor, kimseye gitmiyor.
- **Sürekli profil yok** (P11-08): profil uçları iç portta (`:6060`) hazır, toplayan yok (Pyroscope).
  `/metrics` hâlâ ingress arkasındaki portta (13 §9).
- **Maliyet modeli yok**: 12 pod + 3 DB + Redis + Kafka'nın bulut faturası kapasite modelinin
  parçası olmalı. *Ölçeklenebilirlik bir mühendislik sorunu kadar bir ekonomi sorunudur.*

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 13 ile farkı gösterir:

1. **`internal/cache/tiered.go`** (yeni): L1 + L2 + pub/sub. Asıl içerik yorumdaki dürüst
   muhasebe — *"bu 'L1 artık bedava' değil; L1'in bedeli bir kanal, kısa bir TTL ve ölçüp kabul
   ettiğin bir tutarsızlık penceresi."*
2. **`internal/store/cached.go`**: `CacheLayer` arayüzü ve `invalidate` fonksiyonu. Dekoratör,
   altındaki katmanın L2 mi Tiered mi olduğunu **bilmiyor** — 03'ten beri aynı arayüz, dördüncü
   farklı gerçekleştirim.
3. **`deploy/redis.yaml`**: `noeviction` → `allkeys-lru`. P04-06'da ölçtüğümüz "sessizce
   önbelleklemeyi bırakma" davranışı kapandı.
4. **`deploy/redpanda.yaml`**: 1 → 3 partition; **`deploy/keda.yaml`**: maxReplicas 6 → 3
   (partition sayısını aşmak boşa gider).
5. **`docs-capacity.md`** (yeni): ölçülmüş sayılarla kapasite modeli ve darboğaz sıralaması.
6. **`problems/P14-05.sh`**: game day — merdivenin tüm korumalarını aynı anda sınayan tek script.
