# linkly-ladder

> Bir URL kısaltıcının **en ilkel halinden en modern haline 15 basamak**. Her basamak kendi klasöründe,
> tek başına ayağa kalkar, kendi sorunlarını üretir; bir sonraki basamak onları çözer ve yenilerini getirir.
> Hepsi aynı kind cluster'ında koşar, aynı Grafana panellerinden izlenir, aynı komutlarla yönetilir.

System Design Primer'ın "Design Pastebin.com / Bit.ly" problemi. Ayrıntılı plan: [PLAN.md](PLAN.md).

---

## Neden merdiven?

Bir mimari kararı ezberlemekle, o kararı doğuran acıyı yaşamak aynı şey değil. Burada her bileşen
(Redis, Kafka, circuit breaker, canary…) bir önceki seviyede **reproduce edilmiş** bir soruna cevap
olarak gelir. README'de "hangi sorunu çözüyor" satırı boşsa o parça eklenmez.

```bash
cd platform && make minimal      # kind + ingress + Prometheus/Grafana/Loki  (bir kere)
cd ../00-naive && make up        # seviye ayağa kalkar
make repro P=P00-01              # sorunu kendi gözünle gör
make grafana                     # aynı sorunu panelde gör
```

## Tekdüzelik (en önemli kural)

15 seviyenin hepsi **aynı iskelete, aynı Makefile'a, aynı `make up` yoluna, aynı Grafana dashboard'larına,
aynı k6 senaryolarına ve aynı chaos şablonlarına** sahiptir. Seviyeler arasında değişen yalnızca iki şey vardır:

1. **Uygulama kodu** (`cmd/`, `internal/`, `deploy/`)
2. **README'deki adım adım reproduce edilebilir sorunlar** (`problems/PNN-XX.sh`)

Bir seviyeyi öğrendiysen hepsini öğrendin. `tools/lint-skeleton.sh` sapmayı CI'da hata sayar.

| Seviyede olan | Seviyede olmayan (platform/'da tek kopya) |
|---|---|
| `README.md` (10 sabit başlık), `Makefile` (3 satır), `go.mod`, `Dockerfile` (ortak), `cmd/`, `internal/`, `deploy/`, `problems/` | dashboard'lar, k6 senaryoları, chaos şablonları, helm values, cluster kurulumu |

## Merdiven

| # | Klasör | Slogan | Yeni gelen | Getirdiği acı |
|---|---|---|---|---|
| 00 | [`00-naive`](00-naive) | Tek dosya, tek pod, bellek | — | Çöker, unutur, ölçeklenmez, kördür |
| 01 | [`01-hardened`](01-hardened) | Tek süreç ama düzgün | mutex, probe, graceful shutdown, timeout, metrics | Hâlâ unutur ve ölçeklenmez |
| 02 | `02-postgres` | Kalıcılık ve yatay ölçek | Postgres, stateless N replika | Her redirect DB'ye; pool biter |
| 03 | `03-local-cache` | Süreç içi önbellek | LRU + TTL + singleflight | Pod'lar arası tutarsızlık |
| 04 | `04-redis-cache` | Paylaşılan önbellek | Redis cache-aside | Redis SPOF, hot key |
| 05 | `05-async-analytics` | Yazmayı okuma yolundan çıkar | Bounded kuyruk + batch writer | At-most-once kayıp |
| 06 | `06-event-stream` | Olay akışı | Redpanda + consumer | Duplicate, lag, poison |
| 07 | `07-services-autoscaling` | Servisleri ayır | 3 servis, HPA, KEDA | Darboğaz DB'ye kayar |
| 08 | `08-rate-limiting` | Gürültülü komşu | Dağıtık limiter | Limiter'ın kendi bağımlılığı |
| 09 | `09-database-scaling` | DB darboğazı | CNPG, Pooler, PITR | Replikasyon gecikmesi |
| 10 | `10-resilience` | Hata izolasyonu | timeout, retry, breaker, shedding | Ayar karmaşıklığı |
| 11 | `11-observability-deep` | Neden yavaş? | trace, exemplar, SLO, profil | Sampling, kardinalite |
| 12 | `12-delivery` | Güvenli dağıtım | Argo CD, Rollouts canary | Migration/rollback uyumu |
| 13 | `13-security-tenancy` | Kim, neye, ne kadar | JWT, RLS, NetworkPolicy, Kyverno | Operasyonel sürtünme |
| 14 | `14-modern` | Son hal | Redis HA, L1+L2, gRPC, kapasite modeli | "Yolun devamı" listesi |

## Her seviyede aynı komutlar

```
make up        # build → push → deploy → rollout → smoke
make down      # namespace sil
make load S=   # create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=  # PNN-XX sorununu reproduce et  → REPRODUCED / NOT-REPRODUCED
make chaos C=  # pg-delay-2s redis-kill consumer-kill-30s … (make unchaos ile kaldır)
make grafana   # Ladder klasörü, level=lvlNN
make diff-prev # bir önceki seviyeyle fark — merdivenin asıl ders materyali
make verify-prev  # önceki seviyenin sorunları burada çözülmüş mü?
```

## Durum

| Parça | Durum |
|---|---|
| `platform/` (kind 4 node, Calico, ingress, Prometheus, Grafana, Loki, Alloy, 16 dashboard) | ✅ çalışıyor |
| `ladder.mk`, `tools/lint-skeleton.sh`, `tools/newlevel.sh`, `tools/ladder-matrix` | ✅ |
| `docs/` (API kontratı, seviye şablonu, sorun şablonu, ADR'ler) | ✅ |
| `00-naive` + 10 reproduce scripti | ✅ hepsi gerçek cluster'da doğrulandı |
| `01-hardened` + 8 reproduce scripti + birim testler | ✅ kod/deploy/README hazır, doğrulama sürüyor |
| `02-postgres` … `14-modern` | ⏳ sırada |

## Kurulum

```bash
brew install kind helm k6 kustomize jq
# Docker Desktop: 6 CPU / 10 GB (Settings → Resources)
cd platform && make minimal
```

Kurumsal ağdaysan (Cloudflare Gateway / Zscaler gibi TLS araya girmesi) `make cluster` adımı kök CA'yı
otomatik olarak node'lara kurar (`platform/kind/trust-ca.sh`); olmadan image çekilemez.
