# 03 — local-cache · "Süreç içi önbellek"

## 1. Bu seviye ne?

Mümkün olan en ucuz önbellek: pod'un belleğinde sınırlı bir LRU (+ TTL, singleflight, negatif
önbellek). P02-01'de ölçülen veritabanı okuma yükünün büyük kısmını kaldırıyor — ve aynı anda yeni
bir sorun sınıfı yaratıyor: artık **gerçeğin N kopyası** var ve hiçbiri ne zaman yanlışlandığını
bilmiyor. Bu seviyenin tamamı o takasın muhasebesi.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress-nginx<br/>lvl03.localtest.me]
  I --> A1 & A2 & A3

  subgraph APP["linkly · 3 replika"]
    A1["pod 1<br/>L1: LRU+TTL<br/>(kendi kopyası)"]
    A2["pod 2<br/>L1: LRU+TTL<br/>(kendi kopyası)"]
    A3["pod 3<br/>L1: LRU+TTL<br/>(kendi kopyası)"]
  end

  A1 & A2 & A3 -.->|yalnızca MISS| PG[("postgres:17<br/>× 1")]
  A1 & A2 & A3 -->|her tıklama<br/>UPDATE| PG
```

Dikkat: **okuma** yolu artık çoğunlukla DB'ye gitmiyor, ama **tıklama sayacı** hâlâ her istekte
gidiyor (P02-08 duruyor). Yani önbellek, yükün yarısını kaldırdı.

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P02-01 | Her redirect = DB sorgusu | Cache-aside: `internal/store/cached.go` dekoratörü + `internal/cache` (LRU + TTL + singleflight + negatif önbellek) |

Yalnızca bir madde — ve bilerek. Bir önbellek **tek bir şeyi** çözer: aynı veriyi tekrar tekrar
okumayı. Bağlantı havuzunu (P02-02), tek nokta arızayı (P02-03), satır kilidini (P02-08) ya da
sırları (P02-09) çözmez. Önbelleği "performans sorunlarının cevabı" sanmak, bu merdivendeki en
yaygın yanılgıdır.

## 4. Ayağa kaldırma

Platform bir kere kurulur (`cd platform && make minimal`). Sonra bu klasörde:

```bash
make up            # build → push → deploy → rollout wait → smoke
curl -s -XPOST http://lvl03.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'
curl -I http://lvl03.localtest.me/<code>
make grafana       # Ladder klasörü, level=lvl03
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Davranış değişikliği yok — **ama garanti değişti**: `GET /{code}` artık TTL kadar bayat olabilen bir
kopyadan cevaplanabilir. `GET /api/links/{code}` içindeki `clicks` alanı da önbellekten gelirse
bayattır; tıklama sayısı önbellekte **yetkili değildir**.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P03-01 | Silinen link diğer pod'larda yaşıyor | `make repro P=P03-01` | Cache → hit ratio by pod | 04 |
| P03-02 | Rollout = soğuk önbellek = DB testere dişi | `make repro P=P03-02` | Cache → miss vs DB qps | 04 |
| P03-03 | Aynı veri N pod'da N kopya | `make repro P=P03-03` | Cache → entries by pod | 04 |
| P03-04 | Hit oranı replika sayısıyla düşer | `CONFIRM=1 make repro P=P03-04` | Cache → hit ratio by pod | 04 |
| P03-05 | **TRAP** singleflight yok → stampede | `make repro P=P03-05` | Cache → stampede wait/s | seviye içi |
| P03-06 | **TRAP** negatif önbellek yok → tarama DB'ye | `make repro P=P03-06` | Cache → negative_hit | seviye içi |
| P03-07 | **TRAP** jitter yok → periyodik DB tepesi | `make repro P=P03-07` | Postgres → DB queries | seviye içi |

---

### P03-01 · Silinen link diğer pod'larda TTL boyunca yaşıyor

**Belirti:** Kullanıcı linki siler, sunucu `204` döner, veritabanında kayıt yoktur — ve link
dakikalarca çalışmaya devam eder. Hangi isteğin çalışacağı hangi pod'a düştüğüne bağlıdır.
**Neden:** `DELETE` isteği **bir** pod'a düşer; o pod kendi kopyasını temizler
(`cached.go · Invalidate`), diğer N−1 pod hiçbir şey duymaz. [Topic · Konu: Önbellek tutarlılığı, invalidation]

**Reproduce (adım adım):**
1. `make repro P=P03-01` — linki tüm pod'ların önbelleğine sokar, siler, 60 kez okur
2. Elle: `for i in $(seq 30); do curl -s -o /dev/null -w '%{http_code} ' http://lvl03.localtest.me/$code; done`

**Grafana:** `04 · Cache` → "hit ratio by pod"; `03 · App Business` → "redirect sonuçları".
**Nerede çözülüyor:** 04 (tek paylaşılan önbellek → geçersiz kılma tek yerde olur). Alternatif:
pub/sub ile yayın yapmak. Kural şu: **her kopya, bir geçersiz kılma kanalı borçlanır.** Kanalı
kurmazsan borcu kullanıcı öder — bayat veri olarak.

---

### P03-02 · Rollout = soğuk önbellek = DB'de testere dişi

**Belirti:** Her dağıtımdan sonra DB okuma grafiğinde dikey bir tepe; birkaç dakika sonra normale
dönüş. Grafik testere dişine benzer.
**Neden:** Önbellek pod'un belleğinde; pod ölünce önbellek de ölür. Her yeni pod boş doğar ve ilk
istekler zorunlu olarak DB'ye iner. [Topic · Konu: Soğuk başlangıç, kapasite planlaması]

**Reproduce (adım adım):**
1. `make repro P=P03-02` — 300 linkle ısıtır, 180 sn'lik yük altında **önce kararlı hâli**, sonra
   `rollout restart` penceresini ayrı ayrı ölçer ve ikisini kıyaslar

**Ölçüm dersi 1 — "tepe" tek başına kanıt değil:** İlk hâl tüm koşunun tepesini (`max_over_time`)
alıp sondaki orana bölüyordu. O tepe rollout'tan değil, **yükün kendi soğuk başlangıcından**
geliyordu: k6 `setup()` her koşuda yeni kodlar üretir, ilk okumaları zorunlu olarak DB'ye iner.
Script rollout'u hiç yapmasa da "REPRODUCED" derdi — nitekim 04'te (paylaşılan önbellek)
yanlışlıkla dedi ve `verify-prev`'i kırdı. *Bir olayın etkisini ölçeceksen, pencereni o olaya
hizala; "en büyük değer" nereden geldiğini söylemez.*

**Ölçüm dersi 2 — komşu olayı SUSTUR:** Pencereler düzeltilince ilk sonuç şuydu: kararlı hâl
17.6 DB get/s, rollout penceresi 12.0 get/s. Yani sinyal gürültünün *altında* kaldı. Sebep:
60 sn'lik TTL ile 200 anahtar × 3 pod sürekli yeniden doluyordu (≈10 get/s) ve bu **TTL churn**,
ölçmek istediğimiz soğuk başlangıç darbesiyle aynı büyüklükteydi. Script artık deney süresince
`CACHE_TTL=10m` yapıyor ve çalışma kümesini 2000 koda çıkarıyor: TTL dolması (P03-07) susuyor,
geriye yalnızca "pod boş doğdu" kalıyor. *Aynı grafiği iki farklı olay besliyorsa, hangisini
ölçtüğünü bilemezsin.*

**Grafana:** `04 · Cache` → "cache miss vs DB qps"; `05 · Postgres` → "DB queries by op".
**Nerede çözülüyor:** 04 (önbellek pod'un dışında; pod ölse de yaşar).
**Kritik ders:** "Önbellek sayesinde DB'yi küçülttük" tehlikeli bir cümledir. Veritabanı **soğuk
anı** kaldırabilmeli; aksi hâlde ilk dağıtım seni devirir. Kapasiteyi ortalamaya değil, **en kötü
ana** göre planla.

---

### P03-03 · Aynı veri N pod'da N kopya

**Belirti:** Üç pod, üç kez aynı 3000 kayıt. Bellek kullanımı replika sayısıyla çarpılıyor.
**Neden:** Süreç içi önbellek tanımı gereği pod başına. [Topic · Konu: Bellek maliyeti, ölçek]

**Reproduce (adım adım):**
1. `make repro P=P03-03` — 3000 linki tüm pod'lara okutur, `cache_entries`'i pod bazında basar

**Grafana:** `04 · Cache` → "entries by pod"; `01 · Pods & Resources` → "Heap alloc".
**Nerede çözülüyor:** 04. Zarf arkası: 1M sıcak link × ~200 byte × 10 pod = **2 GB**, aynı veri için
on kez. Paylaşılan önbellekte bir kez ödersin — karşılığında bir ağ gidiş-gelişi (P04-02).

---

### P03-04 · Hit oranı replika sayısıyla düşer

**Belirti:** Aynı çalışma kümesi ve aynı yük, daha fazla replika → **daha düşük** hit oranı.
Ölçekledikçe DB yükü beklediğinden yavaş azalır.
**Neden:** Load balancer istekleri rastgele dağıtır; sabit bir çalışma kümesi için her pod'un
gördüğü örneklem küçülür, ısınma N kat uzar. [Topic · Konu: Önbellek lokalitesi, dağıtım]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P03-04` — 1 replika ve çok replika ile aynı yükü koşup hit oranını kıyaslar
   (4000 kodluk çalışma kümesi, 20 VU × 60 sn; script replika sayısını deney sonunda geri alır)

**Ölçüm notu — bu deneyi üç kez yanlış kurduk, üçü de ders:**
- Çalışma kümesi 200 kodken etki ölçülemiyordu. Etkinin büyüklüğü `N × K / toplam istek`: pod sayısı
  N ve çalışma kümesi K küçükse fark gürültüye karışır. K 4000'e çıkarıldı.
- `increase(cache_ops_total[3m])` iki ölçümü birbirine karıştırıyordu: ölçekleme + restart + yük,
  iki ölçüm arasında 3 dakikadan kısa sürüyor ve pencere bir öncekinin verisini de topluyordu.
  Artık sayacın kendisi yükten **önce ve sonra** okunup fark alınıyor.
- **Hit oranı yanlış ölçüydü.** Payı (ısınma maliyeti) ve paydası (toplam istek) aynı anda oynar;
  iki koşuda oluşturulan link sayısı biraz farklı olunca oran da değişir. 04'te (paylaşılan
  önbellek) bu yüzden "oran düştü" dedi ve `verify-prev`'i kırdı. Artık **ıska sayısı** ölçülüyor:
  kaç `(pod, anahtar)` çifti ısıtıldı? Pod içi önbellekte bu sayı pod sayısıyla **çarpılır**,
  paylaşılan önbellekte **sabit** kalır. *Doğru ölçü, iddianı doğrudan sayan ölçüdür.*

**Grafana:** `04 · Cache` → "hit ratio by pod".
**Nerede çözülüyor:** 04 (sorun tamamen ortadan kalkar). Ara çözüm **consistent hashing**'dir
(aynı anahtar hep aynı pod'a) ama iki yeni sorun getirir: sıcak anahtar tek pod'a bağlanır ve
ölçekleme anında anahtarlar taşınır.

---

### P03-05 · TRAP · Singleflight olmadan izdiham (cache stampede)

**Belirti:** Hit oranı yüksek ve her şey iyi görünüyor, ama DB grafiğinde düzenli dikey darbeler var.
**Neden:** Sıcak bir anahtarın TTL'i dolduğu anda, uçuştaki **tüm** istekler aynı satır için DB'ye
gider. Yük ne kadar yüksekse darbe o kadar büyük — koruma tam da en gerekli olduğu anda yok.
[Topic · Konu: Cache stampede, singleflight]

**Reproduce (adım adım):**
1. `make repro P=P03-05` — Postgres'e 200 ms gecikme enjekte eder (Chaos Mesh), TTL'i 5 sn'ye çeker,
   `hot-key` yükü verir, önce korumalı sonra korumasız ölçer
   (Chaos Mesh kurulu değilse: `cd platform && make chaos`)

**Neden gecikme enjekte ediyoruz:** İzdihamın büyüklüğü `istek hızı × önbelleği DOLDURMA süresi`.
Bu kümede Postgres 1 ms'de cevap veriyor; delik o kadar dar ki korumasız hâlde bile içeri 1-2 istek
sızıyor ve ölçüm "sorun yok" diyor. Gerçek hayatta doldurma maliyeti 10-500 ms'dir (uzak DB, JOIN,
soğuk sayfa). 200 ms bunu temsil ediyor. **Ders: singleflight'ın değeri DB hızıyla ters orantılıdır**
— DB hızlandıkça gereksizleşir, yavaşladıkça hayat kurtarır. Korumayı "yükte lazım olur" diye değil,
"doldurma pahalı olduğunda lazım olur" diye koyarsın.

**Grafana:** `04 · Cache` → "stampede wait/s" ve "cache miss vs DB qps".
**Okuma notu:** `cache_stampede_wait_total`'ın **yükselmesi hata değildir** — o kadar çağrının DB'ye
gitmek yerine beklediğini gösterir, yani korumanın çalıştığının kanıtıdır. Bunu hit oranına bakarak
göremezsin: iki durumda da hit oranı yüksek görünür, fark yalnızca DB'deki **tepe**dedir.

---

### P03-06 · TRAP · Negatif önbellek yoksa "yok" cevabı hep DB'ye iner

**Belirti:** Var olmayan kodlara yapılan istekler (tarama, ölü linkler, yanlış yazım) önbelleği
tamamen atlar.
**Neden:** Önbellek yalnızca **var olanı** korur; **yok olan**, korumasız bir tüneldir.
[Topic · Konu: Negatif önbellek, enumeration]

**Reproduce (adım adım):**
1. `make repro P=P03-06` — `scan` senaryosuyla rastgele kodlara yük verir, açık/kapalı kıyaslar

**Grafana:** `04 · Cache` → "ops by result & layer" (`negative_hit`); `05 · Postgres` → "DB queries by op".
**Denge:** Negatif TTL **kısa** olmalı (burada 10 sn, pozitifin altıda biri) — yeni oluşturulan bir
link, eski "yok" cevabının arkasında kalmasın. Tarama ayrıca bir hız sınırı sorunudur: 08'de 404
oranına göre limit uygulanacak.

---

### P03-07 · TRAP · TTL jitter yoksa periyodik DB tepesi

**Belirti:** DB grafiğinde saat gibi işleyen, düzenli aralıklı dikey darbeler.
**Neden:** Bir dağıtımdan sonra önbellek tek seferde ısınır: binlerce anahtar aynı saniyede yazılır
ve TTL süresi sonra hepsi **aynı saniyede** dolar. Sistem kendi kendine bir yük dalgası üretir.
[Topic · Konu: Korelasyon kırma, thundering herd]

**Reproduce (adım adım):**
1. `make repro P=P03-07` — TTL'i 30 sn'ye çeker, 300 kodluk kümeyi tek seferde ısıtır, jitter
   açık/kapalı 150'şer saniye yük verip **tepe/ortalama** oranını kıyaslar (~8 dk sürer)
2. Saniyelik seriler `/tmp/p0307-jitter.txt` ve `/tmp/p0307-nojitter.txt` dosyalarında kalır —
   yan yana koyunca biri düz, diğeri testere dişi

**Ölçüm notu — bu darbeyi Prometheus'tan okuyamazsın:** Darbe 1-2 saniye sürüyor, Prometheus ise
15 saniyede bir örnekliyor ve `rate(...[30s])` onu 30 saniyeye yayıp düzlüyor; düzlenen şey tam da
ölçmek istediğin tepe. Bu yüzden script pod'un `/metrics` ucunu **saniyede bir** kendisi örnekliyor.
Kural: **ölçüm çözünürlüğün, ölçtüğün olaydan ince olmalı** (pencere kuralının kardeşi: ölçüm
penceresi de olaydan kısa olmamalı). Aynı sorun 11'de yüksek çözünürlük/exemplar başlığıyla dönecek.
Sayaç olarak `cache_ops_total{result="expired"}` seçildi: ilk ısınmanın ıskalarını saymaz, yalnızca
TTL dolmalarını sayar.

**Grafana:** `05 · Postgres` → "DB queries by op" (darbeler); `04 · Cache` → "eviction/expired".
**Okuma notu:** Bakılacak sayı ortalama değil, **tepe/ortalama oranıdır** — kapasite tepeye göre
planlanır. İki durumda da aynı sayıda anahtar dolar; fark yalnızca bunun zamana yayılıp
yayılmadığıdır. Jitter, ilişkisiz olayların ilişkili hâle gelmesini engelleyen genel bir tekniktir;
aynı fikir retry'da (10) ve zamanlanmış işlerde de karşına çıkacak.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_NO_SINGLEFLIGHT` | Eşzamanlı miss'leri birleştirmez | `make repro P=P03-05` | Bayrağı kapat |
| `TRAP_NO_NEGATIVE_CACHE` | "Yok" cevabını önbelleklemez | `make repro P=P03-06` | Bayrağı kapat |
| `TRAP_NO_TTL_JITTER` | TTL'e rastgelelik eklemez | `make repro P=P03-07` | Bayrağı kapat |
| `TRAP_READYZ_CHECKS_DB` · `TRAP_MIGRATE_IN_MAIN` | (02'den devam) | `make repro P=P02-10` (02'de) | — |

Elle denemeye değer:
- `CACHE_CAPACITY=100` yap ve `make load S=mixed` koş: kapasite çalışma kümesinden küçükse önbellek
  bir **eviction makinesine** döner; `cache_evictions_total{reason="capacity"}` tırmanır, hit oranı çöker.
- `CACHE_TTL=1h` yap ve P03-01'i koş: bayatlık penceresi bir saate çıkar. TTL, tutarlılık ile
  DB yükü arasındaki ayar düğmesidir — ve bu seviyede **tek** ayar düğmesi odur.
- `make load S=hot-key` ile `make load S=redirect` hit oranlarını karşılaştır: sıcak anahtar
  önbelleğin en iyi çalıştığı durumdur, tekdüze dağılım en kötüsü.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| `04 · Cache` | **Dolu** ✨ | `cache_ops_total{layer="l1"}`, stampede, eviction, entries |
| `05 · Postgres` | Dolu | Artık çok daha az sorgu görüyor — fark P02 ile kıyaslanarak okunur |
| `02 · App RED` · `03 · App Business` · `01 · Pods` · `10 · Rate limit` | Dolu | — |
| `06 · Redis` | Boş | L2 yok (04) |
| `07 · Analytics` · `08 · Stream` · `09 · Autoscaling` | Boş | — |
| `11 · Resilience` · `12 · SLO` · `13 · Rollout` | Boş | — |

Bu seviyenin en öğretici karşılaştırması **seviyeler arası**: `04 · Cache` panelinde `level` seçicisini
`lvl02` ↔ `lvl03` arasında değiştirip aynı yük altında DB qps'ini kıyasla. Dashboard'ların ortak ve
`$level` değişkenli olmasının sebebi tam olarak bu.

## 9. Bilerek bırakılanlar

- **Önbellek pod başına** — tutarsızlık, soğuk başlangıç, bellek çarpanı, düşen hit oranı (P03-01…04 → 04).
- **Geçersiz kılma yayını yok** (pub/sub yok): silme yalnızca yerel.
- **Yazma yolu önbelleğe yazmıyor** (write-through değil) — bilerek: 09'daki read-your-writes
  sorununu şanslı bir yerel isabetin arkasına saklamamak için.
- **Tıklama sayacı hâlâ her istekte DB'ye** (P02-08 duruyor → 05).
- **Liste önbelleklenmiyor**: her yazmada değişir, geçersiz kılması pahalı. Neyin
  önbelleklenmeyeceğine karar vermek, neyin önbellekleneceğine karar vermek kadar önemlidir.
- **Bağlantı havuzu, tek DB, sırlar, süreç içi hız sınırı**: 02'den olduğu gibi devrediyor.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 02 ile farkı gösterir:

1. **`internal/cache/cache.go`** (yeni): LRU + TTL + jitter + singleflight + negatif önbellek, hepsi
   ~200 satır. Dört TRAP bayrağının her biri bu dosyada tek bir `if` — koruma ile korumasızlık
   arasındaki farkın ne kadar küçük göründüğünü görmek öğretici.
2. **`internal/store/cached.go`** (yeni): **dekoratör**, yeni bir store değil. Handler'lar aynı
   arayüzle konuşmaya devam ediyor ve farkı anlayamıyorlar — önbellek kararını **geri alınabilir**
   kılan şey bu.
3. **`IncrementClicks` önbelleğe dokunmuyor**: her tıklamada geçersiz kılmak, önbelleği tam da en
   sıcak anahtarlarda bir ıska üreticisine çevirirdi. Bunun yerine dürüst ifade: *tıklama sayısı
   önbellekte yetkili değildir.*
4. **`deploy/deployment.yaml`**: bellek limiti 256Mi → 384Mi. Önbellek bedava değil; takas manifestte görünür.
5. **`cmd/linkly/main.go`**: `cache.New` + `store.NewCached` — üç satırlık bir kablolama. Mimari
   değişikliğin küçük görünmesi, sonuçlarının küçük olduğu anlamına gelmiyor: P03-01…04 hepsi bu
   üç satırdan doğuyor.
