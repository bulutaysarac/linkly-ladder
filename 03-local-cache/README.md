# 03 — local-cache · "Süreç içi önbellek"

> **Bu seviyede ne yaşayacaksın?**
> - Pod belleğindeki önbelleğin DB okuma yükünü neredeyse sıfıra indirmesi (`04 · Cache` → isabet oranı ~%100)
> - Silinen bir linkin diğer pod'larda TTL boyunca açılmaya devam etmesi (P03-01)
> - Her rollout'ta soğuk önbellek ve DB'de testere dişi (P03-02); aynı verinin N pod'da N kopya olması (P03-03) ve isabet oranının replika sayısıyla düşmesi (P03-04)
> - Tuzaklar: singleflight kapatılınca izdiham (P03-05), negatif önbellek kapatılınca "yok" cevaplarının hep DB'ye inmesi (P03-06), TTL jitter kapatılınca periyodik DB tepesi (P03-07)
>
> **Bu seviye olmasa ne olur?** Her redirect veritabanına gider (P02-01); trafik arttıkça bağlantı havuzu ve DB darboğaz olur.
>
> **Yeni gelen teknolojiler:** LRU + TTL önbellek, singleflight, negatif önbellek, TTL jitter — hepsi Go kodu, yeni altyapı yok ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

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

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl03.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl03.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl03 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P03-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Davranış değişikliği yok — **ama garanti değişti**: `GET /{code}` artık TTL kadar bayat olabilen bir
kopyadan cevaplanabilir. `GET /api/links/{code}` içindeki `clicks` alanı da önbellekten gelirse
bayattır; tıklama sayısı önbellekte **yetkili değildir**.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P03-01 | Silinen link diğer pod'larda yaşıyor | `make repro P=P03-01` | [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl03&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) → "404 (pod'a göre)" | 04 |
| P03-02 | Rollout = soğuk önbellek = DB testere dişi | `make repro P=P03-02` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl03&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) → "Veritabanı sorguları (türe göre)" | 04 |
| P03-03 | Aynı veri N pod'da N kopya | `make repro P=P03-03` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) · [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl03&from=now-15m&to=now&refresh=10s) → "Önbellekteki kayıt (pod'a göre)" | 04 |
| P03-04 | Hit oranı replika sayısıyla düşer | `CONFIRM=1 make repro P=P03-04` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-30m&to=now&refresh=10s) · [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl03&from=now-30m&to=now&refresh=10s) → "Hazır pod adresi (endpoint) sayısı" | 04 |
| P03-05 | **TRAP** singleflight yok → stampede | `make repro P=P03-05` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) · [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl03&from=now-15m&to=now&refresh=10s) → "Bekletilen eşzamanlı ıska / sn" | seviye içi |
| P03-06 | **TRAP** negatif önbellek yok → tarama DB'ye | `make repro P=P03-06` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) · [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl03&from=now-15m&to=now&refresh=10s) → "Önbellek işlemleri (katman ve sonuca göre)" | seviye içi |
| P03-07 | **TRAP** jitter yok → periyodik DB tepesi | `make repro P=P03-07` | görünmez — kanıt terminalde ↓ | seviye içi |

---

### P03-01 · Silinen link diğer pod'larda TTL boyunca yaşıyor

**Belirti:** Kullanıcı linki siler, sunucu `204` döner, veritabanında kayıt yoktur — ve link
dakikalarca çalışmaya devam eder. Hangi isteğin çalışacağı hangi pod'a düştüğüne bağlıdır.
**Neden:** `DELETE` isteği **bir** pod'a düşer; o pod kendi kopyasını temizler
(`cached.go · Invalidate`), diğer N−1 pod hiçbir şey duymaz. [Topic · Konu: Önbellek tutarlılığı, invalidation]

**Reproduce (adım adım):**
1. `make repro P=P03-01` — linki tüm pod'ların önbelleğine sokar, siler, 60 kez okur
2. Elle: `for i in $(seq 30); do curl -s -o /dev/null -w '%{http_code} ' http://lvl03.localtest.me/$code; done`

**Grafana'da gör:** [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl03&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) — script bittikten sonra aç; deney birkaç saniyelik ve az istekli, bu yüzden çizgiler 30–90 sn gecikmeyle küçük tümsekler olarak belirir (giriş: admin / ladder)
- "404 (pod'a göre)" → silmeden sonraki `404`'lerin neredeyse tamamı **tek** bir pod'dan gelir: silme isteğini alıp kendi kopyasını temizleyen pod. Diğer pod'ların çizgisi 0'da kalır — onlar silinmiş linki hâlâ yönlendiriyor.
- "Yönlendirme sonuçları" → silmeden sonra da `ok` serisi sürer, yanında küçük bir `not_found` belirir: aynı kod aynı anda hem "var" hem "yok".
- "İsabet oranı (pod'a göre)" (Cache) → silmeden sonra da bütün pod'larda yüksek kalır. Bayat kopyayı servis etmek önbellek için bir **isabettir**; önbellek yanıldığını bilmez, hit oranı bu sorunu hiç göstermez.

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

**Ölçüm dersi 1 — "tepe" tek başına kanıt değil:** Tüm koşunun tepesini (`max_over_time`) alıp
sondaki orana bölmek yanıltır: o tepe rollout'tan değil, **yükün kendi soğuk başlangıcından** gelir —
k6 `setup()` her koşuda yeni kodlar üretir, ilk okumaları zorunlu olarak DB'ye iner. Böyle bir ölçü
rollout hiç yapılmasa da "REPRODUCED" der; paylaşılan önbellekli 04'te bile — ve `verify-prev`'i
kırar. Bu yüzden script kararlı hâli ve rollout penceresini ayrı ayrı ölçer. *Bir olayın etkisini
ölçeceksen, pencereni o olaya hizala; "en büyük değer" nereden geldiğini söylemez.*

**Ölçüm dersi 2 — komşu olayı SUSTUR:** Hizalı pencerelerle ama varsayılan ayarlarla ölçülen:
kararlı hâl 17.6 DB get/s, rollout penceresi 12.0 get/s — sinyal gürültünün *altında* kalır. Sebep:
60 sn'lik TTL ile 200 anahtar × 3 pod sürekli yeniden dolar (≈10 get/s) ve bu **TTL churn**,
ölçmek istediğimiz soğuk başlangıç darbesiyle aynı büyüklüktedir. Bu yüzden script deney süresince
`CACHE_TTL=10m` yapar ve çalışma kümesini 2000 koda çıkarır: TTL dolması (P03-07) susar, geriye
yalnızca "pod boş doğdu" kalır. *Aynı grafiği iki farklı olay besliyorsa, hangisini ölçtüğünü
bilemezsin.*

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl03&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) — script ~5 dakika sürer; bittiğinde aç ki kararlı hâl ve rollout penceresi aynı ekranda olsun (giriş: admin / ladder)
- "Veritabanı sorguları (türe göre)" → `get` serisinde iki tümsek: ilki yükün kendi soğuk başlangıcı (k6 yeni kodlar üretir — yukarıdaki ölçüm dersi 1), script yükü başlattıktan ~2 dakika sonraki ikincisi `rollout restart`: yere yakın kararlı hâlden dikey bir tepe, yeni pod'lar ısınınca yeniden iniş. Testere dişinin bir dişi budur. `increment_clicks` serisi baştan sona düz kalır — her tıklamanın UPDATE'ini önbellek hiç korumuyor.
- "Önbellekteki kayıt (pod'a göre)" → rollout anında eski pod'ların çizgileri kesilir, yenilerinki **0**'dan başlayıp tırmanır: her yeni pod boş doğar.
- "Önbellek ıskası ve veritabanı sorguları" → `önbellek ıskası` çizgisi rollout anında sıçrar. `veritabanı sorgusu (hepsi)` çizgisi daha az oynar: tüm sorguları toplar ve her tıklamanın `increment_clicks` UPDATE'i ona yüksek, düz bir taban ekler — soğuk başlangıcı yukarıdaki `get` serisinde oku.

**Nerede çözülüyor:** 04 (önbellek pod'un dışında; pod ölse de yaşar).
**Kritik ders:** "Önbellek sayesinde DB'yi küçülttük" tehlikeli bir cümledir. Veritabanı **soğuk
anı** kaldırabilmeli; aksi hâlde ilk dağıtım seni devirir. Kapasiteyi ortalamaya değil, **en kötü
ana** göre planla.

---

### P03-03 · Aynı veri N pod'da N kopya

**Belirti:** Aynı 3000 link üç pod'a da sorulduğunda üç pod da 3000'er kayıt tutar: 3000 farklı link
için önbellekte 9000 kayıt. Bellek kullanımı replika sayısıyla çarpılıyor.
**Neden:** Süreç içi önbellek tanımı gereği pod başına. [Topic · Konu: Bellek maliyeti, ölçek]

**Reproduce (adım adım):**
1. `make repro P=P03-03` — 3000 link oluşturur, **aynı** 3000 kodu her pod'a doğrudan (port-forward,
   ingress'siz) okutur, her pod'un `cache_entries`'ini kendi `/metrics` ucundan okumadan önce ve sonra
   okur; ölçü: pod'lara eklenen kayıtların toplamı ÷ farklı kod sayısı

**Ölçüm dersi — "toplam kayıt ÷ en dolu pod" çoğalmayı kanıtlamaz:** Linkleri ingress üzerinden iki
tur okuyup bu orana bakmak ~3 verir. Ama pod'lar anahtarları **bölüşseydi** (her pod ayrı bir üçte
bir) oran yine 3 çıkardı: bu ölçü, iddia yanlışken de aynı sayıyı verir. Üstelik iki rastgele turdan sonra her pod anahtarların ancak yarısını tutar, hepsini değil. Daha
sinsisi: ingress round robin dağıtır; sıralı okunan kod sayısı pod sayısına tam bölünüyorsa her tur
aynı kodu aynı pod'a götürür ve gerçek bir çoğalma ölçümde hiç görünmez. Paydayı **farklı kod
sayısı** yap ve dağıtımı şansa bırakma: aynı anahtarı her pod'a sen sor.

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl03&from=now-15m&to=now&refresh=10s) — script "her pod'a doğrudan okut" adımına gelince aç (giriş: admin / ladder)
- "Önbellekteki kayıt (pod'a göre)" → pod çizgileri **sırayla** ~3000 yukarı basamak atar (script pod'ları tek tek okutuyor) ve üçü de aynı seviyede durur: her pod aynı 3000 linkin kendi kopyasını tutuyor.
- "Önbellekteki kayıt" → tüm pod'ların toplamı deney boyunca ~9000 artar — farklı link sayısının (3000) replika sayısı katı. Script bunu `her kod ortalama 3.0 kez tutuluyor` diye basar.
- "Heap bellek (Go)" (Pods) → bu deneyde belirgin bir sıçrama bekleme: 3000 kayıt × ~200 byte pod başına yarım megabayt kadar ve GC dalgalanmasının içinde kaybolur. Çarpanı byte'ta değil kayıt sayısında gör; byte hâli aşağıdaki zarf arkası hesabında.

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

**Ölçüm notu — üç kurulum tuzağı, üçü de ders:**
- Çalışma kümesi 200 kod olursa etki ölçülemez. Etkinin büyüklüğü `N × K / toplam istek`: pod sayısı
  N ve çalışma kümesi K küçükse fark gürültüye karışır. Bu yüzden K = 4000.
- `increase(cache_ops_total[3m])` iki ölçümü birbirine karıştırır: ölçekleme + restart + yük, iki
  ölçüm arasında 3 dakikadan kısa sürer ve pencere bir öncekinin verisini de toplar. Bu yüzden
  sayacın kendisi yükten **önce ve sonra** okunup fark alınır.
- **Hit oranı yanlış ölçüdür.** Payı (ısınma maliyeti) ve paydası (toplam istek) aynı anda oynar;
  iki koşuda oluşturulan link sayısı biraz farklı olunca oran da değişir — paylaşılan önbellekli
  04'te bile "oran düştü" der ve `verify-prev`'i kırar. Bu yüzden **ıska sayısı** ölçülür:
  kaç `(pod, anahtar)` çifti ısıtıldı? Pod içi önbellekte bu sayı pod sayısıyla **çarpılır**,
  paylaşılan önbellekte **sabit** kalır. *Doğru ölçü, iddianı doğrudan sayan ölçüdür.*

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-30m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl03&from=now-30m&to=now&refresh=10s) — iki faz birkaç dakika sürer; bitince aç, aralık (son 30 dk) iki fazı da kapsasın (giriş: admin / ladder)
- "Hazır pod adresi (endpoint) sayısı" (Pods) → fazları ayırır: önce **1**, sonra çok replika (varsayılan **6**) hazır adres; script sonunda eski sayıya döner.
- "Önbellek ıskası ve veritabanı sorguları" → her fazın başında bir `önbellek ıskası` tümseği: ısınma maliyeti. Çok pod'lu fazda tümsek belirgin biçimde daha yüksek ve daha uzun — her pod aynı 4000 kodu kendisi için ayrı ayrı çekiyor. Script'in asıl ölçüsü bu ıska sayısı.
- "İsabet oranı (pod'a göre)" → 1 pod'lu fazda tek çizgi hızla yükselir; çok pod'lu fazda her çizgi daha yavaş ve daha aşağıda kalır: pod başına örneklem küçüldü. Oranı yalnızca şekil için oku — yukarıdaki ölçüm notu sayısına neden güvenmediğimizi anlatıyor.

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

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) ve [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl03&from=now-15m&to=now&refresh=10s) — script iki fazı (önce korumalı, sonra korumasız) 60'ar sn koşar; ikisi de bitince aç (giriş: admin / ladder)
- "Bekletilen eşzamanlı ıska / sn" → panelin içindeki küçük eğri korumalı fazda bir tümsek çizer (bekleyen çağrılar: koruma çalışıyor), korumasız fazda **0**'a iner. Büyük rakam yalnızca son değeri gösterir; script bitince 0 okursun.
- "İsabet oranı (pod'a göre)" → iki fazda da yüksek ve neredeyse aynı: izdihamı hit oranından göremezsin.
- "Veritabanı sorguları (türe göre)" (Postgres) → `get` serisi korumasız fazda belirgin biçimde yükselir; `increment_clicks` iki fazda aynı düzeyde. `04 · Cache` → "Önbellek ıskası ve veritabanı sorguları" bu farkı göstermez: `miss` iki fazda aynı sayılır (bekleyen çağrı da önce ıskalar) ve `veritabanı sorgusu (hepsi)` çizgisini her tıklamanın UPDATE'i domine eder.
- "Sorgu süresi p99 (türe göre)" (Postgres) → iki fazda da enjekte edilen ~200 ms gecikme (histogram kovası yüzünden ~250 ms çizilir): önbelleği doldurmanın maliyeti.

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

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now&refresh=10s) ve [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl03&from=now-15m&to=now&refresh=10s) — script iki fazı (önce açık, sonra kapalı) 60'ar sn koşar; ikisi de bitince aç (giriş: admin / ladder)
- "Önbellek işlemleri (katman ve sonuca göre)" → açık fazda taramanın çoğu `l1 negative_hit` olarak önbellekten döner; kapalı fazda `l1 negative_hit` **0**'a iner, yerini `l1 miss` alır.
- "İsabet oranı (pod'a göre)" → açık fazda yüksek (negatif isabet de isabettir), kapalı fazda sıfıra yakın: tarama önbelleği tamamen atlıyor.
- "Veritabanı sorguları (türe göre)" (Postgres) → `get` serisi kapalı fazda belirgin biçimde yükselir: her "yok" cevabı yeniden DB'ye soruluyor.

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
uygulamayı 10 saniyede bir kazıyor (ServiceMonitor `interval: 10s`; küme metrikleri 30 sn) ve
`rate(...[30s])` onu 30 saniyeye yayıp düzlüyor; düzlenen şey tam da
ölçmek istediğin tepe. Bu yüzden script pod'un `/metrics` ucunu **saniyede bir** kendisi örnekliyor.
Kural: **ölçüm çözünürlüğün, ölçtüğün olaydan ince olmalı** (pencere kuralının kardeşi: ölçüm
penceresi de olaydan kısa olmamalı). Aynı sorun 11'de yüksek çözünürlük/exemplar başlığıyla dönecek.
Sayaç olarak `cache_ops_total{result="expired"}` seçildi: ilk ısınmanın ıskalarını saymaz, yalnızca
TTL dolmalarını sayar.

**Grafana'da gör:** Grafana'da görünmez — darbe 1-2 saniye sürer; Prometheus uygulamayı seyrek kazır ve paneller 1 dakikalık `rate` çizer, yani tepe tam da düzlenen şeydir (yukarıdaki ölçüm notu). Script'in saydığı sayaç `04 · Cache` → "Önbellek işlemleri (katman ve sonuca göre)" panelinde `l1 expired` olarak vardır, ama iki fazda da benzer, düz bir çizgi olur: aynı sayıda anahtar doluyor, fark yalnızca bunun zamana yayılıp yayılmadığında. Kanıt terminalde:
- `make repro P=P03-07` → `jitter'lı: tepe=… ortalama=… → tepe/ortalama=…` ve `jitter'sız: …` satırları; jitter'sız tepe/ortalama oranı belirgin biçimde büyük
- `paste /tmp/p0307-jitter.txt /tmp/p0307-nojitter.txt | head -90` → her satır bir saniyede dolan anahtar sayısı (tek pod): soldaki sütun küçük, dağınık sayılar; sağdaki çoğunlukla 0 ve ~30 satırda bir büyük bir sayı — testere dişi

**Okuma notu:** Bakılacak sayı ortalama değil, **tepe/ortalama oranıdır** — kapasite tepeye göre
planlanır. İki durumda da aynı sayıda anahtar dolar; fark yalnızca bunun zamana yayılıp
yayılmadığıdır. Jitter, ilişkisiz olayların ilişkili hâle gelmesini engelleyen genel bir tekniktir;
aynı fikir retry'da (10) ve zamanlanmış işlerde de karşına çıkacak.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

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
| [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl03&from=now-15m&to=now) | **Dolu** ✨ | `cache_ops_total{layer="l1"}`, stampede, eviction, entries · arama süresi `cache_lookup_duration_seconds{layer="l1"}` panelde yok, Explore'da (P04-02 bunu 04'ün `l2`'siyle kıyaslar) |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl03&from=now-15m&to=now) | Dolu | Artık çok daha az sorgu görüyor — fark P02 ile kıyaslanarak okunur |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl03&from=now-15m&to=now) · [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl03&from=now-15m&to=now) · [`01 · Pods`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl03&from=now-15m&to=now) · [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl03&from=now-15m&to=now) | Dolu | — |
| [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl03&from=now-15m&to=now) | Boş | L2 yok (04) |
| [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl03&from=now-15m&to=now) · [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl03&from=now-15m&to=now) · [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl03&from=now-15m&to=now) | Boş | — |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl03&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl03&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl03&from=now-15m&to=now) | Boş | — |

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
