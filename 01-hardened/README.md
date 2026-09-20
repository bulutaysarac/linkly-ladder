# 01 — hardened · "Tek süreç ama düzgün"

## 1. Bu seviye ne?

00 ile **aynı** tek süreç ve **aynı** bellek içi store — ama çökmesini, yalan söylemesini ve istek
kaybetmesini engelleyen disiplinlerle: kilit, probe, graceful shutdown, timeout'lar, giriş doğrulama,
hız sınırı, metrikler ve yapılandırılmış log. Kalıcılık ve ölçeklenebilirlik hâlâ **yok** — çünkü
onları zorlayan sorunları (P01-01, P01-02) burada ilk kez *ölçebilir* hale getiriyoruz; çözümü 02'de.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress-nginx<br/>lvl01.localtest.me]
  I --> M

  subgraph P["linkly pod × 1"]
    direction TB
    M["middleware zinciri<br/>recover → requestID → accessLog<br/>→ timeout → rateLimit"]
    H["handlers<br/>create · redirect · get · delete"]
    S["store.Memory<br/>RWMutex + CreateUnique"]
    M --> H --> S
  end

  P -.->|/metrics| PR[(Prometheus)]
  P -.->|stdout JSON| LK[(Loki)]
  K[kubelet] -.->|/readyz /healthz<br/>zincirin DIŞINDA| P
```

Zincirin **sırası** tasarımın kendisi: `recover` en dışta (altındaki her katmanın panic'ini yakalar),
`requestID` log'dan önce, `timeout` handler'dan önce ama log'dan sonra, `rateLimit` en sonda
(reddedilen istek iş mantığına hiç ulaşmaz). Sağlık ve metrik uçları **zincirin dışında** — bir trafik
dalgası probe'u düşürüp pod'u öldürmesin diye (bunu bozmak bir alıştırma: `TRAP_LIVENESS_STRICT`).

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P00-01 | Eşzamanlı map yazımı → çökme | `store.Memory` + `sync.RWMutex`; `-race` ile test edilen eşzamanlılık testi |
| P00-04 | Rollout'ta hata dalgası | readiness/liveness probe, `maxUnavailable: 0`, `preStop: sleep 5`, `terminationGracePeriodSeconds: 40` ve **kapatma sırası**: önce readiness düşür → yayılmayı bekle → `Shutdown` |
| P00-05 | 4 karakter kod, sessiz üzerine yazma | `crypto/rand` + 7 karakter + `CreateUnique` (koşullu ekleme) + çakışmada retry + `create_total{result="collision"}` |
| P00-06 | Doğrulama yok | Şema allowlist (`http`/`https`), özel/loopback/link-local adres reddi, `MaxBytesReader` (8 KB) |
| P00-07 | Sunucu timeout'u yok | `ReadHeaderTimeout 3s`, `ReadTimeout 10s`, `WriteTimeout 15s`, `IdleTimeout 60s` + istek başına `TimeoutHandler 5s` |
| P00-09 | Gözlemlenebilirlik sıfır | `/metrics` (sayaçlar **sıfırla** pre-register), `slog` JSON + request-id, ServiceMonitor |
| P00-10 | 301 + önbellek kontrolü yok | `302` + `Cache-Control: no-store` |

`problems/SOLVES` aynı listeyi makine-okunur tutar; `make verify-prev` bu iddiayı **00'ın kendi
scriptlerini burada koşarak** doğrular.

**Çözülmeyenler (bilerek):** P00-02 (kalıcılık → 02), P00-03 (ölçeklenebilirlik → 02), P00-08 (bellek
tavanı → 02/03). Bunlar burada P01-01, P01-02 ve P01-04 olarak, artık **ölçülebilir** biçimde duruyor.

## 4. Ayağa kaldırma

Platform bir kere kurulur (`cd platform && make minimal`). Sonra bu klasörde:

```bash
make up            # build → push → deploy → rollout wait → smoke
curl -s -XPOST http://lvl01.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'
curl -I http://lvl01.localtest.me/<code>
make grafana       # Ladder klasörü, level=lvl01
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyede yeni: `GET /{code}` artık **302** + `Cache-Control: no-store`; `/healthz`, `/readyz`,
`/metrics` uçları var; geçersiz hedefler `400 unsafe_url:<reason>`, büyük gövde `413`, limit aşımı
`429 + Retry-After`.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P01-01 | Restart = tüm linkler gider (artık görünür) | `CONFIRM=1 make repro P=P01-01` | App Business → links_total dikey düşüş | 02 |
| P01-02 | Ölçeklenemez (artık pod bazında görünür) | `CONFIRM=1 make repro P=P01-02` | App Business → redirect 404 by pod | 02 |
| P01-03 | Tek replika + PDB = güvenlik yanılsaması | `CONFIRM=1 make repro P=P01-03` | App RED → 5xx; Pods → Pending | 02 |
| P01-04 | Bellek sınırsız (artık önceden görülür) | `make repro P=P01-04` | Pods → Heap alloc + working set | 02 · 03 |
| P01-05 | Süreç içi limit N replikada N katı | `CONFIRM=1 make repro P=P01-05` | Rate limit → allow by pod | 08 |
| P01-06 | **TRAP** kısa kod label → kardinalite patlaması | `make repro P=P01-06` | App RED → seri sayısı | seviye içi |
| P01-07 | **TRAP** sağlık ucu zincirin arkasında → restart fırtınası | `make repro P=P01-07` | Pods → Restart; Rate limit → reject | seviye içi |
| P01-08 | Tıklama sayacı istek yolunda ve bellekte | `CONFIRM=1 make repro P=P01-08` | App RED → p99 /{code} | 05 · 06 |

---

### P01-01 · Restart = tüm linkler gider — ama artık görünür

**Belirti:** Pod yeniden başlayınca her kısa link 404. 00 ile aynı; fark, artık `links_total`
grafiğinde **dikey bir düşüş** olarak görünmesi.
**Neden:** Mutex çökmeyi durdurdu, kalıcılığı getirmedi. Tek gerçek kaynak hâlâ süreç belleği.
[Topic · Konu: Durum yönetimi, kalıcılık]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P01-01` — 25 link oluşturur, `links_total`'ı okur, pod'u siler, tekrar okur
2. Elle: link oluştur → `kubectl -n lvl01 delete pod -l app.kubernetes.io/name=linkly` → aynı kodu iste → 404

**Grafana:** `03 · App Business` → "links_total" (restartta sıfıra düşer), "redirect sonuçları" → `not_found` sıçraması.
PromQL: `max(links_total{namespace="lvl01"})`
**Nerede çözülüyor:** 02 (Postgres). 01'in kazancı kaybı **ölçebilmek**: 00'da bu grafik yoktu, kaybın
büyüklüğünü söyleyemiyordun bile.

---

### P01-02 · Ölçeklenemez — ama artık pod bazında görünür

**Belirti:** `replicas=3` → aynı link isteklerin ~%66'sında 404.
**Neden:** Her pod'un kendi map'i; Service istekleri dağıtıyor. [Topic · Konu: Stateless servis]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P01-02` — 3 replikaya çıkar, endpoint'lerin yetişmesini bekler, 60 kez okur
2. Script ayrıca **metrikten** aynı gerçeği gösterir: `sum by (pod) (redirect_total{result="not_found"})`

**Grafana:** `03 · App Business` → "redirect 404 by pod" — üç pod, üç ayrı sayaç.
**Nerede çözülüyor:** 02. Not: ölçekledikten sonra Service endpoint'lerinin gerçekten artmasını
beklemek şart; beklemezsen tüm istekler tek pod'a düşer ve yanlış negatif alırsın.

---

### P01-03 · Tek replika + PDB = güvenlik yanılsaması

**Belirti:** Node drain edildiğinde ya drain bloke olur ya da servis kesintiye uğrar. PDB
"minAvailable: 1" diyor ama kimseyi kurtarmıyor.
**Neden:** PDB *gönüllü* kesintilerde en az N pod'un ayakta kalmasını ister. Tek replikada
"ayakta kalacak başka pod" yok: ya budget drain'i engeller ya da pod ölür ve kesinti olur.
Yüksek erişilebilirlik bir nesne değil, bir **yedeklilik** meselesidir. [Topic · Konu: HA, PDB, drain]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P01-03` — yük altında pod'un node'unu drain eder, sonra uncordon eder
2. Script drain çıktısını ve k6'nın gördüğü 5xx sayısını basar

**Grafana:** `02 · App RED` → 5xx; `01 · Pods & Resources` → "Pod fazları" (Pending).
**Nerede çözülüyor:** 02 (3 replika + anti-affinity). PDB'nin kendisi 02'de anlam kazanır.

---

### P01-04 · Bellek hâlâ sınırsız — ama artık önceden görülür

**Belirti:** Link üretimi sürdükçe heap ve working set monoton tırmanır; sonu OOM.
**Neden:** Store'da eviction yok, TTL yok, üst sınır yok. [Topic · Konu: Bounded resources]

**Reproduce (adım adım):**
1. `make repro P=P01-04` — 60 sn link üretir, öncesi/sonrası heap ve `links_total` okur
2. Uzun sürüm: `DURATION=240s URL_SIZE=8000 make repro P=P01-04` → OOMKilled (P00-08'in aynısı, 256Mi limitte)

**Grafana:** `01 · Pods & Resources` → "Heap alloc", "Bellek working set" (limit çizgisiyle).
**Nerede çözülüyor:** 02 (durum DB'de) · 03 (bounded LRU). 01'in kazancı: eğriyi görüp **alarm
yazabilmek** — tavan aynı yerde ama artık çarpmadan önce haberin oluyor.

---

### P01-05 · Süreç içi hız sınırı N replikada N katına çıkar

**Belirti:** "200 rps" yazdın; 3 pod ile client 600 rps geçiriyor. Üstelik dağılım eşit değilse
aynı client bazı pod'larda limitlenip bazılarında geçiyor.
**Neden:** Token bucket her pod'un belleğinde. Limit bir **söz**dür; süreç içinde tutulan söz,
replika sayısıyla çarpılır. [Topic · Konu: Dağıtık durum, hız sınırlama]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P01-05` — limiti 50 rps'e çeker, önce 1 pod sonra 3 pod ile aynı yükü verir
2. Kabul edilen istek sayısını karşılaştırır (beklenen: ~3 kat)

**Grafana:** `10 · Rate limit` → "allow by pod" — üç ayrı kova, üç ayrı sayaç.
**Nerede çözülüyor:** 08 (Redis'te Lua ile atomik, paylaşılan limiter). Orada da yeni bir sorun
doğacak: limiter'ın kendi bağımlılığı düşerse fail-open mı fail-closed mı (P08-01)?

---

### P01-06 · TRAP · Kısa kodu metrik label'ı yapmak

**Belirti:** Metrik eklemek "ücretsiz" sanılır. `short_code` label'ı açıldığında Prometheus'un seri
sayısı link sayısıyla birlikte büyür; sorgular ve Prometheus'un kendisi yavaşlar.
**Neden:** Her farklı label değeri **yeni bir zaman serisi**. Sınırsız değerli alanlar (kısa kod, URL,
IP, tenant id, user id) label olamaz. [Topic · Konu: Kardinalite]

**Reproduce (adım adım):**
1. `make repro P=P01-06` — `TRAP_METRIC_LABEL_CODE=true` açar, 400 farklı kodu ziyaret eder
2. `count(count by (short_code) (http_requests_total{namespace="lvl01"}))` ve
   `prometheus_tsdb_head_series` farkını basar; sonra tuzağı kapatır
3. Route şablonunun (`/{code}`) neden tek bir seri ürettiğini `internal/httpapi/middleware.go:routeOf`'ta gör

**Grafana:** `02 · App RED` → "rps by route" panelinde tek çizgi yerine yüzlerce seri.
**Düzeltme:** Tekil kimlikler metriğe değil **log'a** ve **trace'e** gider (11'de exemplar ile
metrikten trace'e atlayacağız — kardinalite ödemeden).

---

### P01-07 · TRAP · Sağlık uçlarını iş zincirinin arkasına koymak

**Belirti:** Trafik dalgasında pod'lar restart etmeye başlar. Uygulama aslında sağlıklıdır;
öldüren şey **probe'un kendisidir**.
**Neden:** `/healthz` ve `/readyz` iş zincirine (hız sınırı + timeout) dahil edilirse, yük arttığında
probe 429/timeout alır → kubelet konteyneri öldürür → yük kalan pod'lara biner → onlar da ölür.
Yük artışı kendi kendine bir **kesintiye** dönüşür. [Topic · Konu: Probe semantiği, kaskad]

**Reproduce (adım adım):**
1. `make repro P=P01-07` — `TRAP_LIVENESS_STRICT=true` + limiti 30 rps yapar, 60 sn yük verir
2. Restart sayısını ve `Liveness probe failed` olaylarını sayar, sonra tuzağı kapatır
3. Birim test karşılığı: `internal/httpapi/trap_test.go` — tuzak kapalıyken `/healthz` 200, açıkken 429

**Grafana:** `01 · Pods & Resources` → "Restart sayısı"; `10 · Rate limit` → "reject/s".
**Düzeltme (varsayılan):** Sağlık uçları zincirin dışında. Liveness yalnızca "süreç kurtarılamaz mı?"
sorusunu sorar; **bağımlılık kontrolü liveness'a girmez** — aynı tuzağın büyük hâli 10'da (P10-02).

---

### P01-08 · Tıklama sayacı hâlâ istek yolunda ve bellekte

**Belirti:** Her redirect, yanıtı döndürmeden önce paylaşılan bir sayacı kilit altında artırıyor;
pod restart olunca tüm tıklamalar sıfırlanıyor.
**Neden:** Analitik, okuma yolunun içinde ve süreç belleğinde. Bugün ucuz (mutex + RAM), yarın değil.
[Topic · Konu: Asenkronizm, okuma/yazma yolu ayrımı]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P01-08` — 300 tıklama yapar, sayacı okur, hot-key yükünde p99'u ölçer,
   pod'u yeniden başlatır ve sayacın sıfırlandığını gösterir

**Grafana:** `02 · App RED` → "p99 by route" (`/{code}`); `03 · App Business` → "redirect ok/s".
**Nerede çözülüyor:** 05 (bounded kuyruk + batch writer ile istek yolundan çıkar) · 06 (olay akışı
ile dayanıklı olur). Uyarı: 02'de bu mutex bir **DB satır kilidine** dönüşecek ve hot link'te
redirect gecikmesini doğrudan belirleyecek (P02-08).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_METRIC_LABEL_CODE` | Kısa kodu `http_requests_total`'a label olarak ekler | `make repro P=P01-06` | Bayrağı kapat; tekil kimlik log/trace'e |
| `TRAP_LIVENESS_STRICT` | `/healthz` ve `/readyz`'i iş zincirine (limit + timeout) sokar | `make repro P=P01-07` | Bayrağı kapat; sağlık uçları zincirin dışında |

Elle denemeye değer:
- `kubectl -n lvl01 set env deploy/linkly SHUTDOWN_GRACE=1s` → kapatma sırasındaki bekleme penceresini
  yok et, sonra `make repro P=P00-04` (00'ın scriptiyle!) koş: 5xx geri gelir. Graceful shutdown'ın
  hangi parçasının işi yaptığını böyle görürsün.
- `kubectl -n lvl01 set env deploy/linkly HANDLER_TIMEOUT=1ms` → her istek 503; `TimeoutHandler`'ın
  nerede devreye girdiğini logdan izle.
- `make load S=abuser` → tek kötü client'ın normal client'ın p99'una etkisini ölç (08'in ön provası).

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| `00 · Overview` | **Dolu** | Artık availability ve p99 da hesaplanabiliyor |
| `01 · Pods & Resources` | **Dolu** | cAdvisor + KSM + **Go runtime** (goroutine, heap, GC) |
| `02 · App RED` | **Dolu** ✨ | 00'da boştu: `/metrics` yoktu |
| `03 · App Business` | **Dolu** ✨ | `links_total`, `redirect_*`, `create_*`, `create_rejected_unsafe_*` |
| `10 · Rate limit` | **Dolu** (kısmen) | Süreç içi limiter; `key_type="ip"` tek tür |
| `15 · k6` | Dolu | Client tarafı |
| `04 · Cache` | Boş | Cache yok (03) |
| `05 · Postgres` · `06 · Redis` · `07 · Analytics` · `08 · Stream` | Boş | O bileşenler yok |
| `09 · Autoscaling` | Boş | HPA yok (07) |
| `11 · Resilience` · `12 · SLO` · `13 · Rollout` | Boş | 10/11/12'de gelir |
| `14 · Security` | Kısmen | `create_rejected_unsafe_total` dolu; 401/403 yok (13) |

Not: `Pods & Resources` → "CPU throttling" paneli bu ortamda **boş kalır** — kind + Docker Desktop
(cgroup v1) cAdvisor'ı `container_cpu_cfs_throttled_seconds_total` yayınlamıyor. Ortam sınırı,
uygulama sorunu değil; 07'de bu panele ihtiyacımız olacak.

## 9. Bilerek bırakılanlar

- **Store hâlâ bellekte ve tek pod'da.** Kalıcılık, ölçeklenebilirlik, HA yok (P01-01/02/03).
- **Rate limit süreç içi** ve kova map'i sınırsız büyüyor (her yeni IP yeni kayıt). TTL yok (08).
- **URL güvenliği bir azaltma, eliminasyon değil:** özel bir adrese *çözülen* alan adı buradan geçer.
  DNS çözümü ve kalan TOCTOU sınırı 13'te.
- **Tenant yok.** `X-Tenant-ID` gönderebilirsin, hiçbir etkisi yok (13).
- **Analitik istek yolunda ve kalıcı değil** (P01-08 → 05/06).
- **`clientIP` X-Forwarded-For'a körü körüne güveniyor** — spoof edilebilir. Doğrusu yalnızca
  güvenilen proxy hop'undan almak: 08 (P08-03b).
- **Log seviyesi sabit `info`**, log sampling yok — yüksek trafikte Loki'yi zorlar (11, P11-05).

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 00 ile farkı gösterir. Sırayla şuna bak:

1. **`cmd/linkly/main.go`**: 120 satırlık tek dosya, 90 satırlık *bağlantı şemasına* dönüştü. İş
   mantığı `internal/`'a taşındı. En öğretici kısım son yirmi satır: **kapatma sırası** — önce
   readiness düşer, yayılma beklenir, sonra `Shutdown`. Sırayı değiştirip `make repro P=P00-04`
   koşarsan 5xx geri gelir.
2. **`internal/store/memory.go`**: `map` yerine `RWMutex`'li tip ve `CreateUnique`. `CreateUnique`'in
   koşullu ekleme semantiği tesadüf değil: 02'de SQL `UNIQUE`'e birebir çevrilecek.
3. **`internal/httpapi/middleware.go`**: zincirin **sırası** yorumlarda gerekçelendirilmiş.
4. **`deploy/deployment.yaml`**: probe'lar, `maxUnavailable: 0`, `preStop`, `terminationGracePeriodSeconds`,
   `securityContext`. Her satırın yanında hangi P00-XX'i kapattığı yazıyor.
5. **`deploy/servicemonitor.yaml`** (yeni): metrik üretmek yetmez, **toplanması** da gerekir.
6. **`deploy/pdb.yaml`** (yeni): bilerek işe yaramayan bir PDB — P01-03 bunun neden yanılsama
   olduğunu ölçüyor.
