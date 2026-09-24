# 04 — redis-cache · "Paylaşılan önbellek"

> **Bu seviyede ne yaşayacaksın?**
> - 03'ün tutarsızlıklarının tek hamlede kapanması: tek kopya, tek geçersiz kılma, dağıtımlardan sağ çıkan sıcak önbellek
> - Redis ölünce bütün yükün DB'ye inmesi (P04-01); her okumaya bir ağ adımı eklenmesi (P04-02)
> - Tek sıcak linkin Redis'in tek çekirdeğine yığılması (P04-03); tuzak: jitter yokluğunun paylaşılan önbellekte daha kötü olması (P04-04)
> - Cache-aside yarışında bayat kaydın geri yazılması (P04-05); `maxmemory` + `noeviction` ile önbelleğin sessizce önbelleklemeyi bırakması (P04-06); tuzak: `KEYS *`'in tek komutla bütün Redis'i kilitlemesi (P04-07)
>
> **Bu seviye olmasa ne olur?** Silinen link pod'larda yaşamaya devam eder, her rollout önbelleği soğutup DB'yi yakar ve isabet oranı replika sayısıyla düşer (P03-01 … P03-04).
>
> **Yeni gelen teknolojiler:** Redis 7, go-redis, redis_exporter, Chaos Mesh ile Redis öldürme ve geciktirme ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

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

**Dikkat:** P03-05 (singleflight) listede **yok**. Pod içi singleflight L2'de de duruyor, ama
yalnızca pod başına birleştirir; süreçler arası birleştirme dağıtık kilit ister ve o kilit kira
süresi, yenileme ve kendi arıza senaryosunu getirir. Kalan izdiham, istek hızıyla değil **replika
sayısıyla** sınırlı — `internal/cache/redis.go` bunu gerekçesiyle yazıyor. *Kilit satın almadan
önce hangi izdihama sahip olduğunu bil.*

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl04.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl04.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl04 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P04-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
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
| P04-01 | Redis düşünce yük DB'ye iner | `CONFIRM=1 make repro P=P04-01` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl04&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Veritabanı sorguları (türe göre)" | 10 · 14 |
| P04-02 | Önbellek isabeti artık ağ üzerinden | `make repro P=P04-02` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Komut / sn" | 14 (L1+L2) |
| P04-03 | Sıcak anahtar = tek Redis çekirdeği | `make repro P=P04-03` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Komutlar (türe göre)" | 14 |
| P04-04 | **TRAP** jitter yok → dalga birleşiyor | `make repro P=P04-04` | görünmez — kanıt terminalde ↓ | seviye içi |
| P04-05 | Cache-aside yarışı: bayat kayıt geri yazılıyor | `make repro P=P04-05` | görünmez — kanıt terminalde ↓ | tartışma |
| P04-06 | maxmemory + noeviction → sessizce durur | `make repro P=P04-06` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Bellek ve üst sınır" | seviye içi |
| P04-07 | **TRAP** `KEYS *` Redis'i kilitler | `make repro P=P04-07` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl04&from=now-15m&to=now&refresh=10s) → "Komutlar (türe göre)" | seviye içi |

---

### P04-01 · Redis düşünce bütün yük DB'ye iner

**Belirti:** Redis pod'u ölünce hizmet **devam eder** (5xx yok) ama DB okuma yükü kat kat artar.
**Neden:** Fail-open doğru karardır: önbellek yoksa DB'ye düş, hizmeti kesme. Ama bu bir bahistir —
önbellek %95 hit oranıyla çalışıyorsa, kaybı DB için **20 kat** yük artışı demektir.
[Topic · Konu: Fail-open, bağımlılık arızası, degrade]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P04-01` — önbellekli tabanı ölçer, Redis'i siler, aynı yükü tekrar verir

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl04&from=now-15m&to=now&refresh=10s), [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl04&from=now-15m&to=now&refresh=10s) — script iki yük fazı koşar (önbellekli taban, sonra Redis silinmiş hâlde aynı yük); bitince aç (giriş: admin / ladder)
- "Veritabanı sorguları (türe göre)" → `get` serisi ilk fazda yere yakın; Redis silindiği anda kat kat yükselir. Redis kısa sürede geri gelir ama **boş** doğar (kalıcılık kapalı), bu yüzden `get` önbellek yeniden ısınana kadar yüksek kalır. `increment_clicks` iki fazda aynı: o yük zaten hiç önbelleklenmiyordu.
- "Önbellek yazma/okuma hatası" (Cache) → Redis yokken `get` ve `set` serileri belirir: uygulama Redis'e ulaşamıyor ve DB'ye düşüyor (fail-open). `load` 0'da kalır — DB sağlam. (`06 · Redis` → "redis_up" bu kesintiyi 0 olarak göstermez: exporter Redis'le aynı pod'da yan konteyner, pod'la birlikte ölür; çizgide yalnızca kısa bir boşluk görürsün.)
- "Önbellek işlemleri (katman ve sonuca göre)" (Cache) → Redis ölünce `l2 hit` 0'a düşer, yerini `l2 miss` alır; Redis dönünce `l2 hit` yavaş yavaş geri gelir.
- "Dönen durum kodları" (k6) → `302` çizgisi kesintisiz sürer, `5xx` çıkmaz: hizmet devam etti, bedeli kullanıcı değil DB ödedi. Kodlar için bkz. [Grafana'yı okumak](../README.md#grafanayı-okumak).

**Nerede çözülüyor:** 10 (bulkhead: DB'ye giden eşzamanlılığı sınırla, fazlasını hızlıca reddet —
kısmi hizmet, tam çöküşten iyidir) · 14 (L1+L2: pod içinde küçük bir önbellek, Redis düşse de en
sıcak anahtarlar ayakta kalır).
**Asıl soru:** "Redis düşerse ne olur?" değil, **"DB o anki yükü kaldırabilir mi?"** Kaldıramazsa
fail-open kesintiyi ortadan kaldırmaz, yalnızca Redis'ten DB'ye **taşır**.

---

### P04-02 · Paylaşılan önbelleğin bedeli: bir ağ gidiş-gelişi

**Belirti:** Önbelleğe sormanın bedeli iki-üç büyüklük mertebesi arttı: 03'te bir isabet pod içi bir
map aramasıydı (~1 µs), 04'te her isabet bir Redis `GET`, yani bir ağ gidiş-gelişi (yüzlerce µs).
Hit oranı aynı, bedel farklı. Uçtan uca redirect p50'sinde bu fark zor görünür — asıl ölçü önbellek
aramasının kendi süresi.
**Neden:** Önbellek artık süreç dışında. Tutarlılığı kazandık, gecikmeyi ödedik.
[Topic · Konu: Takas, gecikme bütçesi]

**Reproduce (adım adım):**
1. `make repro P=P04-02` — ısıtır, sabit yük altında önbelleğe sormanın süresini ölçer
   (`cache_lookup_duration_seconds{layer="l2"}`, 1 µs'den başlayan kovalar) ve aramaların ne kadarının
   ağ katmanına gittiğini hesaplar. Hüküm: aramaların ≥%90'ı ağda **ve** p50 ≥ 50 µs (bellek içi bir
   aramanın on katından fazla)
2. **Karşılaştırma, aynı aletle:** 03 aynı histogramı `layer="l1"` için yayınlıyor. 03'te
   `make load S=redirect` koşmuşsan (Prometheus ~6 sa saklar) script 03'ün L1 p50'sini de basar

**Ölçüm dersi — uçtan uca p50 hükmü 03'ü de "reproduce" eder:** "Uçtan uca redirect p50'si 0.5 ms'yi
geçiyor mu?" yanlış sorudur. HTTP histogramının en küçük kovası 1 ms — milisaniyenin altındaki bir fark
o kovadan okunamaz; üstelik 03'te de 04'te de her tıklama DB'ye bir UPDATE atıyor (P02-08), yani p50
iki seviyede de 0.5 ms'nin üstünde. Bu ölçü, iddia yanlışken de aynı sonucu verir. *Farkı ölçmek
istediğin şeyin çözünürlüğü, farkın kendisinden ince olmalı* — ve ölçtüğün şey iddianın kendisi olmalı,
onu içinde taşıyan daha büyük bir sayı değil.

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s), [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl04&from=now-15m&to=now&refresh=10s) — script bitince aç; asıl sayı hiçbir panelde yok, Explore'da (giriş: admin / ladder)
- Explore'da: `histogram_quantile(0.5, sum by (le, namespace, layer) (rate(cache_lookup_duration_seconds_bucket{namespace=~"lvl03|lvl04"}[1m])))` → `lvl04 l2` çizgisi yüzlerce µs'de; zaman aralığı 03 koşunu da kapsıyorsa `lvl03 l1` çizgisi ~1 µs'de — aynı isabet, iki-üç büyüklük mertebesi farkı. Hiçbir panel bu metriği çizmiyor.
- "Komut / sn" (Redis) → redirect hızıyla birlikte artar: her isabet bir Redis `GET`, yani bir ağ çağrısı.
- "İsabet oranı (toplam)" (Cache) → yüksek: fark ıskadan gelmiyor, isabetin **nerede** olduğundan geliyor.
- "Gecikme (p50 / p95 / p99)" (App RED) → p50 çizgisi `lvl03` ile `lvl04` arasında ya hiç ya da ancak kabaca ayrışır: fark 1 ms'nin altında, histogramın en küçük kovası 1 ms ve p50'nin büyük kısmı iki seviyede de ortak olan tıklama UPDATE'i (P02-08). Bu panelden hüküm çıkmaz (yukarıdaki ölçüm dersi).
- "Uygulama → Redis gecikmesi (p99)" → bu seviyede **boştur**: o panel `dependency_request_duration_seconds`'ı çizer ve uygulama onu ancak 10'dan itibaren yayınlıyor. Redis'e sormanın süresi için yukarıdaki Explore sorgusu.

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

**Ölçüm dersi — "CPU arttı mı?" yanlış soru:** Dağıtık yük ile sıcak yükün Redis CPU'sunu kıyaslamak
işe yaramaz: ikisi de **aynı sayıda komut** üretir; CPU da aynı çıkar ve hüküm "sorun yok" olur.
Oysa sorun CPU'nun artması değil, **tavanın yeri**: tek anahtarın tavanı tek instance'ın tavanıdır
ve sharding onu yükseltmez. *Ölçemediğin bir sınırı, sınırın kendisini ölçerek göster.* Bu kümede
tavana çarpmıyoruz — ve bu dürüst bir sonuç: sorun "şu an yavaşız" değil, "büyüyünce çare yok".

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) — script bitince aç; tavanın kendisi Grafana'da değil terminalde ölçülür (giriş: admin / ladder)
- "Komutlar (türe göre)" → hot-key yükü boyunca `get` serisinde bir plato: uygulamanın Redis'e yaptırdığı GET hızı. Bunu script'in terminalde bastığı `TEK anahtar GET tavanı` ile kıyasla — script bu oranı "tavanın %…'i kullanılıyor" diye basar. Platonun başında görebileceğin kısa tepe, script'in pod içinde koştuğu `redis-benchmark`'tır, uygulama değil.
- "Redis CPU" → sıcak yükte bile tek çekirdeğin (1.0) altında kalır: bu kümede tavana çarpmıyoruz. Sorun "şu an yavaşız" değil, "büyüyünce çare yok".
- "Komut / sn" → panelin içindeki küçük eğri yük boyunca aynı platoyu çizer; büyük rakam yalnızca son değeri gösterir (script bitince düşük okursun).

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

**Ölçüm notu (P03-07 ile aynı):** Darbe 1-2 saniye sürüyor, Prometheus uygulamayı 10 sn'de bir kazıyor ve
`rate()` onu düzlüyor. Script pod'un `/metrics` ucunu **saniyede bir** kendisi örnekliyor. Sayaç
`cache_ops_total{result="miss"}`: TTL Redis tarafında dolduğu için uygulama "expired" değil **ıska**
görür; ilk ısınma saniyeleri atlanır.

**Grafana'da gör:** Grafana'da görünmez — darbe 1-2 saniye sürer; Prometheus seyrek kazır ve paneller 1 dakikalık `rate` çizer, yani tepe tam da düzlenen şeydir (yukarıdaki ölçüm notu). `05 · Postgres` → "Veritabanı sorguları (türe göre)" (`get`) ve `06 · Redis` → "Silinen / süresi dolan anahtar" (`süresi doldu`) iki fazda da benzer, düz çizgiler olur: aynı sayıda anahtar doluyor, fark yalnızca bunun aynı saniyeye yığılıp yığılmadığında. Kanıt terminalde:
- `make repro P=P04-04` → `jitter'lı: tepe=… ort=… → tepe/ortalama=…` ve `jitter'sız: …` satırları; jitter'sız tepe/ortalama oranı belirgin biçimde büyük
- `paste /tmp/p0404-jitter.txt /tmp/p0404-nojitter.txt | head -90` → her satır bir saniyedeki ıska sayısı (tek pod): soldaki sütun küçük, dağınık sayılar; sağdaki çoğunlukla 0 ve ~30 satırda bir büyük bir sayı — testere dişi

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

**Ölçüm dersi — yanlış pencereyi büyütmek:** Gecikmeyi *silme ile geçersiz kılma* arasına koymak
yanlış pencereyi büyütür (hele `defer` ile konursa ikisi de bittikten sonra çalışır). O pencerede anahtar
hâlâ önbellektedir: okuyanlar bayat değeri zaten hit olarak alır ve geçersiz kılmadan sonra iş
düzelir — **kalıcı** bayatlık üretmez. "Yarışı büyüttüm" demeden önce hangi iki olayın yarıştığını
yaz; yoksa bir şeyi ölçtüğünü sanarak başka bir şeyi ölçersin.

**Grafana'da gör:** Grafana'da görünmez — bayat bir isabet, geçerli bir isabetle aynı sayaçlara yazılır: `04 · Cache` → "Önbellek işlemleri (katman ve sonuca göre)" onu `l2 hit`, `03 · App Business` → "Yönlendirme sonuçları" onu `ok` sayar. Hiçbir metrik "bu kayıt DB'de artık yok" demez; üstelik deney yalnızca birkaç düzine istek atar. Kanıt terminalde:
- `make repro P=P04-05` → `deneme i: kod=… → 302 (SİLİNMİŞ ama hâlâ yönlendiriyor)` satırları
- `kubectl -n lvl04 exec redis-0 -c redis -- redis-cli TTL linkly:link:<kod>` (kodu script çıktısından al; TTL 60 sn, script bittikten sonraki ilk dakika içinde koş) → pozitif bir sayı: `DELETE` 204 döndüğü hâlde kayıt Redis'te TTL dolana kadar yaşıyor (`-2` olsaydı anahtar yoktu)

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

**Ölçüm dersi — deneyi ölçeğe uydur:** 6000 *küçük* link 64 MB'lık Redis'i dolduramaz: ~3 MB
yazılır ve "doldurma gözlenmedi" sonucu çıkar. Ya veriyi büyüt ya sınırı küçült — burada
ikisi de yapılıyor ki deney dakikalar değil saniyeler sürsün. Sınırı geçici olarak küçültmek
meşrudur, **değiştirdiğini söylediğin sürece**.

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now&refresh=10s) — doldurma saniyeler sürer; script bitince aç (giriş: admin / ladder)
- "Bellek ve üst sınır" → `üst sınır` çizgisi deney süresince 64 MB'tan **4 MB**'a iner (script geçici olarak küçültüyor); `kullanılan` hızla ona dayanır ve orada **düz** kalır. Deney bitince script ayarı geri alıp önbelleği boşaltır: `üst sınır` 64 MB'a döner, `kullanılan` düşer.
- "Silinen / süresi dolan anahtar" → `yer açmak için silindi` **0**'da kalır: Redis dolu olduğu hâlde hiçbir şey atmıyor.
- "Önbellek yazma/okuma hatası" (Cache) → `set` serisi yükselir: her yeni kayıt `OOM command not allowed` ile reddediliyor. `evicted = 0` ile `set > 0` yan yana = `noeviction` imzası (aşağıdaki ayırt etme kuralı).
- "Redis ayakta mı" → deney boyunca **1**: Redis "sağlıklı". Bir sağlık kontrolü bu arızayı asla yakalamaz.

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

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl04&from=now-15m&to=now&refresh=10s) — script iki fazı (temiz, sonra ortasında `KEYS *`) 45'er sn koşar; bitince aç (giriş: admin / ladder)
- "Komutlar (türe göre)" → `keys` serisi yalnızca ikinci fazda belirir. Hızı çok küçük (üç çağrı), `get`'in yanında çizgi görünmez; lejantta `keys`'e tıklayıp yalnız onu göster. Bu seri üretimde hiç var olmamalı — görünmesi alarmdır.
- "p99 süre (uç noktaya göre)" (App RED) → `/{code}` p99'u ikinci fazda, `KEYS` çağrılarının olduğu anda birinci fazın tepesinin üstüne çıkar: tek iş parçacıklı Redis o süre boyunca GET'leri sıraya aldı.
- "Uygulama → Redis gecikmesi (p99)" → bu seviyede **boştur** (bağımlılık gecikmesi 10'dan itibaren ölçülüyor); gecikmeyi uygulama tarafından, yukarıdaki p99'dan oku.
- Explore'da: `redis_commands_duration_seconds_total{namespace="lvl04",cmd="keys"} / redis_commands_total{namespace="lvl04",cmd="keys"}` → tek bir `KEYS` çağrısının ortalama süresi (saniye). Aynı sorguyu `cmd="get"` ile koş: `KEYS` kat kat uzun — ve o süre boyunca Redis başka hiçbir komut çalıştırmadı.

**Güvenli karşılığı:** `SCAN` (imleç tabanlı, çağrı başına sınırlı iş) ya da kendi tuttuğun bir sayaç.
**Akrabaları:** `FLUSHALL`, büyük bir hash'te `HGETALL`, sınırsız `SMEMBERS`, `DEBUG SLEEP`.
*"Sadece debug ucu" cümlesi, bunun üretime nasıl ulaştığının tam açıklamasıdır.*

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

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
- `make load S=scan` koş ve `06 · Redis` → "Redis'te bulundu / bulunamadı" panelini izle: negatif önbellek
  Redis'te de çalışıyor mu?
- `kubectl -n lvl04 scale statefulset redis --replicas=0` ile Redis'i kalıcı olarak kapat ve
  `make load S=mixed` koş: sistem tamamen 02 davranışına döner. **Önbellek bir katmandır, bir bağımlılık değil** — bunu koruyabildiğin sürece.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl04&from=now-15m&to=now) | **Dolu** ✨ | redis_exporter: ops, hit/miss, bellek, eviction, komut dağılımı |
| [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl04&from=now-15m&to=now) | Dolu | `layer="l2"` (03'te `layer="l1"` idi — aynı panel, farklı katman) |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl04&from=now-15m&to=now) | Dolu | Artık çok daha az okuma görüyor |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl04&from=now-15m&to=now) · [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl04&from=now-15m&to=now) · [`01 · Pods`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl04&from=now-15m&to=now) · [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl04&from=now-15m&to=now) · [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl04&from=now-15m&to=now) | Dolu | — |
| [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl04&from=now-15m&to=now) · [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl04&from=now-15m&to=now) · [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl04&from=now-15m&to=now) | Boş | — |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl04&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl04&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl04&from=now-15m&to=now) | Boş | — |

`cache_ops_total`'daki `layer` label'ı tam da bunun için var: 03 ve 04 aynı paneli kullanıyor,
yalnızca katman adı değişiyor. `level` dropdown'ı ile `lvl03` ↔ `lvl04` geçişi yapıp **aynı yük
altında** hit oranını ve DB qps'ini kıyaslamak bu seviyenin asıl egzersizi. İsabetin **bedeli** için
p50'ye değil `cache_lookup_duration_seconds{layer}`'a bak (panel yok, Explore — P04-02): uçtan uca
histogramın en küçük kovası 1 ms, fark ise mikrosaniyeler mertebesinde.

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
