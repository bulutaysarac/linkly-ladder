# linkly-ladder — URL Kısaltıcı Merdiveni

> System Design Primer'ın "Design Pastebin.com / Bit.ly" problemi, **en ilkel halinden en
> modern haline 15 basamakta**. Her basamak kendi klasöründe, kendi başına ayağa kalkar,
> kendi sorunlarını üretir; bir sonraki basamak o sorunları çözer ve yenilerini getirir.
> Tüm basamaklar aynı kind cluster'ında koşar, aynı Grafana'dan izlenir.

---

## 0. Felsefe ve kurallar

Merdivenin amacı "doğru mimariyi öğrenmek" değil, **her mimari kararın hangi acıdan doğduğunu
bizzat yaşamak**. Bu yüzden:

1. **Sorunsuz çözüm yok.** Bir seviyeye eklenen her parça (Redis, Kafka, circuit breaker, canary…)
   bir önceki seviyede *reproduce edilmiş* bir soruna cevaptır. README'de "hangi sorunu çözüyor"
   satırı boşsa o parça eklenmez.
2. **Her seviye tek başına çalışır.** `make up` → 5 dk içinde ingress'ten link kısaltıyorsun.
   Seviye 00 bile.
3. **Her sorunun bir kimliği ve bir reproduce scripti var.** `P03-01` gibi. `problems/P03-01.sh`
   çalıştırılır, sorun gösterilir, Grafana'da hangi panelde göründüğü README'de yazar.
4. **Bir sonraki seviye, önceki seviyenin scriptlerini "artık reproduce edilemiyor" diye koşar.**
   `make verify-prev`. Böylece merdiven kendi regresyon testine sahip olur.
5. **Kod paylaşılmaz, kopyalanır.** Her seviye bağımsız okunabilir bir Go modülü. Seviyeler arası
   fark `make diff-prev` ile okunur — merdivenin asıl ders materyali bu diff'ler.
6. **Tuzaklar bayrakla.** Aynı seviyede hem reproduce hem çözüm gösterilecekse `TRAP_*` env
   bayrağı kullanılır; tuzaklar varsayılan kapalıdır, `make repro` açar.
7. **README Türkçe**, kod yorumları mevcut `linkly` geleneğine uygun (EN + TR, `[Topic · Konu: …]`).
8. **"Bilerek bırakılanlar"** her README'nin son bölümü. Neyi çözmediğini bilmek, çözdüğün kadar değerli.
9. **Tekdüzelik (en önemli kural).** 15 seviyenin hepsi **birebir aynı iskelete, aynı Makefile'a, aynı
   `make up` yoluna, aynı ortama, aynı Grafana dashboard setine, aynı k6 senaryolarına, aynı chaos
   şablonlarına** sahiptir. Seviyeler arasında değişen *yalnızca iki şey* vardır: `internal/` + `cmd/`
   altındaki uygulama kodu (ve onun `deploy/` manifest'leri) ile README'deki **adım adım reproduce
   edilebilir sorunlar**. Bir seviyeyi öğrendiysen hepsini öğrendin; `cd 07-… && make up` ile
   `cd 00-… && make up` aynı hissi verir. Bunu garanti eden mekanizma §1.1'de.

Mevcut `linkly` repo'suna dokunulmaz; kaynak deposu olarak kullanılır (`shortcode`, `cache`,
`ratelimit`, `analytics`, `httpapi/middleware` paketleri 01/03/05/08 seviyelerinin tohumu).
Onun README'sindeki "Deliberate simplifications" listesi bu merdivenin ilk 5 sorunudur.

---

## 1. Dizin yapısı

```
linkly-ladder/                       # tek git repo (github.com/bulutaysarac/linkly-ladder)
├── README.md                        # merdiven haritası + problem matrisi (tools/ladder-matrix üretir)
├── PLAN.md                          # bu dosya
├── go.work                          # IDE için; build Makefile'da modül döngüsüyle
├── Makefile                         # build/test/lint tüm seviyeler; matrix; docs
├── .github/workflows/ci.yml         # her modül: vet/test/race + image build + kind smoke (opsiyonel)
├── docs/
│   ├── LEVEL-TEMPLATE.md            # seviye README şablonu (bkz. §5)
│   ├── PROBLEM-TEMPLATE.md          # tek sorun kaydı şablonu
│   ├── API.md                       # tüm seviyelerde sabit API kontratı
│   └── adr/                         # karar kayıtları (Redpanda vs Strimzi, CNPG ne zaman, …)
├── platform/                        # paylaşılan altyapı — §2
├── tools/
│   ├── ladder-matrix/               # tüm problems/*.sh'yi tüm seviyelere koşup matrisi üretir
│   └── newlevel.sh                  # NN-name klasörünü bir öncekinden kopyalayıp modül adını değiştirir
├── 00-naive/
├── 01-hardened/
├── 02-postgres/
├── 03-local-cache/
├── 04-redis-cache/
├── 05-async-analytics/
├── 06-event-stream/
├── 07-services-autoscaling/
├── 08-rate-limiting/
├── 09-database-scaling/
├── 10-resilience/
├── 11-observability-deep/
├── 12-delivery/
├── 13-security-tenancy/
└── 14-modern/
```

### 1.1 Seviye iskeleti — 15 seviyede birebir aynı

```
NN-name/
├── README.md                        # docs/LEVEL-TEMPLATE.md ile aynı başlıklar, aynı sırada
├── Makefile                         # 3 satır: LEVEL=NN, NAME=name, include ../ladder.mk  — başka hiçbir şey
├── go.mod                           # module github.com/bulutaysarac/linkly-ladder/NN-name
├── Dockerfile                       # tüm seviyelerde aynı dosya (ARG SVC ile cmd/$SVC derler)
├── cmd/<svc>/main.go                # 00–06: sadece cmd/linkly · 07+: cmd/{redirect,api,analytics}
├── internal/…                       # DEĞİŞEN ŞEY 1: uygulama kodu
├── deploy/
│   ├── kustomization.yaml           # her seviyede aynı ad; ladder.mk `kubectl apply -k deploy/` yapar
│   └── *.yaml                       # DEĞİŞEN ŞEY 1 (devamı): bu seviyenin manifest'leri
└── problems/
    ├── PNN-XX.sh                    # DEĞİŞEN ŞEY 2: adım adım reproduce scriptleri
    └── README-section.md            # (opsiyonel) --explain için README'den kesit
```

**Seviyede olmayanlar (bilerek):** kendi Makefile hedefleri, kendi dashboard'ları, kendi k6
senaryoları, kendi chaos YAML'ları, kendi helm chart'ı. Hepsi `platform/`'da tek kopya.
`tools/newlevel.sh NN name` bir önceki seviyeyi kopyalar, modül adını ve `LEVEL`'i değiştirir;
`tools/lint-skeleton.sh` her seviyenin iskeletini şablonla karşılaştırır (CI'da koşar — sapma = hata).

**`ladder.mk` (kökte, tek kopya):** seviye Makefile'larının tamamı buradan gelir.
- `up`: `cmd/*` altındaki her servisi derler → `localhost:5001/linkly-ladder/NN-<svc>:<sha>` → `kubectl apply -k deploy/`
  (namespace `lvlNN`, host `lvlNN.localtest.me`) → `rollout status` → smoke (`POST` + `GET` 302) → Grafana linkini basar.
- `down`, `load S=`, `repro P=`, `chaos C=`, `unchaos`, `grafana`, `logs`, `diff-prev`, `verify-prev`, `test`, `lint`.
- Seviye özel iş gerekiyorsa (`09`'da CNPG Cluster beklemek gibi) o iş `deploy/` içindeki manifest'lere
  ve kustomize'ın kendisine (`wait` annotasyonları, Job'lar) sığdırılır — Makefile'a değil.

**Namespace:** `lvlNN`. **Ingress host:** `lvlNN.localtest.me` (127.0.0.1'e çözülür, Chrome'da da çalışır).
**Image:** `localhost:5001/linkly-ladder/NN-<svc>:<git-sha>` (kind local registry).
**Deploy aracı:** her seviyede kustomize (`kubectl apply -k`). 12'de Argo CD / Rollouts *sorun konusu* olarak
gelir; `make up` yolu yine kustomize'dır (Rollout CR'si de `deploy/` içindeki bir YAML'dır).

---

## 2. Platform (paylaşılan altyapı)

```
platform/
├── Makefile                         # cluster | registry | core | obs | data | chaos | delivery | security | destroy
├── kind/
│   ├── cluster.yaml                 # 1 control-plane + 3 worker, disableDefaultCNI (Calico), 80/443 port map, registry mirror
│   └── registry.sh                  # localhost:5001 (kind resmi tarifi)
├── manifests/                       # calico, ingress-nginx (kind varyantı), metrics-server (--kubelet-insecure-tls)
├── helm/                            # her bileşen için values.yaml (kaynakları Mac'e göre kısılmış)
├── dashboards/                      # TEK dashboard seti, tüm seviyeler için — §2.5
├── k6/
│   ├── lib/                         # base url, tag=level, ortak check'ler, senaryo yardımcıları
│   └── scenarios/                   # create · redirect · mixed · hot-key · burst · abuser · read-your-writes · stairs · scan
├── chaos/                           # NetworkChaos/PodChaos/StressChaos şablonları (NS parametreli) — tüm seviyeler
└── profiles/                        # minimal / standard / full — hangi bileşen kurulur
```

### 2.1 Bileşenler ve ilk ihtiyaç duyulan seviye

| Bileşen | Kaynak | İlk seviye | Neden |
|---|---|---|---|
| kind (4 node) + Calico | `kind`, Calico manifest | 00 | Çoklu node: drain/node-freeze deneyleri; Calico: 13'te NetworkPolicy için cluster'ı yeniden kurmamak |
| Local registry | kind tarifi | 00 | `kind load` yavaş; sha etiketli image |
| ingress-nginx | kind manifest | 00 | Gerçek client yolu, 5xx metrikleri, 08'de XFF ve limit-rps |
| metrics-server | manifest | 00 | `kubectl top`, 07'de HPA |
| kube-prometheus-stack | `prometheus-community` | 00 | Prometheus + Grafana + Alertmanager + KSM + node-exporter + cAdvisor. `enableRemoteWriteReceiver`, `exemplar-storage`, dashboard sidecar |
| Loki + Alloy | `grafana/loki`, `grafana/alloy` | 01 | Log'lar; Alloy 11'de OTLP toplayıcı da olur |
| k6 (Mac'te) | `brew install k6` | 00 | `-o experimental-prometheus-rw` ile k6 metrikleri Prometheus'a → yük ve sunucu aynı panelde |
| Chaos Mesh | `chaos-mesh` | 02 | Gecikme/paket kaybı/pod-kill; kind için `chaosDaemon.runtime=containerd` |
| Redpanda (Kafka API) | `redpanda` | 06 | Laptop dostu tek binary; `rpk`; public metrics. (ADR: Strimzi alternatifi) |
| CloudNativePG | `cnpg` | 09 | Primary+replica, failover, Pooler, barman → MinIO |
| MinIO | `minio` | 09 | Yedek/PITR hedefi |
| KEDA | `kedacore` | 07 | Kafka lag ve Prometheus RPS ile ölçekleme (prometheus-adapter'a gerek kalmaz) |
| Tempo | `grafana/tempo` | 11 | Trace'ler |
| Pyroscope | `grafana/pyroscope` | 11 | Sürekli profil (opsiyonel) |
| Sloth | manifest | 11 | SLO → multi-window burn-rate PrometheusRule |
| Argo CD + Gitea | `argo`, `gitea` | 12 | Cluster içi GitOps kaynağı (GitHub'a bağımlı olma) |
| Argo Rollouts | `argo` | 12 | Canary + Prometheus analizi + otomatik geri alma |
| cert-manager, sealed-secrets, Kyverno | ilgili chart'lar | 13 | TLS, sır yönetimi, policy |
| Linkerd, Gateway API, VPA | — | 14 | Opsiyonel/stretch |

### 2.1.1 Bu ortamda karşılaşılan gerçek engeller (Faz A'da çözüldü)

| Engel | Belirti | Çözüm |
|---|---|---|
| Kurumsal TLS araya girmesi (Cloudflare Gateway) | Node'lar image çekemiyor: `x509: certificate signed by unknown authority` | `platform/kind/trust-ca.sh` — kök CA'yı canlı el sıkışmadan çıkarıp her node'un güven deposuna kurar, containerd'yi yeniler. `make cluster` otomatik çağırır |
| ingress-nginx yanlış node'a düşüyor | Host'tan 80'e bağlanılıyor ama yanıt yok (kind port map yalnızca control-plane'de) | `manifests/ingress-nginx-patch.yaml` — `nodeSelector: ingress-ready=true` + control-plane toleration |
| cAdvisor `container` label'ı üretmiyor (cgroup v1) | `container!=""` filtreli tüm PromQL sorguları BOŞ döner | Tüm sorgular `image!="",image!~".*pause.*"` filtresine geçti (her iki ortamda da çalışır) |
| `container_cpu_cfs_throttled_*` metriği hiç yok | Throttling paneli boş | Ortam sınırı olarak işaretlendi; **07'de (P07-04) alternatif ölçüm gerekecek** |
| Docker Desktop yeniden başlatması | Tüm pod'lar `Unknown`, kubelet yeniden senkronize olana kadar | Beklemek yeterli; `make up` tekrar koşulabilir |

### 2.2 Profiller (16 GB Mac gerçeği)

Docker Desktop'a **6 CPU / 10 GB** ver. Aynı anda tek seviye çalıştır (`make down` alışkanlığı).

| Profil | Seviyeler | İçerik | Tahmini RAM |
|---|---|---|---|
| `minimal` | 00–05 | core + kube-prometheus-stack + Loki/Alloy | ~3 GB |
| `standard` | 06–10 | + Redpanda (1 broker), CNPG (opr), Chaos Mesh, KEDA | ~5–6 GB |
| `full` | 11–14 | + Tempo, Pyroscope, Argo CD/Rollouts, Gitea, cert-manager, sealed-secrets, Kyverno | ~8–9 GB |

Sıkışırsa: kind'ı 1 cp + 2 worker'a düşür, Tempo/Pyroscope'u sadece 11'de aç, Redpanda'ya
`resources.cpu.cores=1, memory 1Gi`.

### 2.3 Ortak Make hedefleri (`ladder.mk` — her seviyede aynı)

```
make up            # build → push(local registry) → kubectl apply -k deploy/ → rollout wait → smoke → Grafana linki
make down          # namespace sil
make load S=mixed  # platform/k6/scenarios/<S>.js; level tag'i ile Prometheus'a yazar (aynı senaryolar her seviyede)
make repro P=P02-01               # problems/P02-01.sh (adımları basar, ölçer, REPRODUCED/NOT-REPRODUCED)
make chaos C=pg-delay-2s          # platform/chaos/<C>.yaml'ı bu namespace'e uygular (make unchaos)
make grafana                      # port-forward 3000 + "Ladder" klasörünü level=lvlNN seçili açar
make logs                         # Loki'den bu namespace (ya da kubectl logs, 00'da)
make diff-prev                    # git diff --no-index ../<önceki> . (go.sum/README hariç)
make verify-prev                  # önceki seviyenin problems/*.sh'sini bu namespace'e koşar
make test | lint                  # go test -race ./... | go vet + iskelet lint
```

### 2.4 `problems/*.sh` kontratı

- Girdi: `NS`, `BASE_URL`, `GRAFANA_URL` env; `CONFIRM=1` yıkıcı adımlar için zorunlu.
- Çıktı: adımları yazar, gözlemi ölçer (k6 özet / PromQL sorgusu / curl sayımı), son satır
  `REPRODUCED` (exit 0) ya da `NOT-REPRODUCED` (exit 1).
- `--explain` README'deki ilgili bölümü basar.
- Ölçüm için Prometheus HTTP API (`/api/v1/query`) kullanılır; böylece "Grafana'da gördüğün"
  ile "script'in ölçtüğü" aynı PromQL'dir.

`tools/ladder-matrix` bütün scriptleri bütün seviyelere koşup kök README'deki matrisi üretir
(gece çalıştırılır; yıkıcı deneyler seri).

### 2.5 Tek Grafana seti, tek k6 seti, tek chaos seti

**Dashboard'lar bir kere kurulur, her seviye aynı panellere bakar.** Hepsinde `$level` (namespace)
değişkeni vardır; 03'ten 04'e geçmek = dropdown'dan `lvl03` → `lvl04` seçmek. Bir seviyede veri
üretmeyen panel **boş kalır** ve README "Gözlemlenebilirlik" bölümü hangi panelin neden boş
olduğunu söyler ("00'da `App / RED` boş: metrik yok — bu P00-09'un kendisi").

| Dashboard (`platform/dashboards/`) | Paneller | Dolmaya başladığı seviye |
|---|---|---|
| `ladder-overview` | Tüm seviyeler yan yana: availability, p99, restart, pod sayısı | 00 |
| `pods-resources` | CPU/throttling, working set, OOMKilled, restart nedeni, goroutine, heap | 00 (cAdvisor/KSM) · 01 (go runtime) |
| `app-red` | route/method/code bazlı rate-error-duration, in-flight, panic | 01 |
| `app-business` | `links_total`, `redirect_*`, `create_*`, RYW ihlali, unsafe reject, tenant başına istek | 01 |
| `cache` | hit/miss/negative/stampede-wait pod bazlı, eviction, L1 vs L2 | 03 |
| `postgres` | connections vs max, tps, seq scan, locks, dead tuples, replication lag, pool acquire | 02 |
| `redis` | ops, hit/miss, memory vs maxmemory, evictions, clients, latency | 04 |
| `analytics` | enqueued/dropped/written, queue depth, **k6 tıklama − DB tıklama** farkı | 05 |
| `stream` | produce rate, producer buffer, consumer lag, commit rate, duplicate oranı, DLQ | 06 |
| `autoscaling` | HPA/KEDA desired vs current vs target, Pending pod, node kapasite | 07 |
| `ratelimit` | allow/reject per key, normal client p99 vs abuser p99 | 01 (süreç içi) · 08 |
| `resilience` | breaker state, shed, retry oranı, dependency latency, endpoint sayısı | 10 |
| `slo` | error budget, burn rate, alarm timeline | 11 |
| `rollout` | stable vs canary RED yan yana | 12 |
| `security` | 401/403, policy reddi, unsafe URL reddi | 13 |
| `k6` | Client tarafı: VU, rps, p95/p99, `http_req_failed` — sunucu panelleriyle aynı zaman ekseni | 00 |

**k6 senaryoları tek yerde (`platform/k6/scenarios/`), her seviyede aynı adla çağrılır:**
`create · redirect · mixed · hot-key · burst · abuser · read-your-writes · stairs · scan`.
Senaryo seviyeyi bilmez; `BASE_URL` ve `LEVEL` tag'i alır. Aynı `make load S=redirect`'i 02'de ve
04'te koşup `postgres` dashboard'unda DB qps'i kıyaslamak merdivenin temel egzersizidir.

**Chaos şablonları tek yerde (`platform/chaos/`), `NS` ile parametreli:**
`pg-delay-2s · pg-loss-30 · pg-loss-50 · redis-delay-200ms · redis-delay-3s · redis-kill · consumer-kill-30s ·
replica-delay · node-freeze · pod-kill-<svc>`. Bir şablon hedef bileşen o seviyede yoksa `make chaos`
"bu seviyede <bileşen> yok" der ve çıkar.

---

## 3. Merdiven — tek bakışta

| # | Klasör | Slogan | Yeni gelen | Çözdüğü ana acı | Getirdiği ana acı |
|---|---|---|---|---|---|
| 00 | `00-naive` | Tek dosya, tek pod, bellek | Hiçbir şey | — | Çöker, unutur, ölçeklenmez, kördür |
| 01 | `01-hardened` | Tek süreç ama düzgün | mutex, probe, graceful shutdown, timeout, doğrulama, `/metrics`, log | Çökme, körlük, rollout hataları | Hâlâ unutur ve ölçeklenmez |
| 02 | `02-postgres` | Kalıcılık ve yatay ölçek | Postgres (StatefulSet), stateless N replika, migration | Kayıp, tek replika | Her redirect DB'ye gider; pool biter; DB SPOF |
| 03 | `03-local-cache` | Süreç içi önbellek | LRU+TTL+singleflight | DB okuma yükü | Pod'lar arası tutarsızlık, soğuk cache |
| 04 | `04-redis-cache` | Paylaşılan önbellek | Redis cache-aside, negative cache, TTL jitter | Tutarsızlık, soğuk cache | Redis SPOF, hot key, stampede |
| 05 | `05-async-analytics` | Yazmayı okuma yolundan çıkar | Bounded channel + batch writer, stats API | Redirect'te satır kilidi | At-most-once kayıp, back pressure |
| 06 | `06-event-stream` | Olay akışı, ayrı tüketici | Redpanda, producer, consumer deployment | Kayıp, bağlaşım | Duplicate, lag, poison message |
| 07 | `07-services-autoscaling` | Servisleri ayır, otomatik ölçekle | redirect/api/analytics svc, HPA, KEDA, migration Job | Tek deployment iki profil | Darboğaz DB/Redis'e taşınır, throttling, cold start |
| 08 | `08-rate-limiting` | Gürültülü komşu | Redis'te dağıtık limiter, ingress limit, XFF | Pod başına yanlış limit | Limiter'ın kendi bağımlılığı, fail-open/closed |
| 09 | `09-database-scaling` | Veritabanı darboğazı | CNPG primary+2 replica, Pooler, partition, PITR | Pool, SPOF, okuma yükü | Replikasyon gecikmesi, read-your-writes |
| 10 | `10-resilience` | Hata izolasyonu | timeout bütçesi, retry+jitter, breaker, bulkhead, shedding, chaos | Kaskad çökmeler | Ayar karmaşıklığı |
| 11 | `11-observability-deep` | Neden yavaş? | OTel trace, exemplar, log↔trace, SLO, burn-rate alarm, profil | "Hangi hop?" sorusu | Sampling, kardinalite, alarm yorgunluğu |
| 12 | `12-delivery` | Güvenli dağıtım | Argo CD (Gitea), Rollouts canary, expand/contract, CI | Kötü sürüm %100'e gider | Migration/rollback uyumu |
| 13 | `13-security-tenancy` | Kim, neye, ne kadar | API key/JWT, RLS, NetworkPolicy, TLS, sealed-secrets, Kyverno, SSRF | Header ile tenant, açık ağ | Operasyonel sürtünme |
| 14 | `14-modern` | Son hal | Redis HA, L1+L2, gRPC, Gateway API, (Linkerd), kapasite modeli, game day | Kalanlar | "Yolun devamı" listesi |

---

## 4. Seviye seviye detay

Her seviye için: amaç → çözülenler → eklenenler → **sorunlar tablosu** (ID · belirti · reproduce · Grafana sinyali · çözüm) → seviye içi alıştırmalar → bilerek bırakılanlar.

---

### 00 — `00-naive` · "Tek dosya, tek pod, bellek"

**Amaç:** Bir Go dosyasında, hiçbir koruma olmadan çalışan kısaltıcı. Kubernetes'te 1 replika.
Merdivenin ölçüm sıfır noktası: *bu kadar basit bir şey bile K8s'te kaç türlü kırılıyor?*

**Kod:** `cmd/linkly/main.go` (~120 satır). `map[string]string` (mutex yok), `math/rand` 4 karakter
kod (çakışma kontrolü yok), `http.ListenAndServe` (timeout yok), `301`, body limiti yok, doğrulama yok,
log yok, click sayacı `map[string]int` (o da yarışlı).
**Deploy:** Deployment (1 replika, `memory limit 128Mi`, probe yok), Service, Ingress.
**Grafana'da dolanlar:** sadece `pods-resources`, `ladder-overview`, `k6`. `app-red` ve `app-business` **boş** — bu P00-09'un kendisi.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P00-01 | Eşzamanlı map yazımı → süreç çöker | `make load S=create` (50 VU, 30 s) | `kube_pod_container_status_restarts_total` artar; `last_terminated_reason=Error`; `kubectl logs --previous` → `fatal error: concurrent map writes` | 01 |
| P00-02 | Restart = tüm linkler kaybolur | link oluştur → `kubectl delete pod` → GET 404 | Göremezsin — metrik yok. Sadece restart sayısı | 02 |
| P00-03 | `replicas>1` → rastgele 404 | `scale --replicas=3`; oluştur; 30 kez curl → ~%66 404 | ingress-nginx 404 oranı (uygulama tarafı kör) | 02 |
| P00-04 | Rollout/kill sırasında hata dalgası (readiness ve graceful shutdown yok) | `make load S=redirect` sürerken `kubectl rollout restart` | k6 `http_req_failed` sıçrar; ingress 502/503 | 01 |
| P00-05 | Kod çakışması sessizce üzerine yazar (62⁴≈14.8 M, doğum günü paradoksu: ~4.5 k linkte %50) | k6 `create` 10 k link, script eski kodları tekrar okur → hedef değişmiş olanları sayar | Yok | 01 |
| P00-06 | Doğrulama yok: `javascript:`, boş URL, 100 MB body, `http://10.0.0.1` | `problems/P00-06.sh` curl örnekleri; 100 MB body → bellek | `container_memory_working_set_bytes` | 01 |
| P00-07 | Sunucu timeout'u yok → slowloris ile yeni istekler bekler | küçük Python script 1000 yarım bağlantı açar; paralelde curl → asılı kalır | CPU düşük, latency sonsuz, goroutine sayısı yok — "kör nokta" dersi | 01 |
| P00-08 | Bellek sınırsız → OOMKilled → P00-02 tekrar | k6 uzun URL'lerle 500 k link | working set tavana vurur, `OOMKilled` | 01 (ölçüm) · 02 (asıl) |
| P00-09 | Gözlemlenebilirlik sıfır: "kaç 404 döndü?" cevaplanamaz | Soruya cevap aramaya çalış | Sadece cAdvisor + KSM | 01 |
| P00-10 | `301` + `Cache-Control` yok → tarayıcı kalıcı önbellekler; link silinse de yönlenir | Chrome'da aç → DELETE → tekrar aç: yönlenir; curl 404 | Yok | 01 (302 + no-store) · 05 (analitik etkisi) |

**Bilerek bırakılanlar:** Hepsi. Bu seviye "sorun kataloğu" üretmek için var.

---

### 01 — `01-hardened` · "Tek süreç ama düzgün"

**Amaç:** Aynı tek süreç, ama üretim disiplini: yarış yok, probe var, graceful shutdown var,
metrik var, log var. Hâlâ bellek içi ve tek replika — *çünkü henüz bunu zorlayan sorunu
görmedik, sadece göreceğiz.*

**Çözülenler:** P00-01 (RWMutex), P00-04 (readiness/liveness + preStop + `Shutdown` sırası),
P00-05 (`crypto/rand` 7 karakter + çakışma kontrolü/retry), P00-06 (şema allowlist, host kontrolü,
`MaxBytesReader`), P00-07 (`ReadHeaderTimeout`, `IdleTimeout`, timeout middleware), P00-09
(Prometheus: RED + go runtime + iş metrikleri, hepsi sıfırla pre-register; `slog` JSON → Loki;
request-id), P00-10 (302 + `Cache-Control: no-store`).

**Kod:** `internal/{httpapi,shortcode,store/memory,metrics,ratelimit,config}` — mevcut linkly'den
budanarak. Süreç içi per-IP token bucket (bilerek: 02'de yanlış olacak).
**Deploy:** resources request/limit, probes, `terminationGracePeriodSeconds`, ServiceMonitor, PDB
(1 replikada işe yaramaz — README bunu söyler).
**Grafana'da yeni dolanlar:** `app-red`, `app-business`, `pods-resources` (go runtime satırı), `ratelimit` (süreç içi).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P01-01 | (devralınan P00-02) restart = kayıp, **artık görünür** | pod sil | `links_total` gauge sıfırlanır | 02 |
| P01-02 | (devralınan P00-03) ölçeklenemez, **artık pod başına görünür** | replicas=3 | `redirect_not_found` pod bazlı | 02 |
| P01-03 | Tek replika = drain/rollout = kesinti | `kubectl drain kind-worker2` k6 altında | availability paneli, kesinti saniyesi | 02 |
| P01-04 | Bellek büyümesi görünür ama çözümsüz | k6 create sürekli | `go_memstats_heap_alloc_bytes` merdiven gibi | 02 |
| P01-05 | Süreç içi rate limit N pod'da N kat gevşer | (02'de reproduce) | — | 08 |
| P01-06 | **TRAP_METRIC_LABEL_CODE**: kısa kodu metrik label'ı yaparsan kardinalite patlar | bayrak açık, 100 k link | `prometheus_tsdb_head_series` fırlar, Grafana yavaşlar | seviye içi |
| P01-07 | **TRAP_LIVENESS_STRICT**: liveness = readiness + sıkı timeout → yükte restart fırtınası | bayrak açık + k6 burst | probe timeout → restart → kalan pod'a daha çok yük | seviye içi · 10 |
| P01-08 | Click sayacı hâlâ istek yolunda ve bellekte | — | `clicks_total` da restartta sıfırlanır | 02 · 05 |

---

### 02 — `02-postgres` · "Kalıcılık ve yatay ölçek"

**Amaç:** Durumu sürecin dışına çıkar. Uygulama stateless olunca N replika, drain, rollout
sorunsuz. Ama artık *her* istek ağ üzerinden DB'ye gidiyor.

**Çözülenler:** P00-02/P01-01, P00-03/P01-02, P01-03 (3 replika + PDB + anti-affinity), P01-04, P01-08 (kısmen).
**Kod:** `pgx/v5` pool, `goose` embedded migration, `INSERT … ON CONFLICT DO NOTHING` + retry ile kod
üretimi, `ListByTenant` (index'siz — bilerek), click sayacı senkron `UPDATE links SET clicks=clicks+1` (bilerek).
Pool metrikleri (`acquire_count`, `acquire_duration`, `empty_acquire`) expose edilir.
**Deploy:** Postgres 17 StatefulSet + postgres-exporter sidecar (operator yok — bilerek), app 3 replika, migration `main` içinde (bilerek).
**Grafana'da yeni dolanlar:** `postgres` (connections vs max, tps, seq scan, locks, pool acquire).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P02-01 | Her redirect = DB sorgusu | `make load S=redirect` 2 k rps | PG CPU %100, p99 yükselir; `pg_stat_statements` tepe SELECT | 03/04 |
| P02-02 | Bağlantı havuzu taşması: 10 replika × pool 25 > `max_connections=100` | `scale --replicas=10` + load | `pg_stat_activity_count` tavana; app 500 `too many clients` | 09 (Pooler) |
| P02-03 | DB tek nokta; failover yok | `kubectl delete pod postgres-0` | 30–60 s %100 hata | 09 |
| P02-04 | Per-pod rate limit: 10 rps × 3 pod ≈ 30 rps geçer, dağılım dengesizse adaletsiz | k6 tek IP, kabul edilen rps ölç | `ratelimit_allow` pod bazlı | 08 |
| P02-05 | Index yok → seq scan; 1 M satırda `list` saniyeler sürer | `generate_series` ile seed; list çağır | `pg_stat_user_tables_seq_scan` | seviye içi (migration 002) |
| P02-06 | Yavaş sorgu + timeout yok → havuz dolar → kaskad | `make chaos C=pg-delay-2s` | pool `empty_acquire` artar, readiness düşer | `statement_timeout` (seviye içi) · 10 |
| P02-07 | Migration'ı N pod aynı anda koşar → kilit hatası/yarış | sıfırdan 5 replika deploy | crash loop ilk saniyeler | 07 (Job) |
| P02-08 | Senkron click `UPDATE` → hot link'te satır kilidi kuyruğu, WAL şişmesi | `make load S=hot-key` 500 VU tek kod | `pg_locks`, redirect p99, WAL bytes | 05 |
| P02-09 | Sır ConfigMap/env'de düz metin | `kubectl get deploy -o yaml` | — | 13 |

---

### 03 — `03-local-cache` · "Süreç içi önbellek"

**Amaç:** Cache-aside'ın en ucuz hali: pod belleğinde LRU. DB okuma yükü çöker ama *N kopya
gerçeği* ile tanışırız.

**Çözülenler:** P02-01 (büyük ölçüde).
**Kod:** `internal/cache` (bounded LRU + TTL + singleflight + negative cache; linkly'den), hit/miss/eviction/stampede-wait metrikleri.
**Grafana'da yeni dolanlar:** `cache` (hit ratio **pod bazlı**, stampede-wait); `postgres` qps'in düşüşü.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P03-01 | Silme sonrası diğer pod'lar TTL boyunca yönlendirmeye devam eder | DELETE sonrası 30 curl → karışık 404/302 | pod bazlı `cache_hit` | 04 (paylaşılan) · alt. pub/sub broadcast |
| P03-02 | Her rollout/scale-out = soğuk cache = DB tepesi (testere dişi) | rollout restart k6 altında | DB qps testere dişi, p99 tepe | 04 |
| P03-03 | Bellek × pod: 100 k sıcak link × 3 pod | k6 100 k farklı kod | `go_memstats` pod başına aynı | 04 |
| P03-04 | Hit ratio pod sayısıyla düşer (rastgele LB) | replicas 1→3→6, hit ratio karşılaştır | hit ratio vs replika paneli | 04 · consistent hashing (tartışma) |
| P03-05 | **TRAP_NO_SINGLEFLIGHT**: TTL dolan hot key'de stampede | bayrak + hot-key load | DB qps ani tepe, `cache_stampede_wait`=0 | seviye içi |
| P03-06 | **TRAP_NO_NEGATIVE_CACHE**: rastgele kod taraması hep miss → DB | k6 rastgele kod | `cache_miss` = DB qps | seviye içi |

---

### 04 — `04-redis-cache` · "Paylaşılan önbellek"

**Amaç:** Cache'i tek yere taşı; tutarlılık ve soğuk cache biter, ama cache artık ağda ve
kendisi bir bağımlılık.

**Çözülenler:** P03-01..04.
**Kod:** `go-redis/v9`, cache-aside `GET/SET EX/DEL`, TTL jitter, negative cache, per-pod singleflight; cache hatası = fatal **değil** (log + metric + DB'ye düş). Debug endpoint'inde `KEYS *` (bilerek — P04-07).
**Deploy:** Redis 7 StatefulSet + redis_exporter, `maxmemory 64mb`, policy `noeviction` (bilerek).
**Grafana'da yeni dolanlar:** `redis`; `cache` panelinde L2 satırı.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P04-01 | Redis düşünce her şey DB'ye düşer → P02-01 geri gelir (ya da fallback yoksa 500) | `delete pod redis-0` k6 altında | `redis_up`=0, DB qps tepe | 10 (bulkhead) · 14 (Redis HA) |
| P04-02 | +1 ağ RTT: p50 03'e göre yüksek | 03 ve 04 p50 panelini yan yana | latency karşılaştırma | 14 (L1+L2) |
| P04-03 | Hot key: tek link trafiğin %50'si → tek Redis CPU | `make load S=hot-key` | `redis_cpu`, komut/s tavan | 14 (L1) |
| P04-04 | **TRAP_NO_TTL_JITTER**: deploy sonrası tüm anahtarlar aynı anda dolar → DB tepe | bayrak; 60 s bekle | DB qps periyodik tepe | seviye içi |
| P04-05 | Update endpoint'inde cache-aside yarışı: DB update → DEL arasında okuma eski değeri yeniden yazar | `TRAP_UPDATE_DELAY_MS=500` ile pencereyi büyüt, paralel GET | stale redirect sayısı | tartışma + versiyonlu anahtar |
| P04-06 | `maxmemory` + `noeviction` → `OOM command not allowed` → SET hataları | k6 200 k farklı link | `redis_memory_used_bytes` tavan, `cache_load_error` | seviye içi (`allkeys-lru`) |
| P04-07 | Debug endpoint `KEYS *` → 1 M anahtarda Redis kilitlenir, tüm redirect'ler bekler | seed 1 M key, `/debug/stats` çağır | Redis latency tepe | seviye içi (`SCAN`/sayaç) |

---

### 05 — `05-async-analytics` · "Yazmayı okuma yolundan çıkar"

**Amaç:** Click kaydı redirect'i asla bekletmesin. En ucuz asenkron: süreç içi bounded kuyruk +
batch yazıcı. Kayıp ve back pressure ile tanışırız.

**Çözülenler:** P02-08.
**Kod:** `internal/analytics` (linkly'den: bounded channel, batch/flush, drop metriği), `clicks` tablosu, `GET /api/links/{code}/stats` (`count(*)` — bilerek). Shutdown sırası: server → drain queue → DB.
**Grafana'da yeni dolanlar:** `analytics` (enqueued/dropped/written, queue depth, **k6 tıklama − DB tıklama** farkı).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P05-01 | At-most-once: restart/rollout kuyruktakileri kaybeder | 100 k redirect sırasında rollout; k6 sayısı vs DB | "gap" paneli | 06 |
| P05-02 | Kuyruk dolunca drop (görünür); **TRAP_UNBOUNDED_QUEUE** ile OOM | burst senaryosu; bayrakla OOMKilled | `analytics_dropped`; working set | 06 |
| P05-03 | Analitik yazımı redirect ile aynı pod ve aynı DB'de yarışır | click burst → redirect p99 | p99 vs write batch | 06/07 |
| P05-04 | Stats `count(*)` 10 M satırda yavaş | seed 10 M click | stats latency | 06 (toplam tablo) |
| P05-05 | `terminationGracePeriodSeconds` kısa → drain yarım kalır | 5 s'ye çek, rollout | gap artar | seviye içi |
| P05-06 | **TRAP_REDIRECT_301**: tarayıcı 301'i önbellekler → click sayılmaz | Chrome'da 5 kez aç → DB'de 1 | `redirect_ok` vs gerçek | seviye içi (302/307) |

---

### 06 — `06-event-stream` · "Olay akışı, ayrı tüketici"

**Amaç:** Click olaylarını broker'a yaz, ayrı bir consumer deployment tüketsin. Dayanıklılık
gelir; teslimat semantiği (duplicate, lag, poison) ile ödenir.

**Çözülenler:** P05-01, P05-03, P05-04 (`link_stats_daily` toplam tablosu).
**Kod:** `franz-go` producer (async buffer, `acks=all`, shutdown'da flush; redirect asla bloklanmaz), `cmd/analytics-consumer` (grup, batch, DB'ye yaz **sonra** commit — at-least-once), event şeması JSON+`event_id`.
**Deploy:** Redpanda 1 broker, topic `clicks` 1 partition (bilerek), Redpanda Console.
**Grafana'da yeni dolanlar:** `stream` (produce rate, buffer, consumer lag, commit rate, duplicate, DLQ).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P06-01 | Duplicate / çift sayım: consumer yazdıktan sonra commit'ten önce ölürse | `make chaos C=consumer-kill-30s` load altında; k6 vs DB | duplicate paneli (>0) | seviye içi: idempotent consumer (`event_id` upsert) |
| P06-02 | Consumer lag: yavaş/ölü consumer → stats bayat | `scale consumer --replicas=0` | lag paneli büyür | 07 (KEDA) |
| P06-03 | 1 partition = 1 tüketici; consumer'ı 3'e çıkarmak işe yaramaz | scale 3, lag değişmez | partition-consumer paneli | seviye içi (repartition) + sıralama tartışması |
| P06-04 | Poison message → consumer crashloop, lag sonsuza | `rpk topic produce` ile bozuk JSON | restarts + lag | seviye içi (DLQ topic + skip) |
| P06-05 | Broker düşünce producer buffer dolar: bloklamak mı düşürmek mi? | `delete pod redpanda-0` | `producer_buffer`, redirect p99 (bloklarsa!) | seviye içi (asla bloklama) · 14 (3 broker) |
| P06-06 | "Exactly-once" yok; at-least-once + idempotency | tartışma + P06-01 testi | — | — |
| P06-07 | Şema evrimi: alan yeniden adlandır → eski consumer patlar | v2 producer, v1 consumer | hata oranı | tartışma (versiyon alanı / Protobuf, 14 opsiyonel) |

---

### 07 — `07-services-autoscaling` · "Servisleri ayır, otomatik ölçekle"

**Amaç:** Okuma yolu (redirect) ile yazma/yönetim yolu (api) ve tüketici (analytics) farklı
ölçek profillerine sahip → ayrı deployment'lar, ayrı HPA'lar. İskelet aynı: `cmd/` altında üç servis, `deploy/` altında üç Deployment.

**Çözülenler:** P06-02 (KEDA Kafka lag), P05-03, P02-07 (migration Job + `wait-for` initContainer).
**Kod:** `cmd/redirect-svc`, `cmd/api-svc`, `cmd/analytics-svc` (+ stats HTTP), `internal/` paylaşımlı; api-svc list endpoint'i her link için analytics-svc'ye ayrı çağrı (**N+1, bilerek**).
**Deploy:** üç Deployment + migration Job, HPA (CPU) + KEDA `ScaledObject` (Prometheus RPS tetikleyicisi redirect için, Kafka lag consumer için), sıkı CPU limit (bilerek), topologySpread yok (bilerek).
**Grafana'da yeni dolanlar:** `autoscaling`; `pods-resources` throttling satırı; `app-red` servis bazlı.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P07-01 | HPA gecikir: burst → 60–90 s pod yok → latency penceresi; sonra flapping | `make load S=stairs` | HPA paneli vs p99 | seviye içi (`behavior`, hedef, min) |
| P07-02 | App 20 replika → darboğaz DB/Redis'e taşınır | HPA max 20 + load | PG/Redis CPU tavan, app boş | 09 |
| P07-03 | Yeni pod hazır ama havuz/cache soğuk → ilk istekler yavaş | scale-out anında p99 | pod-yaş vs latency | seviye içi (warm-up, readiness) |
| P07-04 | CPU limit sıkı → throttling; CPU %50 görünürken p99 fırlar | `make load S=mixed` | `container_cpu_cfs_throttled_seconds_total` | seviye içi (limit kaldır/artır) |
| P07-05 | Node kapasitesi bitti → Pending; kind'da autoscaler yok | HPA 30'a çekilir | `kube_pod_status_phase{Pending}` | tartışma (cluster autoscaler/Karpenter) |
| P07-06 | N+1 servis çağrısı: 100 link'lik list = 100 stats çağrısı | list endpoint p99 | api→analytics çağrı sayısı | seviye içi (batch) · 14 (gRPC) |
| P07-07 | Tüm replikalar aynı node'da → node donunca kesinti | `docker pause kind-worker2`; 40 s NotReady, 5 dk evict | availability | seviye içi (topologySpread, PDB) |
| P07-08 | Readiness sadece TCP → bozuk pod trafik alır | `TRAP_READY_ALWAYS` + DB'siz pod | 500'ler | seviye içi · 10 (doğru semantik) |

---

### 08 — `08-rate-limiting` · "Gürültülü komşu"

**Amaç:** Bir kötü/aç client diğerlerini yavaşlatmasın. Redis'te dağıtık limiter (Lua token
bucket / sliding window), tenant ve IP bazlı, `429 + Retry-After`; ingress'te ilk hat.

**Çözülenler:** P01-05/P02-04.
**Kod:** `internal/ratelimit/redis` (Lua script atomik), key: IP / API key / tenant; XFF'i sadece ingress hop'undan güven (`TRAP_TRUST_ANY_XFF` bilerek var).
**Deploy:** ingress annotasyonu `limit-rps`, `use-forwarded-headers`.
**Grafana'da yeni dolanlar:** `ratelimit` (artık anahtar bazlı, dağıtık).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P08-01 | Limiter Redis'e bağımlı: Redis yokken fail-open mı fail-closed mı? | Redis'i sil | 429 oranı 0 ya da %100 | karar + README (fail-open + alarm) · 10 |
| P08-02 | Her isteğe +1 Redis RTT | 04 vs 08 p50 | latency | seviye içi (yerel token cache / pipeline) |
| P08-03a | **TRAP_IGNORE_XFF**: tüm client'lar ingress IP'sinde tek kova → herkes birlikte limitlenir | 2 client, biri abuser → ikisi de 429 | per-key paneli tek anahtar | seviye içi |
| P08-03b | **TRAP_TRUST_ANY_XFF**: header spoof ile limit atlatılır | k6 rastgele XFF | reject 0 | seviye içi (sadece ingress hop'u) |
| P08-04 | Sabit pencere: sınırda 2× burst geçer | `make load S=burst` (pencere sınırına hizalı) | kabul edilen/s tepe | seviye içi (sliding window) |
| P08-05 | Global limit anahtarı = Redis hot key | global limit aç + load | Redis CPU | seviye içi (anahtar parçalama) |
| P08-06 | Büyük müşteri vs abuser: tier kotaları, adalet | 2 tenant senaryosu | tenant bazlı p99 | seviye içi (config) · 13 |

---

### 09 — `09-database-scaling` · "Veritabanı darboğazı"

**Amaç:** DB'yi operatörle yönet: primary + 2 replica, otomatik failover, PgBouncer Pooler,
okuma/yazma ayrımı, `clicks` partition'ları, MinIO'ya yedek/PITR.

**Çözülenler:** P02-02 (Pooler), P02-03 (failover), P07-02 (okuma replikaya).
**Kod:** iki pool (`-rw`, `-ro`), okuma tercihi ayarı, `create` sonrası cache write-through (P09-01 çözümü, bayrakla).
**Deploy:** CNPG `Cluster` (3 instance), `Pooler` (transaction mode, `max_prepared_statements=0` — bilerek), `clicks` RANGE partition by day, barman → MinIO, ScheduledBackup.
**Grafana'da yeni dolanlar:** `postgres` replication lag / failover satırları; `app-business` RYW ihlal sayacı.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P09-01 | Replikasyon gecikmesi → **read-your-writes ihlali**: oluştur → hemen redirect → 404 | `make load S=read-your-writes`; kesinleştirmek için `make chaos C=replica-delay` ya da `recovery_min_apply_delay=5s` | RYW ihlal sayacı, lag | seviye içi: create'te cache'e yaz / N sn primary'den oku |
| P09-02 | Failover penceresi: primary ölür → 10–30 s yazma hatası; app'in yeniden bağlanması | `delete pod <primary>` | write error oranı, promote olayı | seviye içi (retry + idempotency key) · 10 |
| P09-03 | Transaction pooling + pgx prepared statements → `prepared statement … does not exist` | Pooler'a geç | 500 oranı | seviye içi (`default_query_exec_mode=exec` ya da `max_prepared_statements>0`) |
| P09-04 | Uzun okuma replikada iptal: `canceling statement due to conflict with recovery` | uzun list + yoğun yazma | hata logu | tartışma (`hot_standby_feedback`) |
| P09-05 | Partition key olmadan sorgu tüm partition'ları tarar | `EXPLAIN` | plan | seviye içi |
| P09-06 | Sıcak sayaç satırı → dead tuple, bloat | hot-key + `n_dead_tup` | `pg_stat_user_tables_n_dead_tup` | tartışma (`fillfactor`, HOT) |
| P09-07 | "Yanlışlıkla tüm linkleri sildim" → PITR | `DELETE FROM links` → `CONFIRM=1` ile geri yükle | recovery süresi | seviye içi (barman PITR) |

---

### 10 — `10-resilience` · "Hata izolasyonu"

**Amaç:** Bağımlılık kısmen bozulduğunda sistem *kısmen* bozulsun, tamamen değil. Her
deney önce "koruma kapalı" ile kaskadı gösterir, sonra "açık" ile kıyaslar.

**Çözülenler:** P04-01, P02-06, P08-01, P09-02, P01-07/P07-08 (probe semantiği).
**Kod:** uçtan uca `context` deadline bütçesi, retry (exp backoff + jitter + retry budget), `gobreaker`, bağımlılık başına semaphore (bulkhead), load shedding (in-flight limiti → hızlı 503), degrade modları (Redis yok → DB'ye sınırlı eşzamanlılık; DB yok → cache'ten redirect, create 503). Readiness: **sadece kendi** durumu; bağımlılık sağlığı metrik olarak.
**Deploy:** `chaos/` klasörü birinci sınıf: her deney bir YAML + `make chaos C=`.
**Grafana'da yeni dolanlar:** `resilience`.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P10-01 | Retry fırtınası: %30 hata + 3 naive retry → 3× yük → tam çöküş | `TRAP_NAIVE_RETRY` + `C=pg-loss-30` | DB qps ×3, breaker yok | jitter + budget |
| P10-02 | Readiness bağımlılığa bağlı → Redis'te kısa kesinti → **tüm** pod'lar NotReady → endpoint 0 → tam kesinti | `TRAP_READY_CHECKS_REDIS` + Redis'i 10 s durdur | endpoint sayısı 0 | readiness = kendi durumu |
| P10-03 | Timeout hizasızlığı: client 1 s vazgeçer, sunucu 30 s çalışmaya devam eder → boşa iş | `C=pg-delay-2s` + k6 timeout 1 s | in-flight artar, DB yükü artar | context propagation |
| P10-04 | Breaker half-open flapping, eşik ayarı | `C=pg-loss-50` | breaker state timeline | ayar + README |
| P10-05 | Yavaş bağımlılık, ölü bağımlılıktan beterdir: timeout yok → goroutine/bellek şişer → OOM | `TRAP_NO_DEP_TIMEOUT` + `C=redis-delay-3s` | goroutine sayısı, working set | dependency timeout |
| P10-06 | Load shedding yok → herkes yavaş; var → bazıları hızlı 503, kabul edilenlerin p99 sabit | shedding aç/kapa, 3× kapasite yük | p99 (kabul) vs 503 oranı | shedding |
| P10-07 | Liveness saldırgan → yükte restart fırtınası | (P01-07 tekrar, artık gerçek yükte) | restarts | liveness = deadlock tespiti, o kadar |

---

### 11 — `11-observability-deep` · "Neden yavaş?"

**Amaç:** "p99 yüksek" → "hangi servis, hangi hop, hangi sorgu?" Metrik + log + trace + profil
birbirine bağlı; alarm SLO'dan türetilir.

**Kod:** OpenTelemetry SDK (HTTP + pgx + redis + Kafka header propagation), exemplar'lı histogramlar, `slog` içine `trace_id`, Pyroscope Go SDK (opsiyonel), deliberate hot spot (`TRAP_REGEX_PER_REQUEST`).
**Deploy:** Alloy (OTLP → Tempo/Loki/Prometheus), Sloth SLO'ları (redirect availability 99.9, latency 300 ms p99), Alertmanager → webhook stub (log'a yazar), dashboards-as-code (JSON repo'da, Grafana'da düzenleme kapalı).
**Grafana'da yeni dolanlar:** `slo`; `app-red` exemplar noktaları → Tempo; Loki'de `trace_id` linki.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P11-01 | "p99 yüksek, nerede?" | `C=redis-delay-200ms`; önce trace kapalı tahmin et, sonra Tempo | exemplar → trace | tracing |
| P11-02 | Kafka üzerinden trace kopar | `TRAP_NO_KAFKA_PROPAGATION` | analytics span'ları yetim | header propagation |
| P11-03 | %100 sampling 5 k rps'te collector/Tempo'yu boğar; head sampling nadir hataları kaçırır | sampling 1.0 + load | Alloy CPU, Tempo ingest | oran + tail-based tartışması |
| P11-04 | Eşik alarmı (`error>1%`) flapping; burn-rate alarmı sakin | 30 s hata blip'i enjekte | Alertmanager timeline | multi-window burn-rate |
| P11-05 | Debug log seviyesi yükte Loki'yi limitler (`429`/rate limit) | `LOG_LEVEL=debug` + load | Loki ingest reject | seviyeler + log sampling |
| P11-06 | Kardinalite (P01-06 tekrar): tenant id label, 10 k tenant | k6 10 k tenant | head series | label değil exemplar/log |
| P11-07 | Elle düzenlenen dashboard drift eder | Grafana'da düzenle, `make up` | fark | dashboards-as-code |
| P11-08 | CPU hot spot: istek başına regex derleme | `TRAP_REGEX_PER_REQUEST` | Pyroscope flame graph | profil |

---

### 12 — `12-delivery` · "Güvenli dağıtım"

**Amaç:** Kötü sürüm %100'e gitmesin, migration deploy'u kırmasın, cluster'daki durum git'ten
sapamasın. Argo CD (Gitea'dan) + Argo Rollouts canary (Prometheus analizli). `make up` yine kustomize; Argo bu seviyenin *konusu*.

**Kod:** `v-bad` build bayrağı (`ldflags`) — redirect'lerin %10'unda 500 döner; expand/contract migration örneği; basit feature flag (env → 14'te OpenFeature opsiyonel).
**Deploy:** `deploy/` aynı; Deployment yerine `Rollout` CR, Argo CD `Application` (Gitea'daki kopyayı izler), `Rollout` (canary 10→50→100, `AnalysisTemplate`: error rate < %1, p99 < 300 ms), api-svc blue/green, CI: vet/test/race → image → Trivy → kind smoke.
**Grafana'da yeni dolanlar:** `rollout`.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P12-01 | Kötü sürüm rolling update ile %100'e gider | `kubectl set image …:v-bad` load altında | error rate %10 | canary + analiz → otomatik geri alma (aynı script Rollout'la NOT-REPRODUCED) |
| P12-02 | Kırıcı migration (kolon rename) rolling update sırasında eski pod'ları öldürür | `TRAP_BREAKING_MIGRATION` | 500'ler pencere | expand/contract |
| P12-03 | `kubectl edit` ile drift → Argo self-heal geri alır | replicas'ı elle değiştir | Argo sync durumu | GitOps |
| P12-04 | `:latest` etiketi → "deploy ettim değişmedi", geri alma imkânsız | latest ile deploy | — | sha etiketi · 13 (Kyverno) |
| P12-05 | Canary + cache anahtar formatı değişimi → karışık davranış | v2 anahtar öneki | cache miss tepe | tartışma (uyumlu anahtar) |
| P12-06 | App geri alındı, migration geri alınmadı | P12-02 sonrası rollback | — | tartışma + runbook |

---

### 13 — `13-security-tenancy` · "Kim, neye, ne kadar"

**Amaç:** Tenant sınırı header'dan değil kimlikten türesin; DB kendini korusun (RLS); ağ
varsayılan kapalı; sır git'te şifreli; policy engine kuralları uygulasın.

**Kod:** API key (hash'li, tenant'a bağlı) + JWT (Dex/OIDC, opsiyonel), `internal/tenant` (context), RLS (`SET LOCAL app.tenant_id`), SSRF/open-redirect sertleştirme (DNS çözüp özel aralıkları reddet; TOCTOU sınırı README'de), audit log.
**Deploy:** NetworkPolicy (default deny + izin listesi), cert-manager self-signed TLS, sealed-secrets, Kyverno (`disallow-latest`, `require-limits`, `require-probes`), pod security (non-root, RO fs), Trivy CI, cosign (opsiyonel).
**Grafana'da yeni dolanlar:** `security`.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P13-01 | `X-Tenant-ID` header → A, B'nin linkini siler | curl ile spoof | 403 yok | tenant = key/JWT |
| P13-02 | Tek sorguda unutulan tenant filtresi **sessiz** sızıntı | `TRAP_DROP_TENANT_FILTER` | list sonucu yabancı satır | RLS yakalar (0 satır/hata) |
| P13-03 | Her pod Postgres/Redis'e erişir | `kubectl run busybox` → `nc redis 6379` | — | NetworkPolicy |
| P13-04 | Sır ConfigMap/env/git'te (P02-09) | `kubectl get cm`, git log | — | sealed-secrets |
| P13-05 | `http://169.254.169.254/` ya da özel IP'ye çözülen host kabul edilir | curl | `create_rejected_unsafe` | DNS çözüm + blok |
| P13-06 | Enumeration: tahmin edilebilir kod / 404 taraması | k6 rastgele/ardışık | 404 oranı | rastgele kod + 404 limiti (08) |
| P13-07 | Policy: `:latest` / limitsiz pod deploy edilir | apply | Kyverno reject | Kyverno |
| P13-08 | Zafiyetli base image geçer | eski base ile build | Trivy CRITICAL | CI kapısı |

---

### 14 — `14-modern` · "Son hal"

**Amaç:** 01–13'ün tamamı tek sistemde + son kilometre: Redis HA (Sentinel/Valkey), L1+L2 cache
(pod LRU + Redis + pub/sub invalidation), gRPC (api↔analytics, buf), Gateway API, Redpanda 3
broker, KEDA her yerde, (opsiyonel) Linkerd mTLS/golden metrics, VPA önerileri.

**Ayrıca:**
- **Kapasite modeli** (`docs/capacity.md`): SDP'nin zarf arkası hesabını *gerçek k6 ölçümleriyle* yap —
  redirect/pod, Redis ops/çekirdek, PG rps/replica; "1 M link/gün, 100 M redirect/gün için kaç pod?"
- **Game day**: 00–13'teki tüm `problems/*.sh`'yi bu seviyeye koş; beklenen sonuç tablosu
  (hepsi NOT-REPRODUCED olmalı; olmayanlar "bilerek bırakılan").
- **Yolun devamı** (dürüst liste): tek cluster/tek bölge, gerçek CDN/edge, gerçek IdP, maliyet,
  multi-region aktif-aktif (iki kind cluster + DNS failover — stretch).

---

## 5. Seviye README şablonu (`docs/LEVEL-TEMPLATE.md`)

Her README aynı 10 başlığı aynı sırada taşır; 4 ve 5 **her seviyede kelimesi kelimesine aynıdır**
(`make up` → `curl` → `make grafana`; API kontratı linki). Değişen içerik 1–3 ve 6–10'dadır.

```
# NN — <ad> · "<slogan>"
1. Bu seviye ne? (3 cümle)                      6. Reproduce edilebilir sorunlar — README'nin kalbi.
2. Mimari (mermaid)                                 Önce tablo, sonra her sorun için alt bölüm:
3. Önceki seviyeden çözülenler (P-ID listesi)       Belirti · Neden · Adım adım reproduce (komutlar) ·
4. Ayağa kaldırma — SABİT METİN (make up …)        Grafana'da ne göreceksin (dashboard/panel/PromQL) ·
5. API — SABİT METİN (docs/API.md)                  Çözüm hangi seviyede · make repro P=…
                                                7. Seviye içi alıştırmalar (TRAP_ bayrakları)
                                                8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş ve neden
                                                9. Bilerek bırakılanlar
                                               10. make diff-prev okuma rehberi (neye bak)
```

Her sorun alt bölümü şu kalıpta (docs/PROBLEM-TEMPLATE.md):

```
### P02-02 · Bağlantı havuzu taşması
**Belirti:** app 500 döner, logda `FATAL: sorry, too many clients already`.
**Neden:** 10 replika × pool 25 = 250 > max_connections=100. Her pod kendi havuzunu "tek başınaymış gibi" boyutlar.
**Reproduce (adım adım):**
  1. `make up` (3 replika, sağlıklı)
  2. `make load S=redirect` (ikinci terminalde, 2 dk)
  3. `kubectl -n lvl02 scale deploy/linkly --replicas=10`
  4. 20–30 s içinde k6 `http_req_failed` > 0; `make repro P=P02-02` aynı adımları otomatik koşar ve ölçer
**Grafana:** `postgres` → "connections vs max" tavana yapışır; `app-red` → 5xx; PromQL: `pg_stat_activity_count >= pg_settings_max_connections`
**Neden şimdi çözmüyoruz / nerede çözülüyor:** 09 (Pooler). Geçici çare: pool'u 100/replika'ya böl — ama replika sayısı değişince tekrar bozulur.
```

**API kontratı** (her seviyede aynı; sonradan eklenenler işaretli):
`POST /api/links` · `GET /{code}` (302) · `GET /api/links/{code}` · `DELETE /api/links/{code}` ·
`GET /api/links` (02+) · `GET /api/links/{code}/stats` (05+) · `/healthz /readyz /metrics` (01+).
Tenant: `X-Tenant-ID` (02–12, README'de "kimlik değildir" uyarısıyla) → API key/JWT (13+).

**Metrik adları** (01'den itibaren sabit; dashboard'lar seviyeler arası kıyaslanabilir olsun):
`http_requests_total{route,method,code}`, `http_request_duration_seconds`, `redirect_*`, `create_*`,
`cache_*`, `ratelimit_*`, `analytics_*`, `dependency_request_duration_seconds{dep}`, `breaker_state{dep}`.

---

## 6. Sıra ve efor

| Faz | Kapsam | Süre (akşam/hafta sonu temposu) | Çıktı |
|---|---|---|---|
| A | platform `minimal` + 00 + 01 + docs şablonları + `ladder-matrix` iskeleti | 1–2 hafta | Merdiven ritmi oturur; kontrat netleşir |
| B | 02, 03, 04 | 2–3 hafta | Cache/DB dersleri |
| C | 05, 06, 07 (+ `standard` profil) | 3 hafta | Asenkron + servis ayrımı + ölçekleme |
| D | 08, 09, 10 | 3 hafta | Dağıtık limit, DB ops, dayanıklılık |
| E | 11, 12, 13 (+ `full` profil) | 3–4 hafta | Derin gözlem, GitOps, güvenlik |
| F | 14 + kapasite modeli + game day + matris | 2 hafta | Son hal |

Toplam ~3–4 ay. **Faz A bittiğinde planı yeniden gözden geçir**: bazı seviyeler birleşebilir
(03+04, 05+06) ya da bölünebilir. Kopya sayısı: 15 uygulama kopyası, sonuncusu 3 servis;
`make diff-prev` sayesinde kopya "gürültü" değil "ders".

---

## 7. Açık kararlar (ADR adayları)

| # | Karar | Öneri | Alternatif |
|---|---|---|---|
| 1 | Broker | Redpanda (tek binary, laptop dostu, Kafka API) | Strimzi Kafka (gerçek dünya), NATS JetStream (daha hafif) |
| 2 | 02'de Postgres | Düz StatefulSet (operatör *ihtiyacını* 09'da yaşamak için) | CNPG baştan |
| 3 | Deploy aracı | Her seviyede kustomize (`kubectl apply -k deploy/`); Argo/Rollouts 12'de *konu* olarak, `make up` değişmez | Araç merdiveni (YAML→Kustomize→Helm) — tekdüzeliği bozar, reddedildi |
| 4 | k6 | Mac'te, ingress'e, Prometheus remote-write | k6-operator cluster içinde |
| 5 | Repo | Tek repo `linkly-ladder`, seviye = Go modülü, `go.work` | Seviye başına repo |
| 6 | Mevcut `linkly` | Dokunma; paket kaynağı olarak kullan | Merdivene taşı |
| 7 | 14'te gRPC/Linkerd/Gateway API | Opsiyonel; önce kapasite modeli + game day | Zorunlu |
| 8 | Kimlik (13) | API key hash + opsiyonel Dex OIDC | Keycloak (ağır) |

---

## 8. İlk adım (Faz A checklist)

- [x] `brew install kind helm k6 kustomize` · Docker Desktop 6 CPU / 10 GB
- [x] `platform/`: kind cluster (Calico, port map, registry) → ingress-nginx → metrics-server → kube-prometheus-stack (remote-write receiver, exemplars, sidecar) → Loki + Alloy
- [x] `ladder.mk` (tüm hedefler) + `tools/newlevel.sh` + `tools/lint-skeleton.sh`
- [x] `platform/k6/lib` + 9 senaryo · `platform/dashboards/` 16 dashboard (`$level` değişkenli)
- [x] `platform/chaos/` 10 şablon
- [x] `docs/LEVEL-TEMPLATE.md` (4–5 sabit metin dahil), `PROBLEM-TEMPLATE.md`, `API.md`, 2 ADR
- [x] `00-naive`: kod + deploy + README + `problems/P00-01..10.sh` → hepsi REPRODUCED (gerçek cluster'da ölçüldü)
- [x] `01-hardened`: kod (internal/{config,metrics,shortcode,store,httpapi,ratelimit}) + birim testler + deploy (probe/PDB/ServiceMonitor) + README + `problems/P01-01..08.sh` + SOLVES
- [ ] `tools/ladder-matrix` v0 (iki seviye × 18 sorun) → kök README matrisi
- [ ] Faz A retrospektifi: şablon/kontrat düzeltmeleri, sonra Faz B
