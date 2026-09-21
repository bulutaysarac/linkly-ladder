# 04 — redis-cache · "Paylaşılan önbellek"

## 1. Bu seviye ne?

Önbellek pod'un dışına çıktı: tek bir Redis, tüm replikaların paylaştığı. 03'ün bütün tutarlılık
sorunları tek hamlede kapanıyor — tek kopya, tek geçersiz kılma, dağıtımlardan sağ çıkan sıcak bir
önbellek. Karşılığında sıcak yola bir **ağ adımı** ve yavaşlayabilen, dolabilen, ölebilen yeni bir
**bağımlılık** giriyor. Bu seviyenin kuralı: *bağımlı olduğun bir önbellek artık önbellek değil,
veritabanıdır — arızasını hayatta kalınabilir yapmadıkça.*

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

Artık **iki** tek nokta arıza var: Postgres (P02-03) ve Redis (P04-01). İkincisi ölümcül değil
(fail-open ile DB'ye düşülüyor) — ama bu bir söz değil bir **bahis**: DB'nin, önbelleğin sakladığı
yükü aniden kaldırabileceğine bahse giriyorsun.

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P03-01 | Silinen link diğer pod'larda yaşıyor | Tek paylaşılan önbellek: `DEL` herkesi etkiler |
| P03-02 | Rollout = soğuk önbellek | Önbellek pod'un dışında; pod ölse de yaşar |
| P03-03 | Aynı veri N kopya | Bellek bir kez ödeniyor (pod bellek limiti 384Mi → 256Mi'ye **düştü**) |
| P03-04 | Hit oranı replika sayısıyla düşer | Tek önbellek; replika sayısı hit oranını etkilemiyor |

**Dikkat:** P03-05 (singleflight) listede **yok**. Pod içi singleflight kalktı; süreçler arası
birleştirme dağıtık kilit ister ve o kilit kira süresi, yenileme ve kendi arıza senaryosunu getirir.
Kalan izdiham, istek hızıyla değil **replika sayısıyla** sınırlı — `internal/cache/redis.go`
bunu gerekçesiyle yazıyor. *Kilit satın almadan önce hangi izdihama sahip olduğunu bil.*

## 4. Ayağa kaldırma

Platform bir kere kurulur (`cd platform && make minimal`). Sonra bu klasörde:

```bash
make up            # build → push → deploy → rollout wait → smoke
curl -s -XPOST http://lvl04.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'
curl -I http://lvl04.localtest.me/<code>
make grafana       # Ladder klasörü, level=lvl04
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make down
```

Redis'e bakmak için:
```bash
kubectl -n lvl04 exec -it $(kubectl -n lvl04 get pod -l app.kubernetes.io/name=redis -o name) -c redis -- redis-cli
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). Davranış değişikliği yok.

Yalnızca `TRAP_DEBUG_KEYS` açıkken ek bir uç belirir: `GET /debug/keys` (P04-07). Varsayılan kapalı.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P04-01 | Redis düşünce yük DB'ye iner | `CONFIRM=1 make repro P=P04-01` | Redis → redis_up; Postgres → queries | 10 · 14 |
| P04-02 | Önbellek isabeti artık ağ üzerinden | `make repro P=P04-02` | App RED → p50/p99 | 14 (L1+L2) |
| P04-03 | Sıcak anahtar = tek Redis çekirdeği | `make repro P=P04-03` | Redis → CPU, ops/s | 14 |
| P04-04 | **TRAP** jitter yok → dalga birleşiyor | `make repro P=P04-04` | Postgres → DB queries | seviye içi |
| P04-05 | Cache-aside yarışı: bayat kayıt geri yazılıyor | `make repro P=P04-05` | Cache → ops by result | tartışma |
| P04-06 | maxmemory + noeviction → sessizce durur | `make repro P=P04-06` | Redis → memory vs maxmemory | seviye içi |
| P04-07 | **TRAP** `KEYS *` Redis'i kilitler | `make repro P=P04-07` | Redis → commands by type | seviye içi |

---

### P04-01 · Redis düşünce bütün yük DB'ye iner

**Belirti:** Redis pod'u ölünce hizmet **devam eder** (5xx yok) ama DB okuma yükü kat kat artar.
**Neden:** Fail-open doğru karardır: önbellek yoksa DB'ye düş, hizmeti kesme. Ama bu bir bahistir —
önbellek %95 hit oranıyla çalışıyorsa, kaybı DB için **20 kat** yük artışı demektir.
[Topic · Konu: Fail-open, bağımlılık arızası, degrade]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P04-01` — önbellekli tabanı ölçer, Redis'i siler, aynı yükü tekrar verir

**Grafana:** `06 · Redis` → "redis_up"; `04 · Cache` → "cache load error"; `05 · Postgres` → "DB queries by op".
**Nerede çözülüyor:** 10 (bulkhead: DB'ye giden eşzamanlılığı sınırla, fazlasını hızlıca reddet —
kısmi hizmet, tam çöküşten iyidir) · 14 (L1+L2: pod içinde küçük bir önbellek, Redis düşse de en
sıcak anahtarlar ayakta kalır).
**Asıl soru:** "Redis düşerse ne olur?" değil, **"DB o anki yükü kaldırabilir mi?"** Kaldıramazsa
fail-open kesintiyi ortadan kaldırmaz, yalnızca Redis'ten DB'ye **taşır**.

---

### P04-02 · Paylaşılan önbelleğin bedeli: bir ağ gidiş-gelişi

**Belirti:** 03'e göre p50 belirgin yüksek. Hit oranı aynı, gecikme farklı.
**Neden:** 03'te önbellek isabeti bir map aramasıydı (~100 ns). 04'te bir ağ çağrısı (~0.3–1 ms).
Tutarlılığı kazandık, gecikmeyi ödedik. [Topic · Konu: Takas, gecikme bütçesi]

**Reproduce (adım adım):**
1. `make repro P=P04-02` — ısıtır, sabit yük altında p50/p99 ölçer
2. **Karşılaştırma:** Grafana'da aynı panelde `level` seçicisini `lvl03` ↔ `lvl04` yap

**Grafana:** `02 · App RED` → "latency p50/p95/p99"; `06 · Redis` → "App → Redis latency p99".
**Nerede çözülüyor:** 14 (L1+L2). Ama dikkat: L1'i geri getirmek P03-01'i de geri getirir — bu
yüzden 14'te pub/sub ile geçersiz kılma yayını da gelecek. **Her kopya bir kanal borçlanır.**

---

### P04-03 · Sıcak anahtar: tek link, tek çekirdek

**Belirti:** Trafiğin çoğu tek bir linke gittiğinde Redis CPU'su tek çekirdekte tıkanır.
**Neden:** Redis **tek iş parçacıklıdır**. Sıcak anahtarı hangi sunucuya koyarsan koy, o anahtara
erişim tek bir çekirdeğin sınırına dayanır. Ölçeklenemeyen şey anahtar değil, **erişimdir**.
[Topic · Konu: Hot key, sharding'in sınırı]

**Reproduce (adım adım):**
1. `make repro P=P04-03` — Redis'in **tavanını doğrudan ölçer** (`redis-benchmark`: 100k anahtara
   dağıtılmış GET vs **tek** anahtara GET), sonra `hot-key` yükünü verip uygulamanın o tavanın
   yüzde kaçını kullandığını gösterir

**Ölçüm dersi — "CPU arttı mı?" yanlış soru:** İlk hâl dağıtık yük ile sıcak yükün Redis CPU'sunu
kıyaslıyordu. İkisi de **aynı sayıda komut** üretir; CPU da aynı çıkar ve script "sorun yok" der.
Oysa sorun CPU'nun artması değil, **tavanın yeri**: tek anahtarın tavanı tek instance'ın tavanıdır
ve sharding onu yükseltmez. *Ölçemediğin bir sınırı, sınırın kendisini ölçerek göster.* Bu kümede
tavana çarpmıyoruz — ve bu dürüst bir sonuç: sorun "şu an yavaşız" değil, "büyüyünce çare yok".

**Grafana:** `06 · Redis` → "Redis CPU", "ops/s".
**Nerede çözülüyor:** 14 (L1). **Redis cluster bu sorunu çözmez** — sıcak anahtar tek shard'a düşer.
Gerçek seçenekler: anahtarı çoğaltmak (`key:1..N`, tutarlılık maliyeti), pod içi L1 (en sıcak
anahtar hiç ağa çıkmaz) ya da CDN/edge (en popüler linkler uygulamaya hiç ulaşmaz).

---

### P04-04 · TRAP · Jitter yokluğu paylaşılan önbellekte daha kötü

**Belirti:** DB grafiğinde düzenli, keskin darbeler — 03'tekinden daha keskin.
**Neden:** 03'te her pod kendi dalgasını üretiyordu ve dalgalar birbirini kısmen örtüyordu. 04'te
**tek** önbellek var: tüm pod'lar aynı anahtarların aynı anda dolduğunu aynı anda görür. Dalga
bölünmez, **birleşir**. [Topic · Konu: Korelasyon, paylaşılan kaynak]

**Reproduce (adım adım):** `make repro P=P04-04` — TTL'i 30 sn'ye çeker, 300 kodluk kümeyi
ısıtır, jitter açık/kapalı 150'şer saniye yük verip **tepe/ortalama** oranını kıyaslar (~8 dk).
Saniyelik seriler `/tmp/p0404-jitter.txt` ve `/tmp/p0404-nojitter.txt`.

**Ölçüm notu (P03-07 ile aynı):** Darbe 1-2 saniye sürüyor, Prometheus 15 sn'de bir örnekliyor ve
`rate()` onu düzlüyor. Script pod'un `/metrics` ucunu **saniyede bir** kendisi örnekliyor. Sayaç
`cache_ops_total{result="miss"}`: TTL Redis tarafında dolduğu için uygulama "expired" değil **ıska**
görür; ilk ısınma saniyeleri atlanır.

**Grafana:** `05 · Postgres` → "DB queries by op"; `06 · Redis` → "evicted / expired keys".
**Ders:** Paylaşmak, hizalanmayı da paylaşmaktır.

---

### P04-05 · Cache-aside yarışı: bayat kayıt geri yazılıyor

**Belirti:** Silinmiş bir link, silme işleminden sonra bile TTL boyunca yönlendirmeye devam ediyor —
**paylaşılan** önbellekte, yani P03-01'in çözülmüş olmasına rağmen.
**Neden:** Kalıcı bayatlık şu sıradan doğar:
1. bir **okuma** önbelleği ıskalar ve DB'den eski değeri alır,
2. tam o sırada başkası satırı **siler**: DB'den gider, önbellek geçersiz kılınır — ama anahtar
   önbellekte **henüz yok**, yani geçersiz kılma hiçbir şeyi silmez,
3. 1. adımdaki okuma nihayet önbelleğe **yazar**: silinmiş kayıt TTL boyunca yaşar.

Pencere normalde mikrosaniyeler; **küçük olması yok olduğu anlamına gelmez**, yeterli trafikte her
pencere er geç yakalanır. [Topic · Konu: Cache-aside'ın yapısal sınırı, yarış]

**Reproduce (adım adım):**
1. `make repro P=P04-05` — `TRAP_READ_FILL_DELAY_MS=1500` ile **okuma yolundaki** pencereyi
   (DB'den al → önbelleğe yaz) ölçülebilir hâle getirir, tam ortasında siler, sonucu sayar

**Ölçüm dersi — yanlış pencereyi büyütmek:** Bu deneyin ilk hâli gecikmeyi *silme ile geçersiz
kılma* arasına koyuyordu (üstelik `defer` ile, yani ikisi de bittikten sonra). O pencerede anahtar
hâlâ önbellektedir: okuyanlar bayat değeri zaten hit olarak alır ve geçersiz kılmadan sonra iş
düzelir — **kalıcı** bayatlık üretmez. "Yarışı büyüttüm" demeden önce hangi iki olayın yarıştığını
yaz; yoksa bir şeyi ölçtüğünü sanarak başka bir şeyi ölçersin.

**Grafana:** `04 · Cache` → "ops by result & layer"; `03 · App Business` → "redirect sonuçları".
**Nerede çözülüyor:** Bu bir *tartışma* maddesi, çünkü bedava çözümü yok:
- **delayed double delete** — yazmadan sonra bir kez daha sil (pencereyi daraltır, kapatmaz),
- **sürümlü anahtar** (`link:v2:<code>`) — eski anahtar hiç okunmaz, yerine bellek maliyeti,
- **write-through + kısa TTL** — yazma yolu yavaşlar.
Sırayı ters çevirmek (önce önbelleği sil, sonra DB) yarışı yok etmez, **yerini değiştirir**.

---

### P04-06 · maxmemory + noeviction → önbellek sessizce önbelleklemeyi bırakır

**Belirti:** Redis ayakta, `PING` cevap veriyor, okumalar çalışıyor — ama yeni hiçbir şey önbelleğe
girmiyor. Uygulama logunda `OOM command not allowed when used memory > 'maxmemory'`.
**Neden:** `noeviction` politikası, bellek dolduğunda **yazmayı reddeder**. Önbellek "ayakta"dır ve
artık hiçbir işe yaramamaktadır — en sinsi arıza türü: görünürde sağlıklı, işlevsiz.
[Topic · Konu: Eviction politikası, sessiz bozulma]

**Reproduce (adım adım):**
1. `make repro P=P04-06` — `maxmemory`'yi deney süresince **4 MB**'a çeker, 1200 link × ~6 KB URL
   üretip okur (20 paralel), `cache_errors_total{op="set"}` ile `redis_evicted_keys_total`'ı
   karşılaştırır, sonunda ayarı geri alır

**Ölçüm dersi — deneyi ölçeğe uydur:** İlk hâl 6000 *küçük* link ile 64 MB'lık Redis'i doldurmayı
umuyordu; ~3 MB yazıp "doldurma gözlenmedi" diyordu. Ya veriyi büyüt ya sınırı küçült — burada
ikisi de yapılıyor ki deney dakikalar değil saniyeler sürsün. Sınırı geçici olarak küçültmek
meşrudur, **değiştirdiğini söylediğin sürece**.

**Grafana:** `06 · Redis` → "memory vs maxmemory", "evicted / expired keys"; `04 · Cache` → "cache load error".
**Ayırt etme kuralı:** `eviction = 0` **ve** `SET hatası > 0` → politika `noeviction`.
`allkeys-lru` olsaydı eviction > 0 olur, SET hatası olmazdı.
**Çözüm:** `redis-cli CONFIG SET maxmemory-policy allkeys-lru`. Ama asıl karar şudur: önbelleğin
**boyutu** çalışma kümesini karşılıyor mu? Karşılamıyorsa hangi politikayı seçersen seç hit oranı
düşer — LRU yalnızca düşüşü kibarlaştırır.

---

### P04-07 · TRAP · `KEYS *` tek komutla tüm Redis'i kilitler

**Belirti:** "Sadece debug için" eklenmiş bir uç çağrıldığında **tüm** redirect'lerin gecikmesi
aynı anda sıçrar.
**Neden:** Redis tek iş parçacıklıdır: bir komut çalışırken diğerleri sırada bekler. `KEYS` O(N)'dir.
Bir milyon anahtarda bu, saniyelerce tam durma demektir. [Topic · Konu: Bloklayan komutlar]

**Reproduce (adım adım):**
1. `make repro P=P04-07` — tuzağı açar, 4000 anahtar doldurur, yük altında `/debug/keys` çağırır

**Grafana:** `06 · Redis` → "commands by type" (`KEYS` görünürse alarm), "App → Redis latency p99".
**Güvenli karşılığı:** `SCAN` (imleç tabanlı, çağrı başına sınırlı iş) ya da kendi tuttuğun bir sayaç.
**Akrabaları:** `FLUSHALL`, büyük bir hash'te `HGETALL`, sınırsız `SMEMBERS`, `DEBUG SLEEP`.
*"Sadece debug ucu" cümlesi, bunun üretime nasıl ulaştığının tam açıklamasıdır.*

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_NO_TTL_JITTER` | TTL'e rastgelelik eklemez | `make repro P=P04-04` | Bayrağı kapat |
| `TRAP_READ_FILL_DELAY_MS` | Okuma yolunda DB'den alma ile önbelleğe yazma arasına gecikme koyar | `make repro P=P04-05` | Pencereyi daralt (yapısal olarak kapatılamaz) |
| `TRAP_DEBUG_KEYS` | `GET /debug/keys` ucunu açar (`KEYS *`) | `make repro P=P04-07` | Ucu kaldır; `SCAN` kullan |
| `TRAP_NO_NEGATIVE_CACHE` | (03'ten devam) "yok" cevabını önbelleklemez | `make repro P=P03-06` (03'te) | Bayrağı kapat |

Elle denemeye değer:
- `redis-cli CONFIG SET maxmemory-policy allkeys-lru` sonra P04-06'yı tekrar koş: SET hatası biter,
  eviction başlar. **Aynı dolu önbellek, tamamen farklı arıza davranışı.**
- `REDIS_TIMEOUT=5s` yap ve Redis'e `make chaos C=redis-delay-3s` uygula: uzun timeout'un neden
  yanlış olduğunu ölç — yavaş bir önbelleği beklemek, DB'ye gitmekten kötüdür.
- `make load S=scan` koş ve `06 · Redis` → "keyspace hit/miss" panelini izle: negatif önbellek
  Redis'te de çalışıyor mu?
- `kubectl -n lvl04 scale statefulset redis --replicas=0` ile Redis'i kalıcı olarak kapat ve
  `make load S=mixed` koş: sistem tamamen 02 davranışına döner. **Önbellek bir katmandır, bir bağımlılık değil** — bunu koruyabildiğin sürece.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| `06 · Redis` | **Dolu** ✨ | redis_exporter: ops, hit/miss, bellek, eviction, komut dağılımı |
| `04 · Cache` | Dolu | `layer="l2"` (03'te `layer="l1"` idi — aynı panel, farklı katman) |
| `05 · Postgres` | Dolu | Artık çok daha az okuma görüyor |
| `02 · App RED` · `03 · App Business` · `01 · Pods` · `10 · Rate limit` · `15 · k6` | Dolu | — |
| `07 · Analytics` · `08 · Stream` · `09 · Autoscaling` | Boş | — |
| `11 · Resilience` · `12 · SLO` · `13 · Rollout` | Boş | — |

`cache_ops_total`'daki `layer` label'ı tam da bunun için var: 03 ve 04 aynı paneli kullanıyor,
yalnızca katman adı değişiyor. `level` dropdown'ı ile `lvl03` ↔ `lvl04` geçişi yapıp **aynı yük
altında** hit oranını, DB qps'ini ve p50'yi kıyaslamak bu seviyenin asıl egzersizi.

## 9. Bilerek bırakılanlar

- **Redis tek kopya**, Sentinel/cluster yok, kalıcılık kapalı (P04-01 → 14).
- **`maxmemory 64mb` + `noeviction`** (P04-06 → seviye içi).
- **Süreçler arası singleflight yok** — gerekçesi `internal/cache/redis.go`'da.
- **Cache-aside yarışı açık** (P04-05) — yapısal, azaltılabilir ama yok edilemez.
- **L1 yok**: her isabet ağ üzerinden (P04-02, P04-03 → 14).
- **Tıklama sayacı hâlâ istek yolunda ve DB'de** (P02-08 → 05). Bu seviyenin kaldırmadığı yük bu.
- **02'den devreden her şey**: tek Postgres, havuz limiti, düz metin sırlar, süreç içi hız sınırı.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 03 ile farkı gösterir:

1. **`internal/cache/redis.go`** (yeni) ve **`cache.go`** (duruyor ama artık kullanılmıyor):
   L1 kodu silinmedi — 14'te geri gelecek. Duran ama bağlanmamış kod, merdivende bir *niyet
   beyanıdır*.
2. **`internal/store/cached.go`**: dekoratörün gövdesi neredeyse aynı; değişen tek şey önbelleğin
   **nerede** durduğu ve `Invalidate`'in artık `ctx` alması. Arayüz doğru seçilmişse mimari
   değişiklik küçük bir diff üretir.
3. **`deploy/redis.yaml`** (yeni): tek replika, `maxmemory 64mb`, `noeviction`, kalıcılık kapalı —
   dördü de bilinçli ve her biri bir sorunun kaynağı.
4. **`deploy/deployment.yaml`**: pod bellek limiti **384Mi → 256Mi**. Önbelleği dışarı taşımanın
   ölçülebilir kazancı; P03-03'ün çarpanı ortadan kalktı.
5. **`internal/httpapi/handlers.go`**: `/debug/keys` ucu — yalnızca tuzak açıkken kayıtlı.
   Tehlikeli bir şeyi *varsayılan olarak kapalı* tutmanın nasıl göründüğüne dair bir örnek.
