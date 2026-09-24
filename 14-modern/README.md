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
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl14.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl14.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl14 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P14-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

Yönetim uçları kimlik ister (13'ten beri) — yukarıdaki POST bu yüzden anahtarlı (anahtarlar: `deploy/api-keys.yaml`).

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

**Reproduce:** `make repro P=P14-01` — L1 kapalı/açık `hot-key` yükünde okuma yolundaki L2 erişimini,
L1 isabet oranını ve p50/p99'u karşılaştırır. `L1_ENABLED` değişikliği bir canary dağıtımıdır: script
her fazdan önce yeni sürümün stable olmasını bekler (`make wait` ölçütü: `Healthy` ve
`stableRS == currentPodHash`, ~4 dk) ve 1. fazda L1'in gerçekten kapalı olduğunu doğrular — değilse
ölçemediğini söyler (exit 2). Hüküm L1 isabetine ve L2 erişimindeki düşüşe bağlıdır, p50'ye değil.

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

**Reproduce:** `make repro P=P14-02`.

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

**Reproduce:** `make repro P=P14-03`.

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

**Reproduce:** `make repro P=P14-04` · tam model: [`docs-capacity.md`](docs-capacity.md)

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl14&from=now-15m&to=now&refresh=10s), [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl14&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl14&from=now-15m&to=now&refresh=10s) — redirect tek pod'a indirilip `stairs` yükü başlayınca aç (~3 dk sürer) (giriş: admin / ladder)
- "İstek / saniye (uç noktaya göre)" → `/{code}` basamak basamak yükselir (varsayılan `RATES=50,100,200,400`, her basamak ~40 sn). Son basamakta çizgi hedefin altında kalıyorsa tek pod doymuştur — o tavan, modelin "pod başına rps"i.
- "Gecikme (p50 / p95 / p99)" → alt basamaklarda düz; pod doymaya yaklaşınca p99 yukarı kıvrılır. Kıvrılmıyorsa ölçtüğün tepe kapasite değil, verdiğin yüktür: `RATES` ile üstüne çık.
- "CPU kullanımı (çekirdek)" → tek redirect pod'unun çizgisi basamaklarla birlikte tırmanır; script bunun sıfırdan büyük olmasını "yük gerçekten koştu" kanıtı sayar.
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

**Reproduce:** `CONFIRM=1 make repro P=P14-05` — erişilebilirliği, breaker durumunu, yük atmayı,
retry'ı ve kalan hata bütçesini raporlar.

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
