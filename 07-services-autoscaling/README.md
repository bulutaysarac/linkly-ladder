# 07 — services-autoscaling · "Servisleri ayır, otomatik ölçekle"

> **Bu seviyede ne yaşayacaksın?**
> - Tek uygulamanın üçe ayrılması ve her birinin kendi ölçekleme sinyali: redirect CPU'ya göre (HPA), tüketici lag'e göre (KEDA)
> - HPA'nın yükten sonra geç tepki vermesi (P07-01); ölçeklemenin darboğazı yok etmeyip DB'ye taşıması (P07-02)
> - Yeni pod'un "hazır" ama önbelleği soğuk olması (P07-03); CPU limitinin bir kota olarak gecikme üretmesi (P07-04); düğüm kapasitesi bitince Pending (P07-05)
> - Tuzaklar: N+1 sorgu (P07-06), her zaman "hazır" diyen probe (P07-08); bir düğüm donunca yedekliliğin işe yaramaması (P07-07)
>
> **Bu seviye olmasa ne olur?** Okuma, yazma ve tüketim tek bir replika sayısını paylaşır — biri yük alınca hepsi birlikte ölçeklenir ya da hiçbiri.
>
> **Yeni gelen teknolojiler:** HPA, KEDA, metrics-server, üç ayrı Deployment (redirect-svc, api-svc, analytics-consumer), `09 · Autoscaling` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Tek uygulama üçe ayrıldı: **redirect-svc** (trafiğin ~%99'u, salt okuma), **api-svc** (yazma ve
yönetim) ve **analytics-consumer** (06'dan). Her birinin kendi replika sayısı, kendi bağlantı
havuzu, kendi kaynak limitleri ve kendi ölçekleme sinyali var: redirect CPU'ya göre (HPA),
tüketici **lag**'e göre (KEDA). Bu bir "mikroservis" tercihi değil — **her yük şekline kendi
düğmesini vermek**.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I["ingress<br/>/api → api-svc<br/>/ → redirect-svc"]
  I --> RS & AS

  subgraph RS["redirect-svc · HPA 2–12"]
    direction TB
    R1["küçük havuz (6)<br/>CPU limiti sıkı"]
  end
  subgraph AS["api-svc · sabit 2"]
    A1["büyük havuz (15)<br/>CPU limiti yok"]
  end

  RS --> RD[(redis)]
  RS ==>|clicks| K[(redpanda)]
  AS --> PG[("postgres")]
  RS -.->|MISS| PG
  K ==> CN["analytics-consumer<br/>KEDA: lag ≥ 500"]
  CN --> PG
```

Dışarıdan **hiçbir şey değişmedi**: aynı host, aynı URL uzayı, aynı sözleşme. *Servis sınırı
içeriye ait bir karardır; client'ları değiştirmeye zorluyorsa sınır yanlış yere çizilmiştir.*

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P06-02 | Tüketici gecikmesi (lag) elle yönetiliyordu | KEDA `ScaledObject`: tüketici **lag**'e göre 1→6 ölçekleniyor. CPU değil lag, çünkü CPU bir tüketici için yanlış sinyaldir — bir milyon olay beklerken boşta olabilir |

Bir madde daha var ama **listeye yazmıyorum** ve sebebi öğretici: P05-03'ü (yazıcının okumayla
aynı süreci paylaşması) 06 zaten çözmüştü. 07 onu **derinleştiriyor**: artık okuma ve yazma
YOLLARI da birbirinden ayrıldı. Çözülmüş bir sorunu tekrar sahiplenmek, merdivenin hesabını bozar.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl07.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl07.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl07 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P07-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

Ölçeklemeyi izlemek için:
```bash
kubectl -n lvl07 get hpa,scaledobject -w
kubectl -n lvl07 get pods -l app.kubernetes.io/name=redirect -w
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). **Dışarıdan hiçbir fark yok** — ingress yol
tabanlı yönlendirme yapıyor (`/api` → api-svc, geri kalan → redirect-svc).

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P07-01 | HPA gecikir: burst'te pod yok | `make repro P=P07-01` | [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "İstek / sn ve pod sayısı" | seviye içi (tampon) |
| P07-02 | Ölçekleme darboğazı DB'ye taşır | `make repro P=P07-02` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "Otomatik ölçekleyici: istenen / mevcut pod" | 09 |
| P07-03 | Yeni pod hazır ama soğuk | `make repro P=P07-03` | [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "p99 süre (pod'a göre; yeni pod soğuk)" | seviye içi |
| P07-04 | CPU limiti = kota → throttling | `make repro P=P07-04` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "CPU kısıtlama (throttling)" | seviye içi |
| P07-05 | Node kapasitesi bitti → Pending | `CONFIRM=1 make repro P=P07-05` | [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "Yer bekleyen pod" | (bulut: autoscaler) |
| P07-06 | **TRAP** N+1: maliyet sonuç kümesiyle orantılı | `make repro P=P07-06` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "Veritabanı sorguları (türe göre)" | seviye içi · 14 |
| P07-07 | Node donunca yedeklilik işe yaramıyor | `CONFIRM=1 make repro P=P07-07` | [09 · Autoscaling](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-30m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-30m&to=now&refresh=10s) → "Düğüm başına pod" | 10 |
| P07-08 | **TRAP** her zaman hazır diyen probe | `make repro P=P07-08` | [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-15m&to=now&refresh=10s) → "Hazır pod adresi (endpoint) sayısı" | seviye içi |

---

### P07-01 · HPA gecikir

**Belirti:** 5 rps'ten 400 rps'e 5 saniyede çıkan bir burst'te p99 fırlar; pod'lar yük **bittikten
sonra** gelir.
**Neden:** Ölçekleme reaktiftir ve zincir uzundur: metrics-server'ın CPU örneklemesi (15 sn) → HPA
döngüsü (15 sn) → schedule → imaj → süreç başlangıcı → readiness. [Topic · Konu: Reaktif ölçekleme, kapasite]

**Reproduce:** `make repro P=P07-01` — `burst` senaryosunu koşar (5 → 400 rps, tepe 20 sn), tepe p99
ile HPA'nın istediği ve gerçekten hazır olan replika sayısını karşılaştırır. Tepe varsayılan olarak
400: bu kümede redirect ~650 istek/s kaldırıyor; 1000'lik bir tepe gecikmeyi değil yıkımı ölçer
(probe'lar düşer, pod'lar yeniden başlar). Daha sert burst için: `PEAK=1000 make repro P=P07-01`.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — `burst` ~70 sn sürer; bittikten sonra 1–2 dk daha izle, pod'lar geç gelir (giriş: admin / ladder)
- "İstek / sn ve pod sayısı" → `istek / sn` yarım dakikalık dik bir tepe çizer; `pod sayısı` çizgisi tepe **geçtikten sonra** basamaklanır. `pod sayısı` namespace'teki bütün pod'ları sayar (postgres, redis, redpanda, api, tüketici dahil), yani tabanı 2 değildir — basamağın **ne zaman** geldiğine bak.
- "Otomatik ölçekleyici: istenen / mevcut pod" → `istenen: redirect` ancak burst'ün ortasında ya da sonunda 2'nin üstüne çıkar; `mevcut: redirect` onu gecikmeyle izler. İki çizgi ile rps tepesi arasındaki yatay mesafe, Neden'deki zincirin süresidir.
- "p99 süre (uç noktaya göre)" → `/{code}` burst anında sıçrar ve yeni pod'lar hazır olmadan, yük bittiği için düşer.

**Ders:** *Otomatik ölçekleme burst için değil, TREND için tasarlanmıştır.* Ani yük bir kapasite
sorunudur, bir otomasyon sorunu değil — `minReplicas`'ı tabanı karşılayacak kadar yüksek tutmak
"israf" değil, burst sigortasıdır.

---

### P07-02 · Ölçekleme darboğazı taşır, yok etmez

**Belirti:** HPA redirect'i 12 replikaya çıkarır; uygulama CPU'su rahatlar, **Postgres bağlantıları
tavana dayanır** ve havuz bekleme süresi büyür.
**Neden:** Her yeni pod kendi havuzunu açar. `12 × 6 + 2 × 15 + 10 = 112 > max_connections=100`.
[Topic · Konu: Paylaşılan kaynak, ölçeklenemeyen katman]

**Reproduce:** `make repro P=P07-02` — aritmetiği basar, `stairs` yükünü koşar, pod sayısı ile
DB bağlantılarını ve CPU'ları birlikte ölçer.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s), [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) — `stairs` yükü ~3 dk sürer, başlatınca aç (giriş: admin / ladder)
- "Otomatik ölçekleyici: istenen / mevcut pod" → `redirect` replikası merdivenle birlikte basamak basamak artar (en fazla 12).
- "Bağlantılar ve üst sınır" → durum (`active`, `idle` …) çizgileri pod sayısıyla birlikte yükselir ve `üst sınır` (100) çizgisine yaklaşır: her yeni pod kendi havuzunu açıyor.
- "Uygulama havuzu: bağlantı bekleme (p99)" → pod sayısı arttıkça yükselir: pod'lar bağlantı **bekliyor**. Script bunun 50 ms'yi aşmasını (ya da DB hatasını) arıyor. (Bekleme pgx'in her bağlantı alımının etrafında ölçülür — `internal/store/postgres.go`, `acquireTracer`. Havuzun durumuna bakan bir çağrıyı süreleyen bir ölçü burada yapı gereği ~0 okurdu: bekleme alımın kendisinde.)
- "Veritabanı CPU" → merdivenle yükselir.
- "CPU kullanımı (çekirdek)" (Pods) → aynı anda `redirect-…` pod'larının her biri düşük kalır: darboğaz uygulamada değil.

**Nerede çözülüyor:** 09 (PgBouncer: yüzlerce uygulama bağlantısı → onlarca DB bağlantısı; okuma
replikaları). *Otomatik ölçekleme darboğazı görünmez yapmaz, taşır — ve taşıdığı yer genelde
ölçeklenemeyen yerdir.*

---

### P07-03 · Yeni pod "hazır" ama soğuk

**Belirti:** Ölçekleme anında p99 yükselir; en genç pod'lar en yavaştır.
**Neden:** readiness "süreç ayakta ve dinliyor" der; "havuzum açık, önbelleğim ısındı" demez.
[Topic · Konu: Soğuk başlangıç, readiness semantiği]

**Reproduce:** `make repro P=P07-03` — yük altında replika ekler ve pod bazında p99 dağılımını basar.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl07&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; ölçekleme ikinci yük fazının ~12. saniyesinde (giriş: admin / ladder)
- "p99 süre (pod'a göre; yeni pod soğuk)" → ölçekleme anında dört yeni `redirect-…` çizgisi belirir; ilk noktaları eski pod'lardan yüksektir, sonra onlara yakınsar. Fark küçüktür (aşağıya bak). Panel tüm rotaları ve `api-…` pod'larını da çizer; `redirect-…` çizgilerine bak.
- "İsabet oranı (pod'a göre)" → yeni `redirect-…` pod'larının oranı ilk noktadan itibaren eskilerle aynı seviyede: önbellek Redis'te (L2) ve zaten sıcak, yeni pod boş bellekle doğmuyor.

**Bu seviyede maliyeti KÜÇÜK** — çünkü önbellek paylaşımlı (04). Aynı deney 03'te çok daha sert
olurdu: her yeni pod boş bellekle doğuyordu. *Mimarinin bir seviyede verdiği karar, üç seviye
sonraki bir sorunun şiddetini belirliyor.*
**Araçlar:** `startupProbe`, havuzda `MinConns`, ingress'te slow-start.

---

### P07-04 · CPU limiti bir kota'dır

**Belirti:** CPU kullanımı %50 görünürken p99 fırlar. Limit kaldırıldığında CPU artar ve p99 düşer.
**Neden:** CPU limiti, 100 ms'lik dilimlerde kullanılabilir çekirdek-zamanını sınırlar. Kota dilim
ortasında biterse süreç **bekler**. [Topic · Konu: CFS kotası, throttling]

**Reproduce:** `make repro P=P07-04` — aynı yükü limitli ve limitsiz koşup p99 ile CPU'yu karşılaştırır.

> **Ortam sınırı:** Bu kurulumdaki cAdvisor `container_cpu_cfs_throttled_*` metriğini **yayınlamıyor**
> (kind + Docker Desktop, cgroup v1). Throttling'i doğrudan okuyamıyoruz; bu yüzden script dolaylı
> kanıt kullanıyor: limitli/limitsiz p99 farkı. *Ölçemediğin şeyi, ölçebildiğin bir şeyle kuşatmak
> gözlemlenebilirliğin sık kullanılan bir tekniğidir* — ve bunu README'de yazmak, sessizce boş bir
> panele bakmaktan iyidir.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — iki faz var (dar kota, sonra kotasız), her biri 60 sn yük; tek `redirect` pod'u her fazda yeniden başlar (giriş: admin / ladder)
- "CPU kısıtlama (throttling)" → bu kurulumda büyük olasılıkla **boş** (yukarıdaki ortam sınırı). Doluysa: dar kota fazında `redirect-…` çizgisi yükselir, kotasız fazda 0'a yakın kalır.
- "CPU kullanımı (çekirdek)" → dar kota fazında tek `redirect-…` pod'u kotada (`TIGHT`, varsayılan 50m = 0.05 çekirdek) düz bir tavana yapışır; kotasız fazda (yeni pod adıyla) belirgin biçimde yükselir.
- "p99 süre (uç noktaya göre)" → `/{code}` dar kota fazında yüksek, kotasız fazda düşük: aradaki fark kotanın bedeli — throttling'i göremediğimiz yerde onu kuşatan dolaylı kanıt bu.

**Kural:** Bellek limiti şarttır (OOM koruması). **CPU limiti çoğu zaman zarar verir**; `requests`
zaten planlamayı ve adil paylaşımı sağlar.

---

### P07-05 · Node kapasitesi bitince Pending

**Belirti:** 10 replika istenir, bir kısmı çalışır, gerisi Pending'de bekler. Replika sayısını
isteyen taraf (HPA ya da `kubectl scale`) bunu bilmez; Deployment "10 replika" der ve mutlu görünür.
**Neden:** Ölçekleyici replika **sayısı** ister; yerleştirmek scheduler'ın işi. kind'da cluster
autoscaler yok. [Topic · Konu: Ölçekleme zinciri, kapasite]

**Reproduce:** `CONFIRM=1 make repro P=P07-05` — pod başına CPU isteğini bir node'un %60'ına çıkarır,
HPA'nın tabanını (`minReplicas`) geçici olarak 10'a çeker ve Deployment'ı 10'a ölçekler: 10, bir yük
dalgasındaki gibi HPA'nın **kendi** isteği olur. (Taban yerinde kalmazsa CPU düşük olduğu için HPA
45 sn'lik bekleme içinde ölçeği geri çeker, Pending pod'lar silinir ve ölçüm kapasiteyi değil HPA'yı
ölçer; script 45 sn sonra istenen sayının hâlâ 10 olduğunu doğrular, değilse hüküm vermez.) Pending
sayısını ve scheduler'ın mesajını basar; temizlik HPA'nın eski tabanını geri koyar.

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now&refresh=10s) — scripti başlattıktan ~1 dk sonra aç (giriş: admin / ladder)
- "Yer bekleyen pod" → 0'dan birkaç pod'a sıçrar ve script temizlik yapana kadar orada kalır.
- "Düğüm CPU: ayrılabilir / istenen" → `pod'ların istediği` çizgisi `ayrılabilir`'a dayanır: yeni pod'ların isteği hiçbir node'a sığmıyor. (Bu panel küme genelidir, seviye seçicisine bakmaz.)
- "Otomatik ölçekleyici: istenen / mevcut pod" → `istenen: redirect` 10'a çıkar (HPA'nın tabanı 10) ve `mevcut: redirect` de 10 olur, çünkü Pending pod'lar da sayılır: ölçekleyicinin gördüğü sayı "10 pod var"dır. İki çizgi üst üste biner — HPA istediğini aldığını sanıyor; farkı yalnızca "Yer bekleyen pod" gösterir.

**Ders:** Ölçekleme zinciri `metrics-server(15s) → HPA(15s) → scheduler → NODE(dakikalar) → imaj → başlangıç`.
*Kapasite planlaması bu zincirin en yavaş halkasına göre yapılır.*

---

### P07-06 · TRAP · N+1: maliyet sonuç kümesiyle orantılı

**Belirti:** 100 link listeleyen bir istek 101 sorgu yapar; süre beş katına çıkar.
**Neden:** Döngü içinde sorgu. Küçük veride görünmez; sayfa boyutunu büyüttüğün gün patlar.
[Topic · Konu: N+1, batch]

**Reproduce:** `make repro P=P07-06` — 100 link oluşturur, tuzak kapalı/açık süreyi ve DB sorgu
sayısını karşılaştırır.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç (giriş: admin / ladder)
- "Veritabanı sorguları (türe göre)" → başta 100 oluşturma `create` serisinde görünür. Varsayılan fazda liste isteği yalnızca `list` serisinde küçük bir kıpırtıdır; tuzak açıkken aynı istek `stats` serisinde **ayrı** bir tepe doğurur: link başına bir sorgu (100 link → ~100 sorgu). Yalnızca birkaç liste isteği atıldığı için tepeler alçak ve kısadır; sorgu sayısının kendisi terminalde.
- "p99 süre (uç noktaya göre)" → `/api/links` çizgisi tuzak fazında daha yüksektir.

**Ders:** Sayfa boyutu bir ayar değil, bir **maliyet çarpanı** hâline gelir. Doğrusu tek toplu sorgu
(`WHERE code = ANY($1)`) ya da tek JOIN. **Servis ayrımı bunu kötüleştirir**: 101 fonksiyon çağrısı
101 **ağ** çağrısına dönebilir → 14'te gRPC + batch.

---

### P07-07 · Node donunca yedeklilik işe yaramıyor

**Belirti:** Bir worker `docker pause` ile dondurulduğunda istekler düşmeye başlar ve bu **dakikalarca** sürer.
**Neden:** Donmuş node'daki pod'lar Endpoints'te **kalır** — kubelet cevap vermiyor ama API server
pod'u hâlâ Ready sanıyor. `node-monitor-grace-period` (40 sn) + eviction timeout (5 dk) boyunca
trafik ölü pod'lara gider. [Topic · Konu: Düğüm arızası, sağlık algılama gecikmesi]

**Reproduce:** `CONFIRM=1 make repro P=P07-07` — node'u dondurur, NotReady süresini ve 5xx'i ölçer,
sonra çözer.

**Bu deney varsayılan olarak ATLANIR.** Node'un kubelet'ini donduruyor ve çözdükten sonra
containerd'nin PLEG'i ölü kalabiliyor — node onlarca dakika `NotReady` kalabilir, o node'daki
Chaos Mesh/Argo/KEDA pod'ları çürür ve sonraki bütün ölçümler bozuk bir kümede koşar.
Bilerek çalıştır: `FREEZE_NODE=1 CONFIRM=1 make repro P=P07-07`.
*Bir deneyin bedeli ortamın tamamıysa, onu varsayılan yapma.*

**Grafana'da gör:** [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-30m&to=now&refresh=10s), [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-30m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-30m&to=now&refresh=10s) — yalnızca `FREEZE_NODE=1` ile koştuysan dolar; varsayılan koşu node'u dondurmadan çıkar (giriş: admin / ladder)
- "Düğüm başına pod" → donmuş node'un çizgisi **düşmez**: Kubernetes o node'daki pod'ları hâlâ yerinde sanıyor (40 sn + 5 dk kuralı).
- "Dönen durum kodları" (k6) → donma anından itibaren `302` çizgisi belirgin biçimde düşer; ölü pod'a giden istekler zaman aşımına uğradıkça 5xx (`502`/`504`) çizgileri belirir. Kodların anlamı: [Grafana'yı okumak](../README.md#grafanayı-okumak).
- "İstek / saniye (pod'a göre)" (App RED) → donmuş node'daki `redirect-…` pod'unun çizgisi kesilir (Prometheus onu da kazıyamıyor), diğerleri sürer. "5xx by route" burada 0 kalabilir: zaman aşımını uygulama değil ingress üretiyor, hatayı k6 tarafında gör.

**Nerede çözülüyor:** 10 (devre kesici + aktif sağlık kontrolü: *Kubernetes'in fark etmesini
beklemek yerine client'ın kendisi hızlı karar verir*). Ayrıca `topologySpread`'i `DoNotSchedule`
yapmak — ama o da kapasiteyi zorlar (P07-05).

---

### P07-08 · TRAP · Her zaman hazır diyen probe

**Belirti:** `TRAP_READY_ALWAYS` ile rollout sırasındaki 5xx sayısı artar.
**Neden:** Bir probe'un değeri **hayır diyebilmesindedir**. Sabit 200, Kubernetes'in elindeki tek
gerçek bilgiyi siler. [Topic · Konu: Probe semantiği]

**Reproduce:** `make repro P=P07-08` — aynı rollout'u varsayılan ve tuzaklı readiness ile koşup
5xx'leri karşılaştırır.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl07&from=now-15m&to=now&refresh=10s) — iki rollout var (varsayılan, sonra tuzaklı); scripti başlatınca aç (giriş: admin / ladder)
- "Hazır pod adresi (endpoint) sayısı" → her rollout'ta `redirect-…` çizgisi kısa bir tepe/çukur çizer (yeni pod'lar girer, eskiler çıkar). Tuzak fazında yeni pod'lar süreç açılır açılmaz hazır sayılır; iki rollout'un şeklini yan yana karşılaştır.
- "Dönen durum kodları" (k6) → rollout anlarında 5xx (`502`/`503`) kıvılcımları; tuzaklı rollout'takileri varsayılandakilerle karşılaştır. Bu hatalar ingress'ten gelir, `02 · App RED` onları görmez. Fark çıkmayabilir: Kubernetes sonlanan pod'u readiness'tan bağımsız olarak Endpoints'ten düşürüyor — scriptin sonundaki nota bak.

**Aynı kökten üç hata:** readiness'ı TCP kontrolüne indirgemek · `/healthz`'i readiness olarak
kullanmak (kapanışta hayır diyemez — 01'de ayırmıştık) · readiness'a bağımlılık koymak (P02-10).
Hepsi **probe'un ne sorduğunu tanımlamamaktan** doğuyor.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_LIST_N_PLUS_ONE` | Liste yanıtında link başına stats sorgusu | `make repro P=P07-06` | Bayrağı kapat; toplu sorgu |
| `TRAP_READY_ALWAYS` | readiness sabit 200 | `make repro P=P07-08` | Bayrağı kapat |
| `TRAP_COMMIT_BEFORE_WRITE` · `TRAP_NO_DLQ` · `TRAP_COMMIT_DELAY_MS` | (06'dan devam) | 06'da | — |

Elle denemeye değer:
- `kubectl -n lvl07 patch hpa redirect --type=json -p '[{"op":"replace","path":"/spec/behavior/scaleUp/stabilizationWindowSeconds","value":60}]'`
  sonra P07-01'i tekrar koş: ölçek-büyütmeyi yavaşlatmanın bedelini ölç.
- `rpk topic add-partitions clicks -n 6` sonra `make load S=hot-key` ile KEDA'nın tüketiciyi
  gerçekten ölçekleyebildiğini gör (P06-03 tavanı kalkınca KEDA anlam kazanır).
- api-svc'ye HPA ekle ve `make load S=create` koş: yazma yolunu ölçeklemenin DB'ye etkisi,
  okuma yolunu ölçeklemekten **farklıdır** (yazma replikaya dağıtılamaz).
- `DB_MAX_CONNS=2` yap ve `stairs` koş: havuzu küçültmek P07-02'yi çözmez, kuyruğu uygulamaya taşır
  (P02-06'nın aynısı). *Bir kaynağı paylaşan iki taraf varsa, sınırı tek taraftan koymak işe yaramaz.*

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl07&from=now-15m&to=now) | **Dolu** ✨ | HPA desired/current, Pending pod, node kapasitesi, KEDA scaler değeri |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl07&from=now-15m&to=now) | Dolu — **servis bazında** | Artık `redirect` ve `api` ayrı pod'lar; panelleri `pod` kırılımıyla oku |
| [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl07&from=now-15m&to=now) · [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl07&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl07&from=now-15m&to=now) · [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl07&from=now-15m&to=now) | Dolu | — |
| [`01 · Pods`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl07&from=now-15m&to=now) → "CPU throttling" | **Boş (ortam sınırı)** | cAdvisor bu kurulumda metriği yayınlamıyor — P07-04'teki nota bak |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl07&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl07&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl07&from=now-15m&to=now) | Boş | — |

Bu seviyede dashboard okuma alışkanlığı değişiyor: tek bir "uygulama" yok artık. `app-red`'e
bakarken `pod` ya da `service` kırılımı olmadan bakmak, iki farklı yük şeklinin ortalamasını
almak demektir — ve ortalama, iki farklı dağılımı gizleyen en iyi araçtır.

## 9. Bilerek bırakılanlar

- **Postgres hâlâ tek ve havuz aritmetiği sınırda** (P07-02 → 09).
- **Redis hâlâ tek** (P04-01 → 14).
- **Tek partition** — KEDA 6 replikaya çıkabilir ama 1 partition tavanı var (P06-03).
- **api-svc'de HPA yok** — trafiği öngörülebilir kabul edildi; bu bir varsayımdır ve yanlış olabilir.
- **Servisler arası çağrı yok** (N+1 tuzağı hariç): 14'te gRPC ile gelecek.
- **Hız sınırı hâlâ süreç içi** ve artık **iki ayrı serviste** — yani P02-04 daha da kötüleşti (08).
- **Kaynak istekleri tahmini**: gerçek profil ölçülmedi; VPA kurulu değil (kapsam dışı).

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 06 ile farkı gösterir:

1. **`cmd/linkly/` SİLİNDİ**, yerine `cmd/redirect-svc/` ve `cmd/api-svc/` geldi. İki `main.go`'nun
   büyük kısmı **aynı** — ve bu kasıtlı: ortak kod `internal/`'da, farklı olan yalnızca hangi
   handler'ın bağlandığı ve hangi ayarların verildiği.
2. **`internal/httpapi/split.go`** (yeni): `RedirectHandler` ve `APIHandler`. Ayrım bir **yönlendirme
   tablosu** meselesi; iş mantığı bölünmedi.
3. **`deploy/redirect-svc.yaml` vs `deploy/api-svc.yaml`**: asıl fark burada.
   Karşılaştırmalı oku — `DB_MAX_CONNS` 6 vs 15, replika 2–12 (HPA) vs sabit 2, CPU limiti var vs yok.
   **Aynı kod, zıt ayarlar.** Tek deployment bu iki ayarı aynı anda taşıyamazdı.
4. **`deploy/keda.yaml`** (yeni): tüketici CPU'ya değil **lag**'e göre ölçekleniyor.
   *Ölçeklemeyi, toplaması en kolay metriğe göre değil, kullanıcıya görünen sorunu kodlayan
   metriğe göre yap.*
5. **`deploy/ingress.yaml`**: yol tabanlı yönlendirme. Dışarıdan hiçbir şey değişmedi — servis
   sınırının doğru çizildiğinin kanıtı.
