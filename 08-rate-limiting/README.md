# 08 — rate-limiting · "Gürültülü komşu"

> **Bu seviyede ne yaşayacaksın?**
> - Hız sınırının Redis'teki paylaşılan bir sayaca taşınmasıyla limitin replika sayısından bağımsız olması (P01-05 → P02-04 borcu kapanır)
> - Limiter'ın kendi bağımlılığı: Redis ölünce istekler geçsin mi, reddedilsin mi? (P08-01); her isteğe iki ağ çağrısı (P08-02)
> - Tuzak: `X-Forwarded-For`'u yanlış okumanın iki yolu — başlığı yazan herkesin limiti aşması ya da bütün istemcilerin tek IP sanılması (P08-03)
> - Sabit pencere sınırında 2× burst (P08-04); tuzak: global anahtarın Redis hot key olması (P08-05); gürültülü komşunun gerçekten izole edilip edilmediği (P08-06)
>
> **Bu seviye olmasa ne olur?** Süreç içi limit N replikada N katına çıkar ve tek bir kiracı herkesi yavaşlatır.
>
> **Yeni gelen teknolojiler:** Redis üzerinde Lua ile atomik sayaç, kiracı + IP anahtarları, ingress-nginx `limit-rps`, `10 · Rate limit` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Hız sınırı süreç belleğinden çıktı: artık Redis'te, tek bir Lua betiğiyle atomik olarak
değerlendirilen **paylaşılan** bir sayaç. Limit, replika sayısından bağımsız hâle geldi (P01-05 →
P02-04 → P07: her seviyede kötüleşen borç burada kapanıyor). İki anahtar var — **kiracı** ve **IP** —
ve ingress'te kaba bir ilk hat. Karşılığında: her isteğe iki ağ çağrısı ve limiter'ın kendi
bağımlılığı.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I["ingress<br/>limit-rps: 400<br/>(kaba ilk hat)"]
  I --> RS & AS
  subgraph RS["redirect-svc × N"]
    M["middleware:<br/>tenant → IP"]
  end
  subgraph AS["api-svc × 2"]
    M2["aynı middleware"]
  end
  M & M2 -->|"EVALSHA (atomik)"| R[("redis<br/>rl:tenant:* · rl:ip:*")]
  RS --> R
```

Katmanlı: ingress **kaba** (yalnızca IP'yi bilir), uygulama **ince** (kiracıyı, ucu, maliyeti bilir).
*Tek katmana güvenmek, ya çok gevşek ya çok sıkı olmak demektir.*

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P07-06 | N+1: liste maliyeti sonuç kümesiyle orantılı | **Çözülmüş SAYILMAZ:** bu bir `TRAP_` alıştırması ve tuzak 08'de de duruyor (varsayılan kapalı). Script tuzağı kendisi açtığı için her seviyede reproduce olur — bu yüzden `SOLVES` dosyasında YER ALMAZ. Kalıcı çözüm 14'te (toplu sorgu / gRPC batch). |

Ama asıl kapanan borç **listede görünmüyor**, çünkü üç seviye boyunca taşındı: P01-05 (süreç içi
limit yanlış), P02-04 (3 replikada 3 katı), P07 (iki serviste ayrı ayrı). Bir sorunu "bir sonraki
seviyede" diye ertelediğinde faizi replika sayısıyla birlikte büyür — `problems/SOLVES` yalnızca
bir önceki seviyeyi kapsadığı için bu borç orada görünmez; **README'nin görevi onu görünür tutmaktır.**

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl08.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl08.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl08 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P08-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

Limit durumunu görmek için:
```bash
kubectl -n lvl08 exec -it $(kubectl -n lvl08 get pod -l app.kubernetes.io/name=redis -o name) -c redis -- redis-cli --scan --pattern 'rl:*' | head
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Yeni yanıt başlıkları: `429` durumunda `Retry-After`, `X-RateLimit-Limit` ve **`X-RateLimit-Scope`**
(`ip` mi `tenant` mı reddetti). *Bir client'a "ne zaman tekrar dene" demeyen bir limit, onu daha
agresif denemeye iter: sınırlama, iletişim kurmayı gerektirir.*

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P08-01 | Limiter'ın kendi bağımlılığı: fail-open mı closed mı | `CONFIRM=1 make repro P=P08-01` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Sınırlayıcı arka uç hatası / sn" | karar + alarm (11) |
| P08-02 | Her isteğe +2 Redis gidiş-gelişi | `make repro P=P08-02` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Kararlar (anahtar türüne göre)" | seviye içi (pipeline) |
| P08-03 | **TRAP** XFF: adaletsiz mi, etkisiz mi? | `make repro P=P08-03` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Kararlar (anahtar türüne göre)" | seviye içi |
| P08-04 | Sabit pencere sınırında 2× burst | `make repro P=P08-04` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Kararlar (anahtar türüne göre)" | seviye içi (kayan pencere) |
| P08-05 | **TRAP** global anahtar = Redis hot key | `make repro P=P08-05` | [06 · Redis](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Redis CPU" | seviye içi (parçalama) |
| P08-06 | Gürültülü komşu izole ediliyor mu? | `make repro P=P08-06` | [10 · Rate limit](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl08&from=now-15m&to=now&refresh=10s) → "Normal ve kötü niyetli kullanıcının gecikmesi (k6)" | 13 (tier kotaları) |

---

### P08-01 · Limiter'ın kendi bağımlılığı

**Belirti:** Redis durdurulduğunda, `RATE_LIMIT_FAIL_OPEN=true` ile hizmet sürer ama **koruma
kalkar**; `false` ile koruma çalışır ama **herkes reddedilir**.
**Neden:** Korumayı paylaşılan duruma taşıdın; artık koruma da arızalanabilir.
[Topic · Konu: Fail-open/closed, bağımlılık zinciri]

**Reproduce:** `CONFIRM=1 make repro P=P08-01` — normal, fail-open ve fail-closed davranışını
sırayla ölçer.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) — üç faz var (normal, fail-open, fail-closed), ~4 dk; scripti başlatınca aç (giriş: admin / ladder)
- "Sınırlayıcı arka uç hatası / sn" → normal fazda 0; Redis durduğu anda sıfırın üstüne çıkar ve iki Redis'siz fazda da orada kalır: her limit kontrolü başarısız.
- "Reddedilen / sn" → normal fazda sıfırdan büyük (kötü client limitleniyor); fail-open fazında aynı kötü client koşarken **0'a düşer** — koruma kalktı; fail-closed fazında yeniden yükselir, bu kez herkes için.
- "Kararlar (anahtar türüne göre)" → fail-open fazında kararlar `allow` olarak sayılmaya devam eder: hata/s paneline bakmazsan her şey normal görünür (alarmın neden şart olduğu bu). Fail-closed fazında retler `tenant reject` olarak görünür — ilk kontrol kiracıdır ve Redis yokken orada düşer.
- "429 oranı" → fail-closed fazında neredeyse 1'e (%100) çıkar: normal kullanıcılar da reddediliyor.
- "Redis ayakta mı" (Redis) → 0'a inmez, **kesilir**: exporter Redis pod'unda yan konteyner; pod gidince ölçen de gider.

**Seçim ve gerekçesi:** fail-open **+ alarm**. Korumayı kaybetmek telafi edilebilir (kötü client
bir süre geçer); hizmeti kaybetmek edilemez. Ama bu seçim bir **borç** yaratır: *"limiter devre
dışı" alarmı olmak zorunda*, yoksa korumasız kaldığını fark etmezsin — 11'de bu alarm SLO'lardan
türeyecek. Azaltma: yerel, daha gevşek bir yedek limiter (koruma tamamen kalkmasın, gevşesin).
**Üçüncü seçenek "hiç düşünmemek"tir** ve o zaman kararı kütüphanenin varsayılanı verir.

---

### P08-02 · Her isteğe iki ağ çağrısı

**Belirti:** Limit kontrolü isteğin gecikmesinin ölçülebilir bir yüzdesini alıyor.
**Neden:** 07'de bellekteki bir map'ti (~100 ns); şimdi kiracı + IP için iki Redis çağrısı.
[Topic · Konu: Doğruluk/gecikme takası]

**Reproduce:** `make repro P=P08-02` — `ratelimit_check_duration_seconds` ile toplam istek süresini
ve istek başına Redis komut sayısını karşılaştırır (beklenen ~3: 1 önbellek + 2 limit).

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s), [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl08&from=now-15m&to=now&refresh=10s) — yük 40 sn; bittikten sonra aç (giriş: admin / ladder)
- Explore'da: `histogram_quantile(0.5, sum(rate(ratelimit_check_duration_seconds_bucket{namespace="lvl08"}[2m])) by (le))` → tek bir limit kontrolünün p50'si. Kontrol süresini çizen bir panel **yok** (script de bu metriği Prometheus'tan sorgulayarak okuyor); bunu App RED'deki "Gecikme (p50 / p95 / p99)" panelinin `p50` çizgisiyle karşılaştır — izin verilen bir istek bu kontrolden iki tane yapar.
- "Kararlar (anahtar türüne göre)" → her istek iki karar üretir: `tenant allow` çizgisi ile `ip allow` + `ip reject` toplamı aynı hızda ilerler. "Her isteğe iki ağ çağrısı" bu iki çizgidir.
- "Komut / sn" (Redis) → App RED'deki "Saniyedeki istek" değerine böl: istek başına Redis komutu. Geçen istek için ~3 (1 önbellek + 2 limit); reddedilen istek önbelleğe hiç gitmez — kiracıda reddedilen 1, IP'de reddedilen 2 komut yapar — bu yüzden yük limiti aştığında oran 3'ün altına düşer.

**Azaltma:** pipeline ile tek gidiş-gelişte iki kontrol · pod'da kısa ömürlü token tamponu
(doğruluktan ödün) · ucuz reddi ingress'e bırakmak. *Sıcak yolda yapılan her "küçük" kontrol
p50'ye doğrudan eklenir.*

---

### P08-03 · TRAP · X-Forwarded-For'u yanlış okumanın iki yolu

| Yanlış | Sonuç |
|---|---|
| `TRAP_IGNORE_XFF` — soket adresini oku | Herkes ingress IP'sinde **tek kovada**: bir kötü client herkesi limitler → **adaletsiz** |
| `TRAP_TRUST_ANY_XFF` — ilk girdiye güven | Client kendi kovasını seçer → limit **isteğe bağlı**, yani **etkisiz** |
| **Doğru** — sağdan `TRUSTED_PROXY_HOPS` kadar geri say | Yalnızca kendi proxy'nin eklediğine güven |

**Neden:** XFF, client'ın başlatabildiği bir listedir. Güvenilir tek kısmı **senin** proxy'lerinin
eklediğidir. [Topic · Konu: Güven sınırı]

**Reproduce:** `make repro P=P08-03` — üç modu (doğru, `TRAP_IGNORE_XFF`, `TRAP_TRUST_ANY_XFF`) aynı
`abuser` yüküyle koşar ve her fazda limiter'ın Redis'te açtığı IP kovalarını (`rl:ip:<adres>:…`) ve
kimin sınırlandığını ölçer.
  - **Topoloji:** k6'nın bütün sanal client'ları gerçekte tek makineden, yani **tek adresten** gelir;
    yayındaki `TRUSTED_PROXY_HOPS=1` ile doğru mod ve `TRAP_IGNORE_XFF` ayırt edilemez (ikisinde de
    tek kova). Bu yüzden k6 ingress'in önündeki güvenilir yük dengeleyiciyi oynar: her client'ın
    adresini XFF'e yazar (kötü `203.0.113.66`, normal `198.51.100.<n>`) ve deney boyunca uygulamaya
    `TRUSTED_PROXY_HOPS=2` denir. Kötü client her isteğin **önüne** yeni bir sahte adres ekler
    (`198.18.x.y`): doğru okuyucu onu hiç görmez, ilk girdiye güvenen okuyucu ona kanar.
  - **XFF'in uygulamaya ulaşması** ingress-nginx'in ConfigMap ayarıdır, Ingress annotasyonu değil:
    [`platform/manifests/ingress-nginx-config.yaml`](../platform/manifests/ingress-nginx-config.yaml)
    (`make -C ../platform core` uygular). Doğru modda iki client ayrı kovada değilse script hüküm
    vermez (exit 2).
  - **Hüküm:** ignore-xff'te tek kova (ingress'in adresi) ve normal client'ın belirgin biçimde
    sınırlanması (**adaletsiz**) + trust-any-xff'te kötü client'ın her istekte yeni kova açıp IP
    limitinden kaçması (IP reddi doğru modun onda birinin altına iner: **etkisiz**).

Birim test: `internal/httpapi/clientip_test.go`. Kovaları kendin gör:
`kubectl -n lvl08 exec $(kubectl -n lvl08 get pod -l app.kubernetes.io/name=redis -o name) -c redis -- redis-cli --scan --pattern 'rl:ip:*'`

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl08&from=now-15m&to=now&refresh=10s) — üç faz var (doğru, `TRAP_IGNORE_XFF`, `TRAP_TRUST_ANY_XFF`), her biri 40 sn `abuser` (giriş: admin / ladder)
- "Kararlar (anahtar türüne göre)" → üç tümsek, her mod için bir tane. Doğru ve ignore-xff fazlarında `ip reject` belirgin; trust-any-xff fazında `ip reject` neredeyse **sıfıra** iner — kötü client her istekte yeni bir kova seçiyor — ama `tenant reject` sürer: kiracı limiti adresle ilgilenmez.
- "Dönen durum kodları" (k6) → `302` ignore-xff fazında en düşük seviyesinde (normal client'ın istekleri de tek kovada reddediliyor), trust-any-xff fazında en yüksek seviyesinde (kötü client'ın istekleri IP limitinden geçiyor). `503` ingress'in kaba sınırıdır (`limit-rps`), uygulamanın değil: [Grafana'yı okumak](../README.md#grafanayı-okumak).
- "Normal ve kötü niyetli kullanıcının gecikmesi (k6)" → gecikmede büyük fark bekleme: 429 hızlı bir cevaptır. Fark **kimin** reddedildiğinde; normal client'ın sınırlanan payını script her faz için basar.
- Explore'da: `k6_normal_client_limited_rate{level="lvl08"}` → normal client'ın sınırlanan payı (0–1): ignore-xff fazında yükselir, diğer iki fazda sıfıra yakın.

**Ders:** İki hata da *"XFF'i okuduk"* diye rapor edilir; fark **hangi girdiyi** okuduğundadır.
Güven sınırını yazıya dök: kaç proxy var, hangisi senin? Gerisi **veridir, kanıt değil**.

---

### P08-04 · Sabit pencere sınırında 2× burst

**Belirti:** Sabit pencere sayacıyla, iki pencerenin sınırında limitin iki katı geçer.
**Neden:** 10 sn'lik pencerede 300 limit varsa, 9.9. saniyede 300 ve 10.1. saniyede 300 daha →
0.2 saniyede 600. [Topic · Konu: Pencere algoritmaları]

**Reproduce:** `make repro P=P08-04` — pencere sınırına denk gelen burst'te kabul edilen tepe hızı ölçer.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) — iki faz var (kayan, sonra sabit pencere), her biri ~70 sn `burst`; tek `redirect` pod'u ve geçici IP limiti (`LIM_TEST`, varsayılan 60 / 10 sn) (giriş: admin / ladder)
- "Kararlar (anahtar türüne göre)" → iki fazda da `ip reject` sıfırdan büyük olmalı: yük limiti aşıyor, deneyin ön koşulu bu (0 ise script "eksik ölçüm" der). `ip allow` iki fazda da limite yakın (≈6/s), neredeyse aynı düz çizgidir.
- "Sınırdan geçen istek / sn (10 sn çözünürlük)" → büyük olasılıkla **boş ya da kesik kesik**: panel `rate(...[10s])` kullanıyor, uygulama ise 10 sn'de bir kazınıyor ve `rate()` pencerede iki örnek ister.
- Pencere sınırındaki 2× taşma 1 sn'den kısa sürer; Prometheus 10 sn'de bir kazıdığı için hiçbir panelde görünmez, ortalamaya karışır. Kanıt terminalde: script pod'un `/metrics` ucunu saniyede bir okur ve 10 sn'lik en yoğun aralıkta kabul edilen istek sayısını iki mod için ayrı basar.

**Çözüm (uygulanmış):** kayan pencere sayacı — önceki pencerenin sayımı, mevcut pencerede ne kadar
ilerlediğine göre **ağırlıklandırılır** (`internal/ratelimit/redis.go`'daki Lua).
**Alternatifler:** sliding window **log** (her isteğin zaman damgası — kesin ama pahalı) ve
**token bucket** (patlamaya izin verir, ortalamayı korur). Seçim şu soruyla yapılır: *burst'e izin
var mı?*

---

### P08-05 · TRAP · Global anahtar = Redis hot key

**Belirti:** "Tüm sistem için saniyede N istek" kuralı (tek global anahtar) açıldığında limitin
**tavanı** tek bir Redis çekirdeği olur: pod eklemek bu tavanı yükseltmez. Bu kümenin yükünde
uygulama tarafındaki fark (limit kontrolü süresi, Redis CPU) küçüktür — sorun bir yavaşlama değil,
henüz çarpmadığın bir tavandır.
**Neden:** Her istek **tek** bir Redis anahtarına yazar; Redis komutları tek iş parçacığında çalıştırır.
[Topic · Konu: Hot key, paylaşılan sayaç]

**Reproduce:** `make repro P=P08-05` — önce tavanı **doğrudan** ölçer: Redis pod'unun içinde
`redis-benchmark` ile 100 bin anahtara dağılmış ve TEK anahtardaki `INCR` tavanı. İkisi yakınsa sınır
anahtarda değil instance'tadır, yani global limit tek çekirdeğe ölçeklenir — hüküm budur. Ardından
dağıtık anahtar ve `TRAP_GLOBAL_LIMIT` modlarını 40'ar sn uygulama yüküyle koşup limit kontrolü p99'unu
ve Redis CPU'sunu yan yana basar; bu fark bilgi içindir, hükme girmez (uygulama tavanın çok altında).

**Grafana'da gör:** [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) — önce tavan ölçümü, sonra iki 40 sn'lik yük fazı (dağıtık, global) (giriş: admin / ladder)
- "Redis CPU" → önce kısa ve yüksek bir tepe: `redis-benchmark` Redis pod'unun **içinde** tavanı ölçüyor. Ardından iki benzer tümsek (dağıtık ve global faz); aralarındaki fark küçüktür — uygulama bu tavanın çok altında çalışıyor (scriptin son notu: "henüz oraya gelmedin").
- "Komutlar (türe göre)" → benchmark sırasında `incr` tepesi; yük fazlarında `evalsha`. Global fazda `evalsha` artar: her istek artık bir kontrol daha yapıyor (global + kiracı + IP).
- "Kararlar (anahtar türüne göre)" (Rate limit) → `global allow` / `global reject` serileri yalnızca tuzak fazında belirir: her istek aynı tek anahtara yazıyor.

**Çözüm:** anahtarı **parçala** (`global:0..15`, rastgele seç, limiti 16'ya böl) — kesinlikten biraz
ödün, sıcak anahtardan kurtuluş.
**Aynı fizik, üçüncü kez:** 02'de DB satırı (P02-08), 04'te önbellek anahtarı (P04-03), şimdi limit
sayacı. *Paylaşılan durumda "tek sayaç" istemek, tek bir CPU çekirdeğine ölçeklenmek demektir.*

---

### P08-06 · Gürültülü komşu izole ediliyor mu?

**Belirti/Beklenti:** Kötü client 429 yer, normal client'ın p99'u bozulmaz.
**Neden bu seviyenin asıl sorusu:** Hız sınırının amacı kapasiteyi korumak **değil**, **adaleti**
korumaktır. [Topic · Konu: Adalet, izolasyon]

**Reproduce:** `make repro P=P08-06` — `abuser` senaryosu (1 açgözlü + N normal client). P08-03'teki
gibi k6 güvenilir yük dengeleyiciyi oynar ve deney boyunca uygulamaya `TRUSTED_PROXY_HOPS=2` denir;
yoksa tek makineden gelen bütün client'lar aynı IP kovasında olur, normal client da reddedilir ve
izolasyon ölçülemez ("izole edildi" hükmü o zaman anlamsızdır). Kötü ve normal
client'ın sınırlanan paylarını (429 ya da ingress 503), IP/kiracı retlerini ve normal client p99'unu
raporlar. Hüküm: kötü client'ın en az %30'u sınırlanır **ve** normal client'ın %5'ten azı.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl08&from=now-15m&to=now&refresh=10s) — `abuser` 60 sn sürer; başlatınca aç (giriş: admin / ladder)
- "Normal ve kötü niyetli kullanıcının gecikmesi (k6)" → `normal kullanıcı p99` düşük ve düz kalır: normal client'ın deneyimi bozulmuyor. `kötü niyetli kullanıcı p99` çizgileri de düşüktür — 429 hızlı bir cevaptır, kötü client kaynak tüketemiyor.
- "Kararlar (anahtar türüne göre)" → `ip reject` belirgin biçimde yükselir (kötü client'ın kovası); kötü client uygulamaya saniyede 200'den fazla istek ulaştırdığı için pencere başına kiracı limitini (`RATE_LIMIT_PER_TENANT`, 2000 / 10 sn) de aşar ve `tenant reject` de görünür.
- "429 oranı" → sıfırın belirgin biçimde üstüne çıkar.
- "Dönen durum kodları" (k6) → `429` baskın, yanında `302`. `503`, kötü client'ın ingress'in kaba sınırını (`limit-rps`, 400/sn) aşmasıdır: ingress de client'ları XFF'teki güvenilir adrese göre ayırıyor, normal client 503 almaz ([Grafana'yı okumak](../README.md#grafanayı-okumak)).
- Explore'da: `k6_normal_client_limited_rate{level="lvl08"}` → normal client'ın sınırlanan payı (0–1): sıfıra yakın kalmalı.

**İki anahtarın rolü farklı:** IP limiti tek bir saldırganı; kiracı limiti bir müşterinin **tüm
altyapısını** (birçok IP) sınırlar. Yalnızca IP'ye bakmak dağıtık bir client'ı görmez.
**Eksik kalan:** müşteriye göre farklı kotalar (tier). Onun için önce **kimlik** gerekir → 13.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_IGNORE_XFF` | XFF'i yok sayar (herkes tek kovada) | `make repro P=P08-03` | Bayrağı kapat |
| `TRAP_TRUST_ANY_XFF` | XFF'in ilk girdisine güvenir | `make repro P=P08-03` | Bayrağı kapat |
| `TRAP_GLOBAL_LIMIT` | Tek global anahtar kullanır | `make repro P=P08-05` | Bayrağı kapat / parçala |
| `TRAP_FIXED_WINDOW` | Kayan pencere yerine sabit pencere sayacı (sınırda 2× burst) | `make repro P=P08-04` | Bayrağı kapat (kayan pencere) |
| `TRAP_LIST_N_PLUS_ONE` · `TRAP_READY_ALWAYS` | (07'den devam) | 07'de | — |

Elle denemeye değer:
- `RATE_LIMIT_PER_IP=20` yap ve normal tarayıcıyla gez: kendi limitini yemek, limitin kullanıcıya
  nasıl hissettirdiğini anlamanın en hızlı yolu. `Retry-After` başlığına bak.
- `RATE_LIMIT_WINDOW=60s` yap: uzun pencere daha adil ama daha az tepkisel; kısa pencere tersi.
  **Pencere uzunluğu, "ne kadar hızlı tepki verelim" ile "ne kadar adil olalım" arasındaki düğmedir.**
- Ingress limitini kaldır (`limit-rps` annotasyonunu sil) ve `abuser` koş: uygulamaya ulaşan
  istek sayısındaki farkı ölç. *Reddedilen en ucuz istek, hiç gelmeyen istektir.*
- İki servisi karşılaştır: `make load S=create` ile api-svc'yi zorla. Aynı limitler her iki
  serviste de geçerli — çünkü sayaç paylaşımlı. 07'de olsaydı iki ayrı limit olurdu.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl08&from=now-15m&to=now) | **Dolu** ✨ | `decision` × `key_type` kırılımı, limiter hataları. Kontrol süresinin paneli **yok**: Explore'da `ratelimit_check_duration_seconds` (P08-02) |
| [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl08&from=now-15m&to=now) | Dolu | Artık hem önbellek hem limiter aynı Redis'te — **komut dağılımına bak** |
| [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl08&from=now-15m&to=now) · [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl08&from=now-15m&to=now) · [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl08&from=now-15m&to=now) · [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl08&from=now-15m&to=now) | Dolu | — |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl08&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl08&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl08&from=now-15m&to=now) | Boş | — |

Yeni okuma alışkanlığı: `ratelimit_decisions_total`'a **yalnızca toplam** olarak bakmak yanıltır.
`key_type` kırılımı olmadan "çok 429 var" cümlesi eyleme dönüşmez — IP mi kiracı mı reddetti,
tamamen farklı iki sorun.

## 9. Bilerek bırakılanlar

- **Redis hem önbellek hem limiter** — tek arıza noktası iki işi birden düşürür (P08-01 → 14'te ayrı örnek).
- **Kimlik yok**: kiracı hâlâ `X-Tenant-ID` header'ından. Tier kotaları için gerçek kimlik şart (13).
- **Sabit kotalar**: her kiracıya aynı limit. Gerçekte müşteri planına göre değişir.
- **Ingress limiti kaba**: yol/metot ayrımı yok — `POST /api/links` ile `GET /{code}` aynı kovada.
- **404 taramasına özel limit yok**: enumeration için ayrı bir kural gerekir (13, P13-06).
- **Yerel yedek limiter yok**: Redis düşünce koruma tamamen kalkıyor (P08-01'in azaltması).
- **07'den devreden**: tek Postgres + havuz aritmetiği (09), tek partition (06), tek Redis (14).

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 07 ile farkı gösterir:

1. **`internal/ratelimit/redis.go`** (yeni): asıl ders **Lua betiğinin kendisi**. Neden client
   tarafında `GET` + karar + `SET` değil? Çünkü hız sınırlama paylaşılan durumda bir
   oku-değiştir-yaz'dır ve client tarafındaki kontrol **yapısı gereği** bir yarıştır.
   *Limit, her pod'un ayrı ayrı sahip olduğu bir kanaat olmaktan çıkıp bir olgu hâline geliyor.*
2. **`internal/httpapi/clientip.go`** (yeni): 20 satır kod, üç farklı güvenlik sonucu. Yorumlarda
   üç seçeneğin tablosu var. Bir isteğin tek bir istemci kimliği vardır (`server.go · API.clientIP`):
   dağıtık limiter, süreç içi yedek limiter ve access log'un `ip` alanı aynı adresi kullanır —
   logdaki bir 429, onu üreten kovayı gösterir.
3. **`internal/ratelimit/ratelimit.go` DURUYOR**: süreç içi limiter silinmedi, **yedek** olarak
   kaldı. Bu kararsızlık değil — testlerin ve Redis'siz çalıştırmanın sürmesini sağlıyor ve
   dağıtık limiter'ın bir **yükseltme** olduğunu belgeliyor.
4. **`deploy/ingress.yaml`**: `limit-rps` — iki katmanlı savunmanın ucuz yarısı burada.
   X-Forwarded-For davranışı ise burada DEĞİL, controller ConfigMap'inde:
   [`platform/manifests/ingress-nginx-config.yaml`](../platform/manifests/ingress-nginx-config.yaml).
   `use-forwarded-headers` Ingress annotasyonu olarak var olmayan bir ayardır; ConfigMap'te açık
   değilse ingress client'ın XFF'ini ezer ve bütün k6 client'larını tek IP kovasına toplar (P08-03, P08-06).
5. **`deploy/*-svc.yaml`**: `RATE_LIMIT_PER_IP` artık **pencere başına**, pod başına değil.
   Aynı ortam değişkeni adı, tamamen farklı bir anlam — bu yüzden yorumda açıkça yazıyor.
