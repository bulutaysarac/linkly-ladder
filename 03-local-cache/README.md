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
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl03.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl03.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl03 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P03-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Önceki seviye açıksa kapat (aynı anda tek seviye çalışır), bu seviyeyi kur. `make up` Grafana'yı da temizler:
```bash
make -C ../02-postgres down
make up
```
2. 02'nin sorunlarını bu seviyede koş. Koşarken başka komut çalıştırma: aynı pod'lara dokunurlar.
   Çıktıdaki `BEKLENEN` sütunu `NOT-REPRODUCED` diyen tek satır P02-01: 03'ün çözdüğü sorun. Onay isteyen scriptler
   (P02-02, P02-03, P02-04, P02-10) onaysız `SKIPPED` der; onları da koşmak istersen `CONFIRM=1 make verify-prev`:
```bash
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P03-01 → P03-07). Her sorunda aynı düzen:
   **Elle** bloklarını sırayla yapıştır (ilk komut `make fresh`: Grafana bu deneye boş başlar) →
   **Terminalde ne görmelisin** ile karşılaştır → **Grafana'da gör** linklerini aç, her madde hangi panelde neyi
   göreceğini söyler. İstersen aynı deneyi `make repro P=…` ile otomatik koş: ölçer ve hükmünü basar.
4. Bitince açık kalan ayarları geri al ve seviyeyi kapat:
```bash
make reset
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

Otomatik — ölçer ve hüküm basar: `make repro P=P03-01` (linki tüm pod'ların önbelleğine sokar, siler, 60 kez okur ve kaçının hâlâ yönlendirdiğini sayar).

Elle — `03-local-cache` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle; bir link oluştur ve 36 kez okuyarak üç pod'un da önbelleğine sok (ingress istekleri pod'lara
   sırayla dağıtır):
```bash
make fresh
code=$(curl -s -XPOST http://lvl03.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0301"}' | jq -r .code); echo "kod: $code"
for i in $(seq 1 36); do curl -s -o /dev/null http://lvl03.localtest.me/$code; done
```
2. Linki sil (istek tek bir pod'a düşer) ve veritabanında kalmadığını gör:
```bash
curl -s -o /dev/null -w 'DELETE → %{http_code}\n' -XDELETE http://lvl03.localtest.me/api/links/$code
kubectl -n lvl03 exec postgres-0 -c postgres -- psql -U linkly -d linkly -tAc "SELECT count(*) FROM links WHERE code = '$code'"
```
3. Silinmiş kodu 30 kez iste:
```bash
for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code} ' http://lvl03.localtest.me/$code; done; echo
```
4. İstersen bayatlık penceresinin sonunu gör: TTL'in (60 sn, ±%20 jitter) dolmasını bekle, tekrar iste:
```bash
sleep 75
for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code} ' http://lvl03.localtest.me/$code; done; echo
```

**Terminalde ne görmelisin:** `DELETE → 204` ve veritabanında `0` satır. Buna rağmen 30 cevabın yaklaşık üçte ikisi
`302`, üçte biri `404`: `404`'ler silme isteğini alıp kendi kopyasını temizleyen tek pod'dan, `302`'ler hiçbir şey
duymamış diğer iki pod'dan geliyor. 4. adımda 30 cevabın hepsi `404`: kopyalar TTL dolunca kendiliğinden düştü — o
ana kadar kullanıcı "sildim" dediği linke yönlenmeye devam etti.

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

Otomatik: `make repro P=P03-02` (TTL'i deney süresince 10 dk yapar, 2000 kodluk sürekli yük altında **önce kararlı hâli**, sonra `rollout restart` penceresini ayrı ayrı ölçer ve ikisini kıyaslar; ~5 dk).

Elle — sırayla yapıştır:

1. Grafana'yı temizle; TTL dolmasını sustur (Ölçüm dersi 2), pod'lar yeni ayarla yeniden başlar:
```bash
make fresh
make set E="CACHE_TTL=10m"
```
2. İKİNCİ bir terminalde `03-local-cache` klasöründe 2000 kodluk çalışma kümesiyle 4 dk sürecek yükü başlat:
```bash
SEED=2000 SEED_BUDGET_MS=240000 make load S=redirect K6_ARGS="--vus 20 --duration 240s"
```
3. Yük başlar başlamaz İLK terminalde 2 dk bekle (75 sn ısınma + 45 sn ölçüm penceresi) ve kararlı hâlde saniyedeki DB
   okumasını ölç:
```bash
sleep 120
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(db_queries_total{namespace="lvl03",op="get"}[45s])) / 45' | jq -r '.data.result[0].value[1]'
```
4. Hemen ardından dağıtım yap; yeni pod'lar ısınınca, dağıtımın başından beri geçen pencerede saniyedeki DB okumasını
   ölç:
```bash
t0=$(date +%s)
kubectl -n lvl03 rollout restart deploy/linkly
kubectl -n lvl03 rollout status deploy/linkly
sleep 30
rw=$(( $(date +%s) - t0 )); echo "rollout penceresi: $rw sn"
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=sum(increase(db_queries_total{namespace=\"lvl03\",op=\"get\"}[${rw}s])) / $rw" | jq -r '.data.result[0].value[1]'
```
5. İkinci terminaldeki yük bitince TTL'i geri al:
```bash
make reset
```

**Terminalde ne görmelisin:** 3. adımdaki sayı yere yakın: önbellek sıcak, TTL uzun, okumaların neredeyse hiçbiri DB'ye
inmiyor. 4. adımdaki sayı bunun birkaç katı (script en az 3 katını ve saniyede 5'ten fazlasını arar): her yeni pod boş
bellekle doğdu ve 2000 kodun hepsini kendisi için yeniden DB'den çekti. Testere dişinin bir dişi bu.

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

Otomatik: `make repro P=P03-03` (3000 link oluşturur, **aynı** 3000 kodu her pod'a doğrudan — port-forward, ingress'siz — okutur, her pod'un `cache_entries`'ini kendi `/metrics` ucundan okumadan önce ve sonra okur; ölçü: pod'lara eklenen kayıtların toplamı ÷ farklı kod sayısı).

Elle — sırayla yapıştır:

1. Grafana'yı temizle; 3000 farklı link oluştur, kodları bir dosyada topla (1–2 dk) ve farklı kod sayısını say:
```bash
make fresh
for i in $(seq 1 3000); do curl -s -XPOST http://lvl03.localtest.me/api/links -H 'Content-Type: application/json' -d "{\"url\":\"https://example.com/mem/$i\"}" | jq -r .code; done > /tmp/p0303-codes.txt
sort -u /tmp/p0303-codes.txt | wc -l
```
2. Aynı 3000 kodu **her pod'a doğrudan** okut (dağıtımı şansa bırakma — Ölçüm dersi) ve her pod'un kendi önbellek kayıt
   sayısını okumadan önce ve sonra oku:
```bash
for pod in $(kubectl -n lvl03 get pods -l app.kubernetes.io/name=linkly -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name'); do
  kubectl -n lvl03 port-forward "pod/$pod" 18093:8080 >/dev/null 2>&1 &
  pf=$!
  sleep 3
  before=$(curl -s http://127.0.0.1:18093/metrics | awk '$1 == "cache_entries" {print $2}')
  xargs -P 10 -I{} curl -s -o /dev/null --max-time 5 http://127.0.0.1:18093/{} < /tmp/p0303-codes.txt
  after=$(curl -s http://127.0.0.1:18093/metrics | awk '$1 == "cache_entries" {print $2}')
  echo "${pod}: önbellek kaydı $before → $after"
  kill $pf
  sleep 1
done
```

**Terminalde ne görmelisin:** `3000`. Ardından üç satır, her pod için bir tane: her birinde kayıt sayısı ~3000 artar
(`… → …`). Pod'lara eklenen toplam ~9000, farklı kod 3000: her kod ortalama 3 kez tutuluyor — script bunu
`her kod ortalama 3.0 kez tutuluyor` diye basar. Aynı veri için üç kez bellek ödüyorsun.

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

Otomatik: `CONFIRM=1 make repro P=P03-04` (1 replika ve 6 replika ile aynı yükü koşup ıska sayısını ve hit oranını kıyaslar — 4000 kodluk çalışma kümesi, 20 VU × 60 sn; replika sayısını deney sonunda geri alır).

Elle — sırayla yapıştır:

1. Grafana'yı temizle; tek pod'a in, pod'u boş önbellekle yeniden başlat, Prometheus'un eski pod'u unutmasını bekle ve
   ıska sayacını oku:
```bash
make fresh
kubectl -n lvl03 scale deploy/linkly --replicas=1
kubectl -n lvl03 rollout status deploy/linkly
kubectl -n lvl03 rollout restart deploy/linkly
kubectl -n lvl03 rollout status deploy/linkly
sleep 40
m0=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(cache_ops_total{namespace="lvl03",result="miss"})' | jq -r '.data.result[0].value[1] // "0"'); echo "ıska sayacı: $m0"
```
2. 4000 kodluk çalışma kümesiyle 20 kullanıcı × 60 sn yük ver, sonra yükün yarattığı ıskayı hesapla:
```bash
SEED=4000 SEED_BUDGET_MS=240000 make load S=redirect K6_ARGS="--vus 20 --duration 60s"
sleep 20
m1=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(cache_ops_total{namespace="lvl03",result="miss"})' | jq -r '.data.result[0].value[1] // "0"')
echo "1 pod → ıska: $(awk -v a="$m0" -v b="$m1" 'BEGIN{print b - a}')"
```
3. Aynısını 6 pod'la yap:
```bash
kubectl -n lvl03 scale deploy/linkly --replicas=6
kubectl -n lvl03 rollout status deploy/linkly
kubectl -n lvl03 rollout restart deploy/linkly
kubectl -n lvl03 rollout status deploy/linkly
sleep 40
m0=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(cache_ops_total{namespace="lvl03",result="miss"})' | jq -r '.data.result[0].value[1] // "0"'); echo "ıska sayacı: $m0"
SEED=4000 SEED_BUDGET_MS=240000 make load S=redirect K6_ARGS="--vus 20 --duration 60s"
sleep 20
m1=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(cache_ops_total{namespace="lvl03",result="miss"})' | jq -r '.data.result[0].value[1] // "0"')
echo "6 pod → ıska: $(awk -v a="$m0" -v b="$m1" 'BEGIN{print b - a}')"
```
4. Geri al:
```bash
kubectl -n lvl03 scale deploy/linkly --replicas=3
kubectl -n lvl03 rollout status deploy/linkly
```

**Terminalde ne görmelisin:** 1 pod'da ıska kabaca çalışma kümesi kadar (en çok 4000: her kod bir kez ısınır). 6 pod'da
aynı yük ve aynı çalışma kümesiyle ıska bunun belirgin biçimde katı — script en az 1.8 katını arar, üst sınır pod
sayısıdır (6): her pod aynı 4000 kodu kendisi için ayrı ayrı çekiyor. Paylaşılan bir önbellekte (04) bu iki sayı
yaklaşık aynı çıkar.

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

Otomatik: `make repro P=P03-05` (Postgres'e Chaos Mesh ile 200 ms gecikme enjekte eder, TTL'i 5 sn'ye çeker, `hot-key` yükü verir, önce korumalı sonra korumasız ölçer, sonunda hepsini geri alır). Chaos Mesh kurulu değilse bir kez: `cd platform && make chaos`.

Elle — sırayla yapıştır:

1. Grafana'yı temizle; önbelleği doldurmayı pahalı yap (Postgres'e 200 ms — aşağıdaki "Neden gecikme"), TTL'i 5 sn'ye çek
   (pod'lar yeniden başlar), eski pod'un sayacı toplamdan düşene kadar bekle, DB `get` sayacını oku:
```bash
make fresh
make chaos C=pg-delay-200ms
make set E="CACHE_TTL=5s"
sleep 40
g0=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(db_queries_total{namespace="lvl03",op="get"})' | jq -r '.data.result[0].value[1] // "0"'); echo "get sayacı: $g0"
```
2. Koruma açıkken (varsayılan) 60 kullanıcıyla 60 sn sıcak anahtar yükü; sonra yük boyunca DB'ye inen `get` sayısı ve
   singleflight'ta bekletilen çağrı sayısı:
```bash
SEED=20 HOT_SHARE=0.99 make load S=hot-key K6_ARGS="--vus 60 --duration 60s"
sleep 20
g1=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(db_queries_total{namespace="lvl03",op="get"})' | jq -r '.data.result[0].value[1] // "0"')
echo "korumalı: yük boyunca DB get = $(awk -v a="$g0" -v b="$g1" 'BEGIN{print b - a}')"
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(cache_stampede_wait_total{namespace="lvl03"}[5m]))' | jq -r '.data.result[0].value[1]'
```
3. Korumayı kapat (pod'lar yeniden başlar), aynı yükü tekrarla:
```bash
make set E="TRAP_NO_SINGLEFLIGHT=true"
sleep 40
g0=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(db_queries_total{namespace="lvl03",op="get"})' | jq -r '.data.result[0].value[1] // "0"'); echo "get sayacı: $g0"
SEED=20 HOT_SHARE=0.99 make load S=hot-key K6_ARGS="--vus 60 --duration 60s"
sleep 20
g1=$(curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(db_queries_total{namespace="lvl03",op="get"})' | jq -r '.data.result[0].value[1] // "0"')
echo "korumasız: yük boyunca DB get = $(awk -v a="$g0" -v b="$g1" 'BEGIN{print b - a}')"
```
4. Geri al: gecikmeyi kaldır, TTL'i ve tuzağı manifestteki hâline döndür:
```bash
make unchaos C=pg-delay-200ms
make reset
```

**Terminalde ne görmelisin:** `make chaos` `networkchaos.chaos-mesh.org/pg-delay-200ms created` der. Korumalı turda yük
boyunca DB `get` sayısı küçük ve bekletilen çağrı sayısı sıfırdan büyük: TTL dolduğu anda gelen istekler tek bir DB
sorgusunu bekledi. Korumasız turda `get` sayısı belirgin biçimde büyük — script en az iki katını ve 100 fazlasını
arar: 200 ms'lik delik boyunca gelen her istek DB'ye indi. Hit oranı iki turda da yüksek görünür; farkı yalnızca DB'ye
inen sorgu sayısı gösterir.

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

Otomatik: `make repro P=P03-06` (`scan` senaryosuyla 60 kodluk sınırlı bir "yok" havuzuna yük verir, negatif önbellek açık/kapalı kıyaslar; negatif isabet hiç olmazsa ölçmeden çıkar).

Elle — sırayla yapıştır:

1. Grafana'yı temizle; negatif önbellek açıkken (varsayılan) 60 var olmayan koddan oluşan bir havuza 30 kullanıcıyla
   60 sn tarama yap (havuz sınırlı olmalı: aynı "yok" cevabı tekrarlanmazsa önbelleklenecek bir şey olmaz), sonra DB'ye
   saniyede inen `get` sayısını ve negatif isabetleri sor:
```bash
make fresh
KEYS=60 CODE_LEN=7 make load S=scan K6_ARGS="--vus 30 --duration 60s"
sleep 18
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(db_queries_total{namespace="lvl03",op="get"}[1m]))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(cache_ops_total{namespace="lvl03",result="negative_hit"}[5m]))' | jq -r '.data.result[0].value[1]'
```
2. Negatif önbelleği kapat (pod'lar yeniden başlar), eski pod'lar gidince aynı taramayı yap:
```bash
make set E="TRAP_NO_NEGATIVE_CACHE=true"
sleep 10
KEYS=60 CODE_LEN=7 make load S=scan K6_ARGS="--vus 30 --duration 60s"
sleep 18
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(db_queries_total{namespace="lvl03",op="get"}[1m]))' | jq -r '.data.result[0].value[1]'
```
3. Geri al:
```bash
make reset
```

**Terminalde ne görmelisin:** iki taramanın k6 özet satırında da istekler `404` (hepsi var olmayan kod). Açık turda
negatif isabet sayısı büyük ve DB `get`/sn düşük: aynı "yok" cevabı 10 sn boyunca önbellekten dönüyor. Kapalı turda
DB `get`/sn belirgin biçimde yüksek — script en az 1,5 katını arar: her "yok" cevabı yeniden DB'ye soruluyor.

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

Otomatik: `make repro P=P03-07` (TTL'i 30 sn'ye çeker, 300 kodluk kümeyi tek seferde ısıtır, jitter açık/kapalı 150'şer saniye yük verip **tepe/ortalama** oranını kıyaslar; ~8 dk). Saniyelik seriler `/tmp/p0307-jitter.txt` ve `/tmp/p0307-nojitter.txt` dosyalarında kalır — yan yana koyunca biri düz, diğeri testere dişi.

Elle — sırayla yapıştır (Prometheus bu darbeyi göremez; pod'un kendi `/metrics` ucu saniyede bir okunur — Ölçüm notu):

1. Grafana'yı temizle, TTL'i 30 sn'ye çek (jitter açık, varsayılan ±%20; pod'lar yeniden başlar), eski pod'lar gidince
   hazır bir pod seç:
```bash
make fresh
make set E="CACHE_TTL=30s"
sleep 10
pod=$(kubectl -n lvl03 get pod -l app.kubernetes.io/name=linkly -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "pod: $pod"
```
2. İKİNCİ bir terminalde `03-local-cache` klasöründe 300 kodluk kümeyle 150 sn okuma yükünü başlat:
```bash
SEED=300 make load S=redirect K6_ARGS="--vus 20 --duration 150s"
```
3. Hemen ardından İLK terminalde 150 sn boyunca saniyede bir, o pod'da TTL'i dolan anahtar sayısını dosyaya yaz; sonra
   tepe/ortalama oranını hesapla:
```bash
prev=""; for i in $(seq 1 150); do cur=$(kubectl -n lvl03 get --raw "/api/v1/namespaces/lvl03/pods/${pod}:8080/proxy/metrics" | awk -v pat='^cache_ops_total\{.*result="expired"' '$0 ~ pat {s += $2} END {print s + 0}'); [ -n "$prev" ] && awk -v a="$prev" -v b="$cur" 'BEGIN{print b - a}'; prev=$cur; sleep 1; done > /tmp/p0307-jitter.txt
awk '{n++; s+=$1; if ($1>p) p=$1} END{if (s==0) {print "veri yok"; exit} printf "jitterli: tepe=%d ortalama=%.1f tepe/ortalama=%.1f\n", p, s/n, p/(s/n)}' /tmp/p0307-jitter.txt
```
4. Jitter'ı kapat (pod'lar yeniden başlar), yeni bir pod seç:
```bash
make set E="TRAP_NO_TTL_JITTER=true"
sleep 10
pod=$(kubectl -n lvl03 get pod -l app.kubernetes.io/name=linkly -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0]'); echo "pod: $pod"
```
5. İKİNCİ terminalde aynı yükü yeniden başlat:
```bash
SEED=300 make load S=redirect K6_ARGS="--vus 20 --duration 150s"
```
6. Hemen ardından İLK terminalde aynı örneklemeyi yap, sonra iki seriyi yan yana koy:
```bash
prev=""; for i in $(seq 1 150); do cur=$(kubectl -n lvl03 get --raw "/api/v1/namespaces/lvl03/pods/${pod}:8080/proxy/metrics" | awk -v pat='^cache_ops_total\{.*result="expired"' '$0 ~ pat {s += $2} END {print s + 0}'); [ -n "$prev" ] && awk -v a="$prev" -v b="$cur" 'BEGIN{print b - a}'; prev=$cur; sleep 1; done > /tmp/p0307-nojitter.txt
awk '{n++; s+=$1; if ($1>p) p=$1} END{if (s==0) {print "veri yok"; exit} printf "jittersiz: tepe=%d ortalama=%.1f tepe/ortalama=%.1f\n", p, s/n, p/(s/n)}' /tmp/p0307-nojitter.txt
paste /tmp/p0307-jitter.txt /tmp/p0307-nojitter.txt | head -90
```
7. Geri al:
```bash
make reset
```

**Terminalde ne görmelisin:** iki `tepe/ortalama` satırı; jitter'sız olanın oranı belirgin biçimde büyük — script en
az 1,8 katını ve 3'ten büyüğünü arar. `paste` çıktısında her satır bir saniyede o pod'da dolan anahtar sayısı: soldaki
sütun (jitter'lı) küçük, dağınık sayılar; sağdaki (jitter'sız) çoğunlukla `0` ve ~30 satırda bir büyük bir sayı —
testere dişi. İki sütunun toplamı yakın: aynı sayıda anahtar doluyor, fark yalnızca bunun zamana yayılıp
yayılmadığında.

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
