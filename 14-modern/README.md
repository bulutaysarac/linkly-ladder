# 14 — modern · "Son hal"

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
  RS & AS -->|L2 ıskası| PGP["pg-pooler-rw/ro"] --> PG[("CNPG: 1 primary + 2 replika")]
  RS ==>|clicks (3 partition)| K[("redpanda")] ==> CN["analytics ×1-3 (KEDA)"]
  CN --> PGP
```

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P13-06 | Enumeration maliyeti / 404 taraması | L1 sayesinde negatif kayıtlar da pod belleğinde: tarama artık Redis'e bile büyük ölçüde ulaşmıyor. *Tam çözüm değil (404 oranına özel limit hâlâ yok) ve README bunu söylüyor.* |

Bunun dışında **kapatılan borçlar** (yeni sorun açmadıkları için tabloya değil buraya yazılı):
P04-02/P04-03 (L1 ile ağ adımı ve hot key), P06-03 (3 partition), P04-06 (`allkeys-lru`).

## 4. Ayağa kaldırma

Platform (tam): `make minimal && make keda && make cnpg && make chaos && make tempo && make argo && make security`

```bash
make up            # build → push → deploy → rollout wait → smoke
curl -s -XPOST http://lvl14.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'
curl -I http://lvl14.localtest.me/<code>
make grafana       # Ladder klasörü, level=lvl14
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make down
```

Yönetim uçları kimlik ister (13'ten beri): `-H 'Authorization: Bearer acme-key-9f2c'`.

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). 13'e göre değişiklik yok.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P14-01 | L1'in kazancı: ağ adımı olmadan isabet | `make repro P=P14-01` | Cache → l1 vs l2; Redis ops | seviye içi |
| P14-02 | **TRAP** her kopya bir kanal borçlanır | `make repro P=P14-02` | Cache → invalidation mesajları | seviye içi (pub/sub + kısa TTL) |
| P14-03 | Partition tavanı kalktı | `make repro P=P14-03` | Stream → lag by partition | seviye içi |
| P14-04 | Kapasite modeli (ölçümle) | `make repro P=P14-04` | App RED → rps/p99 | `docs-capacity.md` |
| P14-05 | **GAME DAY**: üç arıza üst üste | `CONFIRM=1 make repro P=P14-05` | Resilience + SLO | prova |

---

### P14-01 · L1'in geri dönüşü

**Belirti/Kazanç:** Sıcak anahtarlarda p50 düşüyor ve Redis komut sayısı belirgin azalıyor.
**Neden:** En sıcak anahtarlar artık **hiç ağa çıkmıyor** — P04-02'deki RTT ve P04-03'teki tek
çekirdek tavanı bu sayede geç geliyor. [Topic · Konu: Çok katmanlı önbellek]

**Reproduce:** `make repro P=P14-01` — L1 kapalı/açık `hot-key` yükünde p50 ve Redis ops'u karşılaştırır.

**Ama bu "L1 artık bedava" demek değil.** Bedeli bir sonraki maddede.

---

### P14-02 · TRAP · Her kopya bir geçersiz kılma kanalı borçlanır

**Belirti:** Pub/sub açıkken silinen link neredeyse anında her pod'da kayboluyor; kapalıyken
L1 TTL'i boyunca yaşamaya devam ediyor — **03'teki P03-01'in aynısı**.
**Neden:** L1 = gerçeğin N kopyası. 03 bu borcu ödememişti; 14 Redis pub/sub ile ödüyor.
[Topic · Konu: Invalidation broadcast, en-iyi-çaba]

**Reproduce:** `make repro P=P14-02`.

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

**Yeni sınır ve bedeli:** partition başına sıra garantisi var, **global sıra yok** · partition
sayısı **azaltılamaz** · artırma anında mevcut anahtarlar yeni partition'lara taşınır ve o an
için sıra garantisi kırılır. *"Partition artır" bir düğme değil, planlanması gereken bir değişikliktir.*

---

### P14-04 · Kapasite modeli

**Soru:** "100 milyon redirect/gün için ne gerekir?"
**Yöntem:** Tahmin değil ölçüm. Script tek pod kapasitesini `stairs` yüküyle ölçer, sonra modeli
o sayıyla kurar. [Topic · Konu: Kapasite planlaması]

**Reproduce:** `make repro P=P14-04` · tam model: [`docs-capacity.md`](docs-capacity.md)

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

**Bu bir test değil, bir provadır:** amacı geçmek değil, hangi korumanın ne zaman devreye
girdiğini **görmek** ve runbook'u buna göre yazmak. *Tek tek çalışan korumaların birlikte nasıl
davrandığı, ayrı bir sorudur ve yalnızca denenerek öğrenilir.*

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

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

Bu seviyede **hepsi** dolu — merdivenin ilk bakışta en görünür kazancı bu. 00'da yalnızca
`Pods & Resources` ve `k6` doluydu; şimdi 16 dashboard'ın tamamı veri gösteriyor.

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
- **Sürekli profil yok** (P11-08).
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
