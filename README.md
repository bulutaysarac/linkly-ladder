# linkly-ladder

> Bir URL kısaltıcının **en ilkel halinden en modern haline 15 basamak**. Her basamak kendi klasöründe ayağa
> kalkar ve kendi sorunlarını üretir; bir sonraki basamak onları çözer ve yenilerini getirir. Hepsi aynı kind
> kümesinde koşar, aynı Grafana panellerinden izlenir, aynı komutlarla yönetilir.

System Design Primer'ın "Design Bit.ly" problemi. Buradaki her bileşen (Redis, Kafka, circuit breaker,
canary…) bir önceki seviyede **gözünle gördüğün** bir soruna cevap olarak gelir. Ayrıntılı plan: [PLAN.md](PLAN.md).

**Her seviyede aynı döngü:** kur (`make up`) → önceki seviyenin sorunları burada çözülmüş mü ölç
(`make verify-prev`) → bu seviyenin sorunlarını sırayla yaşa (README §6: yapıştırılacak adımlar,
"Terminalde ne görmelisin", "Grafana'da gör") → kapat (`make down`) → sonraki seviye. Verileri temizleyip
baştan koşmak istersen: [adım 7](#7-verileri-temizleyip-baştan-koşmak).

İlk kez mi? Aşağıdaki **[Sıfırdan başlangıç](#sıfırdan-başlangıç)** adımlarını sırayla uygula. Bilmediğin bir
araç ya da terim çıkarsa: [Kullanılan teknolojiler](#kullanılan-teknolojiler) · [Sık geçen kavramlar](#sık-geçen-kavramlar).

## Sıfırdan başlangıç

Her adım: **nerede** (`cd`) → **ne çalıştır** → **ne görmelisin**. Komut blokları olduğu gibi yapıştırılır.
Takılırsan en alttaki [Takılırsan](#takılırsan) tablosuna bak.

### 0. Gerekenler

| Gereken | Not |
|---|---|
| **Docker Desktop**, Settings → Resources: **en az 6 CPU / 10 GB** (mümkünse 8 CPU / 12 GB) | Bütün küme Docker'ın içinde koşar; 13–14'te her şey açık olduğu için 6 CPU sınırda kalır |
| `brew install kind kubectl helm k6 jq` | kind: küme · kubectl/helm: kurulum · k6: yük üretici · jq: JSON |
| `git`, `python3`, `make` | macOS'ta hazır (`xcode-select --install`) |
| Go 1.26+ (isteğe bağlı) | Yalnızca `make test`/`make lint` için; imajlar Docker içinde derlenir |
| Boş portlar: **80, 443, 5001** | 80/443 ingress'e, 5001 yerel imaj deposuna gider |
| zsh'da bir kez: `echo 'setopt interactivecomments' >> ~/.zshrc`, yeni terminal | Yalnızca seviye README'lerindeki hızlı başvuru satırları `# açıklama` taşır; bu ayar olmadan zsh `#`'i komutun parçası yapar |

macOS'ta denendi. Kurumsal ağ (Zscaler gibi TLS araya girmesi) için ek bir şey gerekmez; kök sertifika
düğümlere otomatik kurulur.

### 1. Platformu kur (bir kez, ~20–25 dk)

Repoyu klonla, `LADDER`'ı (repo kökünün yolu) tanımla ve platformu kur:

```bash
git clone https://github.com/bulutaysarac/linkly-ladder.git
cd linkly-ladder
echo "export LADDER=\"$(pwd)\"" >> ~/.zshrc
export LADDER="$(pwd)"
cd "$LADDER/platform"
make full
```

- **`LADDER` neden?** Sonraki her blok `cd "$LADDER/…"` ile başlar; hangi terminalde, hangi klasörde
  yapıştırırsan yapıştır doğru yerde çalışır. `~/.zshrc`'deki satır yeni terminallere de geçer (bash'te
  `~/.bashrc`). Repo zaten klonluysa yalnızca `echo …` ve `export …` satırlarını repo kökünde çalıştır.
  Kontrol: `echo "$LADDER"` repo kökünü basar.
- **`make full` ne kurar?** kind kümesi (`linkly`: 1 control-plane + 3 worker), yerel imaj deposu, ingress,
  Prometheus/Grafana/Loki/Tempo, Chaos Mesh, KEDA, CloudNativePG, Argo, Kyverno. Hepsi bir kez kurulur; her
  seviye yalnızca kendi ihtiyacını açık tutar. Dar makinede `make minimal` (00–01) ya da `make standard` (02–10).
- **Ne görmelisin:** son satırda `✔ cert-manager + sealed-secrets + kyverno`; `make status` dört düğümü
  `Ready` gösterir; Docker Desktop'ta konteynerler `linkly` grubu altında.

| Adres | Ne | Giriş |
|---|---|---|
| http://grafana.localtest.me | Paneller (`Ladder` klasörü) | admin / ladder |
| http://prometheus.localtest.me | Ham metrikler, PromQL | — |
| http://argocd.localtest.me | GitOps (12+) | admin / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| http://lvlNN.localtest.me | NN. seviyenin kendisi (örn. `lvl00`) | 13+: API anahtarı |

### 2. İlk seviyeyi kur: 00-naive (~2 dk; ilk derlemede daha uzun)

```bash
cd "$LADDER/00-naive"
make up
```

`make up` sırasıyla: seviyenin platform profilini uygular → Grafana'yı temizler → servisi derler → depoya
iter → Kubernetes'e kurar → hazır olmasını bekler → bir link oluşturup açarak dener.
**Ne görmelisin:** `smoke ✔ POST /api/links → <kod>, GET /<kod> → 301` ve `✔ lvl00 ayakta`.

### 3. Uygulamayı elle dene

Bir kısa link oluştur, yönlendirmesine bak, Grafana'yı aç:

```bash
cd "$LADDER/00-naive"
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl00.localtest.me/$code
make grafana
```

**Ne görmelisin:** 4 karakterlik kısa kod, sonra `301 → https://example.com`. Tarayıcıda Grafana açılır
(admin / ladder) → **Dashboards → Ladder** → üstte `level` = `lvl00`. `01 · Pods & Resources` panosunda tek bir
pod ve 0 restart. 301'in kendisi de 00'ın sorunlarından biri (P00-10); 01'den itibaren 302 döner.

### 4. İlk sorunu yaşa (P00-01: eşzamanlı yazma süreci öldürür)

Her seviye README'sinin §6'sı sorunları bu düzende verir. İkinci bir terminal aç, pod'u izle ve açık bırak:

```bash
cd "$LADDER/00-naive"
kubectl -n lvl00 get pods -w
```

İlk terminalde 50 eşzamanlı kullanıcıyla 30 sn link oluştur:

```bash
cd "$LADDER/00-naive"
make load S=create K6_ARGS="--vus 50 --duration 30s"
```

**Ne görmelisin:** birkaç saniye içinde ikinci terminalde `RESTARTS` artar: süreç çöküyor. Sebebi pod'un
önceki logunda `fatal error: concurrent map writes`. Grafana:
[`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl00&from=now-15m&to=now) →
"Yeniden başlatma sayısı" basamak basamak artar (her basamak bir çöküş).

Aynı deneyi script de koşabilir; ölçer ve hükmünü basar — `REPRODUCED` (sorun var), `NOT-REPRODUCED` (yok),
`SKIPPED` (ölçülemedi):

```bash
cd "$LADDER/00-naive"
make repro P=P00-01
```

Yıkıcı adımı olan scriptler (pod silme, düğüm dondurma) onay ister: `CONFIRM=1 make repro P=…`. Bir seviyenin
bütün sorunlarını koşmak 20–60 dk sürer; önce birkaçını elle yaşa.

**Seviye README'si nasıl okunur:** en üstte ne yaşayacağın · §3 önceki seviyeden neyin çözüldüğü · **§4 Rehber**
(o seviyenin baştan sona komut sırası) · **§6 sorunlar** (asıl ders) · §7 alıştırmalar · §8 hangi panel dolu ·
§10 `make diff-prev` ile kod farkı.

### 5. Alıştırma: bir çözümü bilerek boz

Her README'nin §7'si bir çözümü kapatan `TRAP_*` bayraklarını ve denemeye değer ayarları listeler; alıştırma
o seviye ayaktayken yapılır. Örnek — 03'e geldiğinde (`03-local-cache` ayaktayken) önce normal hâli gör:

```bash
cd "$LADDER/03-local-cache"
make load S=mixed K6_ARGS="--duration 30s"
```

Grafana → `04 · Cache` → isabet oranı ~%100. Şimdi önbelleği küçült, aynı yükü tekrar ver, ayarı gör:

```bash
cd "$LADDER/03-local-cache"
make set E="CACHE_CAPACITY=100"
make load S=mixed K6_ARGS="--duration 30s"
make env
```

İsabet ~%20'ye çöker, veritabanına yığılan istekler 5xx üretir; `make env` → `CACHE_CAPACITY=100`. Her şeyi
`deploy/`'daki hâline döndür:

```bash
cd "$LADDER/03-local-cache"
make reset
```

### 6. Sonraki seviyeye geç

Açık seviyeyi kapat ve 00 → 01 kod farkını oku — çözümün kendisi (`q` ile çıkılır):

```bash
cd "$LADDER/00-naive"
make down
cd "$LADDER/01-hardened"
make diff-prev | less
```

01'i kur ve 00'ın sorunlarını burada tekrar koş:

```bash
cd "$LADDER/01-hardened"
make up
make verify-prev
```

**Ne görmelisin:** `BEKLENEN` sütunu `NOT-REPRODUCED` olan satırlar 01'in çözdüğünü iddia ettikleri; sonuç
uymazsa satır `✘` alır. `(açık kalabilir)` yazanlar sonraki seviyelere bırakılmış sorunlar.
**Aynı anda tek seviye çalıştır**: makine buna göre ayarlı.

### 7. Verileri temizleyip baştan koşmak

Önceki deneylerin verisi (linkler, veritabanı, önbellek, kuyruk) ya da Grafana'daki eski çizgiler yeni koşuya
karışmasın istiyorsan. Neyi temizlemek istediğine göre:

| Ne temizlenir | Ne kalır | Komut |
|---|---|---|
| Grafana'daki geçmiş çizgiler (metrikler) | Veri ve kurulum | Seviye klasöründe `make fresh` — her deneyin ilk komutu zaten bu |
| Tek seviyenin verisi (namespace silinir, yeniden kurulur) | Diğer seviyeler, metrikler | Seviye klasöründe `make down`, sonra `make up` |
| Bütün seviyelerin verisi + metrik, trace, log | Küme, kurulu bileşenler, panolar, imajlar | Kök klasörde `make wipe CONFIRM=1` (~2-3 dk) |

**Verileri temizleyip sıfırdan koşmak istersen bunu kullan** (örnek 00; başka seviye için son iki satırda
klasörü değiştir). Önce neyin silineceğini görmek istersen `CONFIRM=1` olmadan: `cd "$LADDER" && make wipe`.

```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/00-naive"
make up
```

**Ne görmelisin:** `make wipe` silinenleri tek tek yazar (`→ lvl00 siliniyor` …) ve `✔ veriler silindi — Grafana boş`
ile biter; `make up` imaj derlemeden ~1 dk'da `✔ lvl00 ayakta`
der. Grafana panelleri boş başlar ve yalnızca bu koşuyu gösterir.

### 8. Günün sonunda

Açık seviyeyi kendi klasöründe kapat (örnek 01):

```bash
cd "$LADDER/01-hardened"
make down
```

Kümeyi durdur — hiçbir şey silinmez, Docker'ın CPU/belleği boşalır:

```bash
cd "$LADDER/platform"
make stop
```

Ertesi gün kümeyi başlat (düğümler `Ready` olunca döner), sonra çalıştığın seviyede `make up`:

```bash
cd "$LADDER/platform"
make start
```

Docker Desktop'taki **sil** düğmesi kümenin tamamını siler; durdurmak için `make stop` kullan.

**Her şeyi kaldır** (küme ve imaj deposu dahil; sonra yeniden `make full` gerekir):

```bash
cd "$LADDER/platform"
make destroy
```

### Takılırsan

| Belirti | Sebep | Ne yap |
|---|---|---|
| `make up`: `✘ seviye NN şu platform bileşenlerini istiyor ama kurulu değil` | O seviyenin operatörü kurulmamış | Mesajdaki komut, ya da `cd "$LADDER/platform" && make full` |
| `failed calling webhook … connection refused` | Bir operatör (CNPG, Kyverno) yeniden başlıyor | `make up` 3 kez dener; olmazsa 1 dk bekleyip tekrar `make up` |
| `lvlNN siliniyor, bitmesi bekleniyor…` uzun sürüyor | Önceki `make down` bitmedi | Bekle; 5 dk'yı geçerse `kubectl get ns lvlNN -o yaml` → `status.conditions` |
| `Forbidden` / `TLS handshake timeout` / her şey yavaş | Docker VM'i doygun (en sık sebep) | Mac'te ağır işleri kapat; `docker stats` ile `linkly-*`'e bak; gerekirse `cd "$LADDER/platform" && make stop && make start` |
| `make grafana` boş sayfa / 502 | Grafana kapalı (otomatik turlar kapatır) | Seviye klasöründe `make profile` |
| `lvlNN.localtest.me` açılmıyor | DNS filtreleniyor ya da seviye ayakta değil | `dig lvl00.localtest.me` → 127.0.0.1 olmalı; değilse `/etc/hosts`'a `127.0.0.1 lvl00.localtest.me grafana.localtest.me prometheus.localtest.me` |
| `port is already allocated` (80/443/5001) | Portu başka bir şey tutuyor | `lsof -i :80`; başka bir kind kümesiyse `kind get clusters` → `kind delete cluster --name <ad>` |
| 13+'da POST `401` | Yönetim uçları API anahtarı ister | README §4'teki `Authorization: Bearer …` başlıklı komutu kullan |
| Script `SKIPPED` dedi | Ölçüm yapılamadı (ortam hazır değil) | Çıktıdaki sarı uyarıyı oku; genelde `make up` düzeltir |
| Grafana'da eski deneylerin çizgileri karışıyor | Prometheus 48 saat saklar | Seviye klasöründe `make fresh`; her şey için `cd "$LADDER" && make wipe CONFIRM=1` |
| `bad pattern` / `No rule to make target '#'` / `command not found: #` | zsh `#`'i yorum saymıyor | Bir kez: `echo 'setopt interactivecomments' >> ~/.zshrc`, yeni terminal |
| Her şey tuhaf | — | Seviye klasöründe `make status` ve `make logs`; platform için `cd "$LADDER/platform" && make status` |

## Seviye rehberleri

Her seviyenin README'si kendi başına yeter: en üstte ne yaşayacağın, **§4 Rehber**'de komut sırası, **§6**'da
her sorunun yapıştırılacak adımları.

| # | README | Slogan | Yeni gelen | Getirdiği acı | Sorun |
|---|---|---|---|---|---|
| 00 | [00-naive](00-naive/README.md) | Tek dosya, tek pod, bellek | — | Çöker, unutur, ölçeklenmez, kördür | 10 |
| 01 | [01-hardened](01-hardened/README.md) | Tek süreç ama düzgün | mutex, probe, graceful shutdown, timeout, metrics | Hâlâ unutur ve ölçeklenmez | 8 |
| 02 | [02-postgres](02-postgres/README.md) | Kalıcılık ve yatay ölçek | Postgres, stateless N replika | Her redirect DB'ye; havuz biter | 10 |
| 03 | [03-local-cache](03-local-cache/README.md) | Süreç içi önbellek | LRU + TTL + singleflight | Pod'lar arası tutarsızlık | 7 |
| 04 | [04-redis-cache](04-redis-cache/README.md) | Paylaşılan önbellek | Redis cache-aside | Redis tek arıza noktası, sıcak anahtar | 7 |
| 05 | [05-async-analytics](05-async-analytics/README.md) | Yazmayı okuma yolundan çıkar | Sınırlı kuyruk + toplu yazıcı | Sert ölümde tıklama kaybı | 6 |
| 06 | [06-event-stream](06-event-stream/README.md) | Olay akışı | Redpanda + tüketici | Tekrar, gecikme, zehirli mesaj | 7 |
| 07 | [07-services-autoscaling](07-services-autoscaling/README.md) | Servisleri ayır | 3 servis, HPA, KEDA | Darboğaz DB'ye kayar | 8 |
| 08 | [08-rate-limiting](08-rate-limiting/README.md) | Gürültülü komşu | Dağıtık hız sınırı | Limiter'ın kendi bağımlılığı | 6 |
| 09 | [09-database-scaling](09-database-scaling/README.md) | Veritabanı darboğazı | CNPG, PgBouncer, partition | Replikasyon gecikmesi | 6 |
| 10 | [10-resilience](10-resilience/README.md) | Hata izolasyonu | timeout, retry, breaker, yük atma | Ayar karmaşıklığı | 6 |
| 11 | [11-observability-deep](11-observability-deep/README.md) | Neden yavaş? | trace, exemplar, SLO, profil | Sampling, kardinalite | 8 |
| 12 | [12-delivery](12-delivery/README.md) | Güvenli dağıtım | Argo Rollouts canary, expand/contract | Migration/rollback uyumu | 6 |
| 13 | [13-security-tenancy](13-security-tenancy/README.md) | Kim, neye, ne kadar | API anahtarı, RLS, NetworkPolicy, Kyverno | Operasyonel sürtünme | 8 |
| 14 | [14-modern](14-modern/README.md) | Son hal | L1+L2 önbellek, kapasite modeli, game day | "Yolun devamı" listesi | 5 |

## Her seviyede aynı komutlar

Hepsi seviyenin klasöründe çalışır (`cd "$LADDER/NN-ad"`); bu liste başvuru içindir, blok olarak yapıştırılmaz.

```
make up        # profil → Grafana'yı temizle → build → push → deploy → rollout → smoke
make fresh     # Grafana'yı temizle: geçmiş çizgiler gider, kurulum ve veri kalır (her deneyin ilk adımı)
make down      # namespace sil
make status    # pod/servis durumu        ·  make logs  # uygulama logları
make load S=   # create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=  # PNN-XX sorununu reproduce et  → REPRODUCED / NOT-REPRODUCED / SKIPPED
make chaos C=  # pg-delay-2s redis-kill consumer-kill-30s … (make unchaos ile kaldır)
make set E=    # alıştırma: "TRAP_X=true CACHE_TTL=1h"  ·  make env  ·  make reset (hepsini geri al)
make grafana   # Ladder klasörü, level=lvlNN
make profile   # bu seviyenin platform bileşenlerini aç/kapat (make up zaten yapar)
make diff-prev # bir önceki seviyeyle fark — merdivenin asıl ders materyali
make verify-prev  # önceki seviyenin sorunları burada çözülmüş mü?
```

Kök klasörde (`cd "$LADDER"`): `make wipe CONFIRM=1` (verileri sil, kurulumu koru) · `make verify` (kümesiz
doğrulama: gofmt, vet, lint, test) · `make full-run` (tam tur) · `make help` (hepsi).

**Tam tur:** `make full-run` 00'dan 14'e her seviyeyi rehberin sırasıyla kendisi koşar (kur, önceki sorunlar,
kendi sorunları, kapat) ve `reports/tam-tur-<zaman>/RAPOR.md` yazar: her adımın saati, hükmü, logu ve saat
aralığı hazır Grafana linkleri. 8-12 saat sürer; bu sürede kümede başka iş yapma. Birkaç seviye için
`tools/full-run.sh 05-async-analytics 06-event-stream`.

## Grafana'yı okumak

Adres **http://grafana.localtest.me** · kullanıcı **`admin`** · şifre **`ladder`**. Paneller **Dashboards → Ladder**
klasöründe. Seviye README'lerindeki her "Grafana'da gör" linki panoyu o seviye seçili, son 15 dk açık olarak açar.

| Sayfanın üstü | Ne yapar | Deneyde |
|---|---|---|
| `level` seçici (sol üst) | Aynı paneller her seviye için: `lvl00` … `lvl14` | Çalıştığın seviye; yanlış seviye = boş panel |
| Zaman aralığı (sağ üst) | Grafiğin kapsadığı pencere | Deneyi kapsamalı: 30 dk önce koştuysan "Last 1 hour" |
| Yenileme (⟳ yanındaki ok) | Otomatik güncelleme | Deney sırasında **10s** |

Bir panelde: fareyi çizginin üstünde gezdir → o anki değerler; lejantta bir seriye tıkla → yalnız o seri;
panel başlığı → ⋮ → **View** (büyüt) · **Explore** (sorguyu gör).

**"No data" sıfır demek değildir**, "ölçülen bir şey yok" demektir. Sırayla bak: (1) seviye bu metriği üretiyor
mu? (README §8) · (2) `level` doğru mu? · (3) zaman aralığı deneyi kapsıyor mu? · (4) yeni mi başladı? —
metrikler 10–30 sn'de bir toplanır, yeni olay 30–90 sn gecikmeyle ve yumuşatılmış görünür · (5) Grafana/Prometheus
ayakta mı? (`cd "$LADDER/platform" && make status`; Grafana kapalıysa seviye klasöründe `make profile`).

**k6 "Dönen durum kodları"** (istemcinin gördüğü): `201` oluşturuldu · `301`/`302` normal yönlendirme · `404`
böyle kod yok · `429` hız sınırı (08+) · `500` uygulama hatası · `502` bağlantı istek sırasında koptu (pod öldü)
· `503` hazır pod yok (ya da 08+'da ingress'in hız sınırı) · `504` uygulama zamanında cevap vermedi · `0`
bağlantı hiç kurulamadı. Hatalar sayıca şişer (ölü pod'un 503'ü anında döner); "ne kadar başarısız?" sorusunu
çizginin **süresine** bakarak oku. `02 · App RED` (uygulamanın saydığı) ile `15 · k6` (istemcinin gördüğü)
arasındaki fark, aradaki katmanın (ingress, hız sınırı) ürettiği cevaptır.

**Grafana "ne oldu"yu gösterir, "neden"i log söyler.** Örnek 00 (başka seviyede klasörü ve `lvl00`'ı
değiştir). `RESTARTS` sütunu 0'dan büyük olan pod'u bul:

```bash
cd "$LADDER/00-naive"
kubectl -n lvl00 get pods
```

O pod'un **ölmeden önceki** son satırları (`<pod-adı>` yerine bulduğun adı yaz):

```bash
cd "$LADDER/00-naive"
kubectl -n lvl00 logs <pod-adı> --previous --tail=30
```

Tüm uygulama pod'larının şu anki logları (canlı akar; Ctrl+C ile çık):

```bash
cd "$LADDER/00-naive"
make logs
```

### Dashboard haritası

| Dashboard | Hangi soruya cevap | Dolu olduğu seviyeler |
|---|---|---|
| [`00 · Overview`](http://grafana.localtest.me/d/ladder-overview) | Tüm seviyeler yan yana | hepsi (kısmen) |
| [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods) | Pod'lar yaşıyor mu? Restart, bellek, CPU, hazır endpoint | hepsi |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red) | Kaç istek, kaçı hatalı, ne kadar sürüyor (uygulamanın gözünden) | 01+ |
| [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business) | Link oluşturma, yönlendirme, 404 | 01+ |
| [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache) | İsabet oranı, atılan kayıt, izdiham | 03+ |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres) | Bağlantı havuzu, sorgular, replikasyon | 02+ |
| [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis) | Paylaşılan önbellek, sıcak anahtar | 04+ |
| [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics) | Tıklama kuyruğu, kayıp | 05+ |
| [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream) | Olay akışı, gecikme (lag), tekrar | 06+ |
| [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling) | HPA/KEDA replika kararları | 07+ |
| [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit) | İzin/ret kararları | 01+ kısmen (süreç içi limiter), 08+ tam |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience) | Breaker, yük atma, retry, degrade | 10+ |
| [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo) | Hata bütçesi, burn rate | 11+ |
| [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout) | Canary adımları, analiz | 12+ |
| [`14 · Security`](http://grafana.localtest.me/d/ladder-security) | 401/403, reddedilen URL, politika | 13+ |
| [`15 · k6`](http://grafana.localtest.me/d/ladder-k6) | Yükün istemci tarafı — ne gönderildi, ne döndü | yük verildiğinde |

Diğer adresler: http://prometheus.localtest.me (ham metrik) · http://argocd.localtest.me (12+; kullanıcı
`admin`, şifre: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

## Kullanılan teknolojiler

Her araç bu projede tek bir iş yapar. **İlk** sütunu aracın hangi seviyede sahneye çıktığını söyler;
"kurulum" yazanlar platformla gelir ve her seviyede arka planda çalışır.

### Çalışma ortamı

| Araç | Bu projede ne yapar | İlk |
|---|---|---|
| **Docker Desktop** | Mac'te Linux konteynerlerini çalıştıran VM; kümenin tamamı içinde (CPU/bellek: *Settings → Resources*) | kurulum |
| **kind** | Her Kubernetes düğümü bir Docker konteyneri: `linkly` kümesi, 1 control-plane + 3 worker | kurulum |
| **Kubernetes** | Konteynerleri düğümlere yerleştirir, ölünce yeniden başlatır, trafiği dağıtır; her seviye kendi namespace'inde (`lvl00` … `lvl14`) | 00 |
| **kubectl** | Kubernetes'in komut satırı: `kubectl -n lvl00 get pods` | 00 |
| **Helm** | Kubernetes paket yöneticisi; platform bileşenlerini kurar (`platform/helm/*.values.yaml`) | kurulum |
| **Kustomize** | Seviyenin YAML'larını birleştirir (`deploy/kustomization.yaml`) | 00 |
| **Calico** | Pod ağını kuran ve NetworkPolicy'yi uygulayan eklenti (13'ün ağ kuralları için) | kurulum |
| **ingress-nginx** | Dışarıdan gelen HTTP'yi alan adına göre servise yollar: `lvl00.localtest.me` → lvl00; 08+'da kaba hız sınırı | 00 |
| **localtest.me** | Her alt adı `127.0.0.1`'e çözen genel alan adı; `/etc/hosts` gerekmez | 00 |
| **Yerel registry** (`linkly-registry`, :5001) | İmaj deposu: `make up` imajı buraya iter, küme buradan çeker | 00 |
| **metrics-server** | Pod'ların anlık CPU/belleği: `kubectl top`, HPA'nın sinyali | 07 |
| **make** | Uzun komutlara kısa ad: `make up`, `make repro`, `make load` … | 00 |
| **jq · python3** | JSON işleme · yardımcı scriptler | 00 |

### Uygulama

| Araç | Bu projede ne yapar | İlk |
|---|---|---|
| **Go** | Bütün servisler; imajlar Docker içinde derlenir | 00 |
| **net/http** | Go'nun HTTP sunucusu; 00'da korumasız, 01'den itibaren timeout ve düzgün kapanma | 00 |
| **log/slog** | JSON log: her istek bir satır; 11'de `trace_id` taşır | 01 |
| **prometheus/client_golang** | Uygulamanın kendi metrikleri (`/metrics`): istek sayısı, süre, havuz, önbellek, kuyruk | 01 |
| **pgx** | Postgres sürücüsü ve bağlantı havuzu; havuz beklemesi ölçülür | 02 |
| **goose** | Veritabanı şema migration'ı (`migrate` Job'ı; 12'de expand/contract) | 02 |
| **go-redis** | Redis istemcisi: önbellek (04), hız sınırı (08), geçersiz kılma yayını (14) | 04 |
| **franz-go** | Kafka istemcisi: tıklama olaylarını üretir ve tüketir | 06 |
| **OpenTelemetry SDK** | Trace üretir (bir isteğin servisler arası yolculuğu) → Alloy → Tempo | 11 |
| **pprof** | Go'nun profilleyicisi (`:6060`): "CPU'yu hangi satır yiyor?" | 11 |

### Veri

| Araç | Bu projede ne yapar | İlk |
|---|---|---|
| **PostgreSQL 17** | İlişkisel veritabanı: linkler ve günlük tıklama sayıları | 02 |
| **postgres-exporter** | Postgres'in iç durumunu (bağlantı, kilit, sorgu) metriğe çevirir (02–08) | 02 |
| **CloudNativePG (CNPG)** | Postgres operatörü: primary + replika, otomatik failover | 09 |
| **PgBouncer** | Postgres önünde bağlantı havuzu: `pg-pooler-rw` (yazma), `pg-pooler-ro` (okuma) | 09 |
| **Redis 7** | Bellek içi anahtar-değer: önbellek (04), hız sınırı sayacı (08), pub/sub ile geçersiz kılma (14) | 04 |
| **redis_exporter** | Redis metrikleri: bellek, komut/sn, isabet | 04 |
| **Redpanda** | Kafka API'siyle konuşan olay akışı sunucusu: tıklama topic'i, tüketici grubu, DLQ | 06 |

### Gözlemlenebilirlik

| Araç | Bu projede ne yapar | İlk |
|---|---|---|
| **Prometheus** | Metrikleri toplar ve saklar (uygulama 10 sn, küme 30 sn aralıkla; 48 saat); k6 sonuçları da burada | kurulum |
| **PromQL** | Prometheus'un sorgu dili; her panel ve her `make repro` ölçümü | 00 |
| **Grafana** | Metrik, log ve trace'i panellerde gösterir, veri tutmaz — http://grafana.localtest.me | kurulum |
| **prometheus-operator** | *ServiceMonitor* (neyi topla) ve *PrometheusRule* (kayıt/alarm kuralı) nesneleri | 01 |
| **kube-state-metrics** | Kubernetes nesnelerinin durumu: restart, replika, hazır endpoint | 00 |
| **cAdvisor** (kubelet'in içinde) | Konteyner başına CPU ve bellek; 00'da tek göz | 00 |
| **node-exporter** | Düğüm CPU/belleği | kurulum |
| **Alertmanager** | Alarmları toplar ve gruplar: SLO burn-rate alarmları | 11 |
| **Loki** | Log deposu; `trace_id`'ye tıklayınca Tempo'daki trace açılır | 11 |
| **Alloy** | Her düğümde toplayıcı: loglar → Loki, trace'ler → Tempo | 11 |
| **Tempo** | Trace deposu: "istek nerede yavaşladı?" | 11 |
| **Exemplar** | Gecikme grafiğindeki noktaya iliştirilmiş örnek trace; tıkla → o isteğin trace'i | 11 |

### Yük, arıza ve ölçekleme

| Araç | Bu projede ne yapar | İlk |
|---|---|---|
| **k6** | Yük üretici (sanal kullanıcı = VU): `make load S=…`, 10 senaryo; sonuçlar `15 · k6` panosunda | 00 |
| **Chaos Mesh** | Kontrollü arıza — pod öldürme, ağa gecikme/kayıp: `make chaos C=…`, 12 şablon | 02 |
| **HPA** | Kubernetes'in yerleşik ölçekleyicisi: CPU'ya göre replika sayısı (redirect-svc) | 07 |
| **KEDA** | Olay kaynaklı ölçekleyici: kuyruk gecikmesine göre replika sayısı (analytics-consumer) | 07 |

### Dağıtım ve güvenlik

| Araç | Bu projede ne yapar | İlk |
|---|---|---|
| **Argo Rollouts** | Kademeli dağıtım (canary) + Prometheus'a bakan otomatik analiz; kötü sürüm canary'de geri alınır | 12 |
| **Argo CD** | GitOps: kümeyi Git'e eşitler; kurulu, Application bilerek tanımsız (P12-03) | 12 |
| **API anahtarı (sha256)** | Kiracı kimliği: `Authorization: Bearer …`, hash'lenip sabit zamanda karşılaştırılır | 13 |
| **Postgres RLS** | Satır düzeyi güvenlik: kiracı filtresini veritabanı uygular | 13 |
| **NetworkPolicy** | Pod'lar arası trafik için izin listesi (varsayılan-reddet) | 13 |
| **Kyverno** | Kurala uymayan manifest'i kümeye sokmaz: `:latest` yasak, bellek limiti ve probe zorunlu | 13 |
| **sealed-secrets** | Sırrı şifreleyip Git'e koymayı sağlar; kurulu, P13-04 sırların hâlâ düz metin olduğunu gösterir | 13 |
| **cert-manager** | TLS sertifikası üretir; kurulu, ingress bilerek HTTP | 13 |

### Merdivenin kendi araçları

| Araç | Ne yapar |
|---|---|
| `ladder.mk` | Her seviyenin Makefile'ı bunu içe alır: `make up/down/load/repro/chaos/set/grafana …` |
| `problems/PNN-XX.sh` | Bir sorunu ölçerek üreten script; hükmü `REPRODUCED` / `NOT-REPRODUCED` / `SKIPPED` |
| `platform/lib/profile.sh` | Seviyenin kullanmadığı platform bileşenlerini kapatır, gerekenleri açar (`make up`'ın ilk adımı) |
| `platform/lib/wipe.sh` | `make wipe`: verileri siler, kurulumu korur |
| `platform/dashboards/gen.py` | 16 Grafana panosunu tek kaynaktan üretir |
| `tools/lint-skeleton.sh` · `tools/lint-guide.py` · `tools/lint-grafana.py` | Seviyelerin aynı iskelette kaldığını, rehber bloklarının yapıştırılabildiğini ve README'deki her panel adının gerçekten var olduğunu denetler |

## Sık geçen kavramlar

| Kavram | Kısaca |
|---|---|
| **Konteyner · imaj** | Uygulama + bağımlılıkları tek pakette (imaj); çalışan kopyası konteyner |
| **Pod** | Kubernetes'in en küçük birimi: bir ya da birkaç konteyner, tek IP |
| **Deployment · StatefulSet** | N kopya pod'u ayakta tutan nesne; StatefulSet sıralı ve kalıcı diskli (Postgres, Redis, Redpanda) |
| **Service** | Bir grup pod'a sabit ad ve yük dağıtımı; pod'lar gelir gider, Service kalır |
| **Ingress** | Dışarıdan gelen HTTP'yi alan adına göre Service'e yönlendiren kural |
| **Namespace** | Küme içinde ayrı bir oda; her seviye `lvlNN`'de, silinince içindeki her şey gider |
| **Readiness · liveness probe** | "Trafik alabilir mi?" (hayırsa trafikten çıkarılır) · "Yaşıyor mu?" (hayırsa yeniden başlatılır) |
| **Rolling update · rollout** | Pod'ları eskisinden yenisine kademeli değiştirmek |
| **Graceful shutdown** | Kapanırken yeni istek almayı bırakıp elindekileri bitirmek |
| **PDB** | PodDisruptionBudget: "gönüllü kapatmalarda aynı anda en az şu kadar pod ayakta kalsın" |
| **Requests · limits** | Pod'un ayırttığı ve aşamayacağı CPU/bellek; bellek limitini aşan konteyner **OOMKilled** (çıkış kodu 137) |
| **Operatör · CRD** | Kubernetes'e yeni nesne türü (CRD) ekleyip onu yöneten controller — CNPG, KEDA, Argo, Kyverno |
| **Finalizer** | Bir nesne silinmeden önce controller'ın işini bitirmesini bekleten kilit |
| **Metrik · log · trace · profil** | Ne kadar · neden · nerede · hangi satır |
| **RED** | Bir servisin üç sağlık sayısı: Rate (istek/sn), Errors (hata oranı), Duration (süre) |
| **Histogram · p50 · p99** | Süreleri kovalara sayan metrik; p99 = isteklerin %99'unun bittiği süre, yani en yavaş %1'in sınırı |
| **Scrape · scrape aralığı** | Prometheus'un hedefin `/metrics` ucunu okuması; aralıktan kısa olaylar grafikte düzleşir |
| **Kardinalite** | Bir metriğin etiket kombinasyonu sayısı; her kombinasyon ayrı seri, ayrı bellek |
| **SLO · hata bütçesi · burn rate** | Hedef (örn. %99.9 başarı) · hedefin izin verdiği hata miktarı · bütçenin tükenme hızı |
| **Connection pool** | Veritabanı bağlantılarını yeniden kullanan havuz; dolunca istekler sırada bekler |
| **Cache-aside · TTL · LRU** | Önce önbelleğe bak, yoksa DB'den okuyup yaz · kaydın ömrü · yer dolunca en uzun süredir kullanılmayanı at |
| **Cache stampede · singleflight** | Aynı anda süresi dolan bir anahtar için yüzlerce isteğin DB'ye koşması · aynı anahtarı tek istekle getirmek |
| **Hot key** | Trafiğin orantısız büyük kısmını alan tek anahtar |
| **At-most-once · at-least-once · idempotency** | En fazla bir kez (kayıp olabilir) · en az bir kez (tekrar olabilir) · tekrarın sonucu değiştirmemesi |
| **Consumer lag · DLQ** | Tüketicinin logun gerisinde kaldığı mesaj sayısı · işlenemeyen mesajların ayrıldığı kuyruk |
| **Replikasyon gecikmesi · read-your-writes** | Replikanın primary'nin gerisinde kalması · yazdığını hemen okuyabilme garantisi |
| **Failover** | Primary ölünce bir replikanın primary'ye terfi etmesi |
| **Timeout · retry · circuit breaker · bulkhead · load shedding** | Bekleme sınırı · yeniden deneme · arızalı bağımlılığa çağrıyı kesmek · kaynakları bölmelere ayırmak · kapasite dolunca yeni işi hızlıca reddetmek |
| **Rate limit · sabit pencere** | Birim zamandaki istek sınırı · "her dakika sıfırlanan sayaç" tipi sınır |
| **Canary · rollback** | Yeni sürümü önce trafiğin küçük bir kısmına vermek · önceki sürüme dönmek |
| **Expand/contract** | Şemayı önce genişletip (eski ve yeni kod birlikte çalışır) sonra daraltmak |
| **Drift** | Kümedeki gerçek durumun Git'teki tanımdan sapması |
| **Chaos · game day** | Arızayı bilerek, kontrollü üretmek · bütün korumaları aynı anda sınayan tatbikat |
| **`TRAP_*` bayrağı** | Bir çözümü kapatan ortam değişkeni; sorunun geri geldiğini görmek için (§7 alıştırmaları) |
| **REPRODUCED · NOT-REPRODUCED · SKIPPED** | `make repro` hükmü: sorun var · sorun yok · ölçülemedi (sahte hüküm vermek yerine durdu) |

## Tekdüzelik

15 seviyenin hepsi **aynı iskelete, aynı Makefile'a, aynı `make up` yoluna, aynı panolara, aynı k6 senaryolarına
ve aynı chaos şablonlarına** sahiptir. Seviyeler arasında yalnızca iki şey değişir: **uygulama kodu** (`cmd/`,
`internal/`, `deploy/`) ve **README'deki sorunlar** (`problems/PNN-XX.sh`). Bir seviyeyi öğrendiysen hepsini
öğrendin; `tools/lint-skeleton.sh` sapmayı hata sayar. Dashboard'lar, k6 senaryoları, chaos şablonları ve helm
ayarları `platform/`'da tek kopyadır.

## Ölçüm ve ortam kuralları

Bir sonuç açıklanamaz göründüğünde ya da yeni bir deney yazarken: [docs/OLCUM.md](docs/OLCUM.md) — platformun
hangi kurallarla kurulduğu (neden her seviye yalnızca kendi bileşenlerini açık tutar, Prometheus neden ölçülü
toplar…) ve her reproduce scriptinin uyduğu ölçüm kuralları (pencere, çözünürlük, "düşemeyen deney deney
değildir"…).

## Sayılarla

| | |
|---|---|
| Seviye | 15 (`00-naive` … `14-modern`) |
| Reproduce scripti | **108** (`PNN-XX.sh`, her biri REPRODUCED/NOT-REPRODUCED/SKIPPED döner) |
| `TRAP_*` alıştırma bayrağı | 33 |
| Go satırı (yorumlar dahil) | ~69 000 |
| Paylaşılan Grafana panosu | 16 (`$level` seçicili, tek set) |
| k6 senaryosu · chaos şablonu | 10 · 12 |
