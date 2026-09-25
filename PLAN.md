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
├── Makefile                         # tüm seviyeler: test · lint · fmt · verify · build · sweep · matrix · wipe
├── ladder.mk                        # seviye Makefile'larının TEK kaynağı (§1.1)
├── .github/workflows/ci.yml         # iskelet lint · her modül vet/test -race · script sözdizimi · dashboard üreteci · k6 inspect · image build
├── docs/
│   ├── LEVEL-TEMPLATE.md            # seviye README şablonu (bkz. §5)
│   ├── PROBLEM-TEMPLATE.md          # tek sorun kaydı şablonu + script kontratı + ölçüm kuralları
│   ├── API.md                       # tüm seviyelerde sabit API kontratı
│   ├── skeleton/                    # her seviyede birebir aynı Dockerfile + 3 satırlık Makefile
│   └── adr/                         # karar kayıtları (broker seçimi, tekdüze iskelet)
├── platform/                        # paylaşılan altyapı — §2
├── tools/
│   ├── ladder-matrix/               # tüm problems/*.sh'yi tüm seviyelere koşup matrisi üretir
│   ├── newlevel.sh                  # NN-name klasörünü bir öncekinden kopyalayıp modül adını değiştirir
│   ├── lint-skeleton.sh             # seviye iskeleti şablonla aynı mı (CI'da koşar) — lint-grafana.py'yi de çağırır
│   ├── lint-grafana.py              # her sorun bölümü var olan dashboard/panelleri mi anıyor
│   ├── lint-guide.py                # rehber blokları yapıştırılabilir mi (cd "$LADDER/…", yorumsuz, make fresh)
│   ├── verify-level.sh · verify-sweep.sh   # küme üzerinde uçtan uca doğrulama (up → verify-prev → repro → down)
│   └── observe-gameday.sh           # game day sırasında istemci ile uygulamayı yan yana izler
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
├── cmd/<svc>/main.go                # 00–01: cmd/linkly · 02+: + cmd/migrate · 06: + cmd/analytics-consumer · 07+: cmd/{redirect-svc,api-svc,analytics-consumer,migrate}
├── internal/…                       # DEĞİŞEN ŞEY 1: uygulama kodu
├── deploy/
│   ├── kustomization.yaml           # her seviyede aynı ad; ladder.mk `kubectl apply -k deploy/` yapar
│   └── *.yaml                       # DEĞİŞEN ŞEY 1 (devamı): bu seviyenin manifest'leri
└── problems/
    ├── PNN-XX.sh                    # DEĞİŞEN ŞEY 2: adım adım reproduce scriptleri (--explain README bölümünü basar)
    └── SOLVES                       # önceki seviyenin çözülen sorun ID'leri — make verify-prev bunu zorlar
```

**Seviyede olmayanlar (bilerek):** kendi Makefile hedefleri, kendi dashboard'ları, kendi k6
senaryoları, kendi chaos YAML'ları, kendi helm chart'ı. Hepsi `platform/`'da tek kopya.
`tools/newlevel.sh NN name` bir önceki seviyeyi kopyalar, modül adını ve `LEVEL`'i değiştirir;
`tools/lint-skeleton.sh` her seviyenin iskeletini şablonla karşılaştırır (CI'da koşar — sapma = hata).

**`ladder.mk` (kökte, tek kopya):** seviye Makefile'larının tamamı buradan gelir.
- `up`: profil (`platform/lib/profile.sh`: bu seviyenin platform bileşenlerini aç, gerisini kapat) → `cmd/*` altındaki
  her servisi derler → `localhost:5001/linkly-ladder/NN-<svc>:<sha>-<kaynak-hash>` → `kubectl apply -k deploy/`
  (namespace `lvlNN`, host `lvlNN.localtest.me`) → `wait` → smoke (`POST` + `GET` 30x) → Grafana linkini basar.
- `down`, `status`, `load S=`, `repro P=`, `chaos C=`, `unchaos`, `grafana`, `logs`, `env`/`set`/`unset`/`reset`,
  `diff-prev`, `verify-prev`, `test`, `lint`.
- Seviyeye özel iş gerekiyorsa o iş `deploy/` içindeki manifest'lere (Job'lar, init sırası) sığdırılır — Makefile'a
  değil. `ladder.mk` yalnızca TÜRE göre genel davranır: `wait`, namespace'te bir CNPG Cluster, `migrate`/`topics`
  Job'ı ya da Argo Rollout varsa onları da bekler.

**Namespace:** `lvlNN`. **Ingress host:** `lvlNN.localtest.me` (127.0.0.1'e çözülür, Chrome'da da çalışır).
**Image:** `localhost:5001/linkly-ladder/NN-<svc>:<git-sha>-<kaynak-hash>` (kind local registry; etiket deterministik —
`make push` ile `make deploy` ayrı çağrılsa da aynı imajı bulur).
**Deploy aracı:** her seviyede kustomize (`kubectl apply -k`). 12'de Argo CD / Rollouts *sorun konusu* olarak
gelir; `make up` yolu yine kustomize'dır (Rollout CR'si de `deploy/` içindeki bir YAML'dır).

---

## 2. Platform (paylaşılan altyapı)

```
platform/
├── Makefile                         # cluster · core · obs · dashboards · chaos · keda · cnpg · tempo · argo · security
│                                    #   minimal/standard/full · stop/start · wipe · destroy · profile · status
├── kind/
│   ├── cluster.yaml                 # 1 control-plane + 3 worker, disableDefaultCNI (Calico), 80/443 port map, registry mirror
│   ├── registry.sh                  # localhost:5001 (kind resmi tarifi)
│   ├── trust-ca.sh                  # kurumsal MITM kök CA'sını node'lara kurar
│   └── shim/docker                  # kind'ın `docker run`larına Compose etiketi ekler (Docker Desktop gruplaması)
├── manifests/                       # ingress-nginx yaması (node sabitleme) + XFF ConfigMap'i, metrics-server yaması,
│                                    #   Loki/Alloy/Kyverno ServiceMonitor'ları (Calico/ingress/metrics-server URL'den)
├── helm/                            # her bileşen için values.yaml (kaynakları Mac'e göre kısılmış)
├── lib/                             # repro.sh (script kütüphanesi) · k6run/loadtest/apikey · chaos · profile · setenv · smoke · verify-prev · wipe
├── dashboards/                      # TEK dashboard seti, tüm seviyeler için — §2.5
├── k6/
│   ├── lib/                         # base url, tag=level, ortak check'ler, senaryo yardımcıları
│   └── scenarios/                   # create · redirect · mixed · steady · hot-key · burst · abuser · read-your-writes · stairs · scan
└── chaos/                           # NetworkChaos/PodChaos şablonları (NS parametreli) — tüm seviyeler
```

### 2.1 Bileşenler ve ilk ihtiyaç duyulan seviye

| Bileşen | Kaynak | İlk seviye | Neden |
|---|---|---|---|
| kind (4 node) + Calico | `kind`, Calico manifest | 00 | Çoklu node: drain/node-freeze deneyleri; Calico: 13'te NetworkPolicy için cluster'ı yeniden kurmamak |
| Local registry | kind tarifi | 00 | `kind load` yavaş; içerik hash'li etiketli image |
| ingress-nginx | kind manifest | 00 | Gerçek client yolu, 5xx metrikleri; 08'de `limit-rps` annotasyonu, XFF güveni controller ConfigMap'inde |
| metrics-server | manifest | 00 | `kubectl top`, 07'de HPA |
| kube-prometheus-stack | `prometheus-community` | 00 | Prometheus + Grafana + Alertmanager + KSM + node-exporter + cAdvisor. `enableRemoteWriteReceiver`, `exemplar-storage`, dashboard sidecar |
| k6 (Mac'te) | `brew install k6` | 00 | `-o experimental-prometheus-rw` ile k6 metrikleri Prometheus'a → yük ve sunucu aynı panelde |
| Chaos Mesh | `chaos-mesh` | 02 | Gecikme/paket kaybı/pod-kill; kind için `chaosDaemon.runtime=containerd` |
| KEDA | `kedacore` | 07 | Tüketiciyi Kafka lag'e göre ölçekler (redirect'te CPU tabanlı HPA) |
| CloudNativePG | `cnpg` | 09 | Primary+replica, failover, Pooler (rw/ro). Nesne deposu/yedek yok — P09-06 |
| Loki + Alloy | `grafana/loki`, `grafana/alloy` | 11 | Log'lar (uygulama 01'den itibaren `slog` JSON yazar; `make logs` doğrudan `kubectl logs` okur). Alloy aynı seviyede OTLP toplayıcı da olur |
| Tempo | `grafana/tempo` | 11 | Trace'ler; exemplar → trace bağı |
| Argo CD + Argo Rollouts | `argo` | 12 | Rollouts: canary + Prometheus analizi + otomatik geri alma. Argo CD kurulu ama bilerek bir Application'a bağlı değil (P12-03 GitOps'un yokluğunu ölçer) |
| cert-manager, sealed-secrets, Kyverno | ilgili chart'lar | 13 | Kyverno politikaları uygular; cert-manager ve sealed-secrets kurulu ama seviye bilerek kullanmaz (TLS yok, sırlar düz metin — 13 §9) |

**Redpanda platform bileşeni değil:** 06'dan itibaren her seviye kendi `deploy/redpanda.yaml`'ında tek broker'lık
bir StatefulSet + topic Job'ı kurar (ADR-0001). Broker'ın ayarı seviyenin dersinin parçası (06: 1 partition, 14: 3).

**Kapsam dışı — bilerek kurulmayanlar:**

| Bileşen | Yerine ne var | Neden |
|---|---|---|
| Sloth (SLO → kural üreteci) | 11–14 `deploy/slo.yaml`: elle yazılmış PrometheusRule (kayıt kuralları + çok pencereli burn-rate alarmları) | Üreteç, burn-rate matematiğini bir soyutlamanın arkasına saklar; ders o matematiğin kendisi |
| Pyroscope (sürekli profil) | 11+ iç portta (`:6060`) `net/http/pprof`; P11-08 profili `kubectl get --raw` ile çeker | 6 çekirdekli VM'de sürekli toplayıcının bedeli; ders "profil olmadan görünmeyen sıcak nokta" — anlık profil yeter |
| Gitea + Argo CD `Application` | Seviyenin yerel manifest'leri; `make up` kustomize ile uygular | Elde bir GitOps zaten var (manifest + `make up`); P12-03, Argo CD'nin ekleyeceği sürekli karşılaştırma, self-heal ve görünürlüğün yokluğunu ölçer — bağlamak bir sonraki adım |
| MinIO / barman nesne deposu | — | Yedeği açmak bir YAML bloğudur; asıl iş geri yükleme tatbikatıdır. P09-06 "replikasyon yedek değildir" dersini ve bu seçimi anlatır |
| Linkerd, Gateway API, VPA, Redis HA (Sentinel/Valkey), gRPC | ingress-nginx; tek Redis + pod içi L1 | 14'ün "yolun devamı" listesi: 14 kapasiteyi ve korumaların birlikte davranışını ölçer, bileşen kataloğu kurmaz |
| Trivy, cosign, OIDC (Dex) | API anahtarı; konteyner sertleştirme (P13-08) | 13'ün dersi kimlik doğrulama ve sertleştirmenin kendisi; protokol/araç seçimi değil (13 §9) |

### 2.1.1 Ortam notları (kind + Docker Desktop + kurumsal ağ)

Merdiven bir laptop VM'inde koşar; platform, bu ortamın kendine has davranışlarını baştan hesaba katar:

| Ortam özelliği | Belirti (önlem olmadan) | Platformun cevabı |
|---|---|---|
| Kurumsal TLS araya girmesi (Cloudflare Gateway / Zscaler) | Node'lar image çekemez: `x509: certificate signed by unknown authority` | `platform/kind/trust-ca.sh` — kök CA'yı canlı el sıkışmadan çıkarıp her node'un güven deposuna kurar, containerd'yi yeniler. `make cluster` otomatik çağırır; kurumsal ağ dışında hiçbir şey eklemez |
| kind port map'i yalnızca control-plane'de | ingress-nginx başka node'a düşerse host'tan 80'e bağlanılır ama yanıt gelmez | `manifests/ingress-nginx-patch.yaml` — `nodeSelector: ingress-ready=true` + control-plane toleration |
| cAdvisor `container` label'ı üretmez (cgroup v1) | `container!=""` filtreli PromQL sorguları BOŞ döner | Sorgular `image!="",image!~".*pause.*"` filtresiyle yazılır (label'ın olduğu ortamlarda da çalışır) |
| `container_cpu_cfs_throttled_*` metriği yok | Throttling paneli boş | Ortam sınırı olarak işaretli; P07-04 throttling'i dolaylı ölçer (aynı yükte limitli/limitsiz p99 farkı) |
| 6 çekirdeği dört düğüm paylaşır | Lease yazması 25 sn'ye çıkar; varsayılan kirayla controller'lar kirayı kaybedip yeniden başlar | `kind/cluster.yaml` ve operatörlerde lider kirası 60/45 sn |
| Tek VM'de her operatör birden | ~5.6/6 çekirdek boşta; swap, NotReady düğümler | `make up`'ın ilk adımı profil: seviyenin kullanmadığı bileşenler kapanır (§2.2) |
| Docker Desktop yeniden başlatması | Tüm pod'lar `Unknown`, kubelet yeniden senkronize olana kadar | `cd "$LADDER/platform" && make start` API sunucusunu ve düğümleri bekler; `make up` tekrar koşulabilir |

### 2.2 Kurulum hedefleri ve profil (16 GB Mac gerçeği)

Docker Desktop'a **6 CPU / 10 GB** ver. Aynı anda tek seviye çalıştır (`make down` alışkanlığı).

| Hedef (`platform/Makefile`) | Seviyeler | İçerik |
|---|---|---|
| `minimal` | 00–01 | cluster (Calico, registry, CA) + core (ingress-nginx, metrics-server) + obs (kube-prometheus-stack, Loki, Alloy, dashboard'lar) |
| `standard` | 02–10 | + Chaos Mesh, KEDA, CNPG operatörü |
| `full` (önerilen) | 11–14 | + Tempo (+ Alloy OTLP), Argo CD + Rollouts, cert-manager + sealed-secrets + Kyverno |

Kurulum bir kez yapılır; hangi bileşenin **çalışacağına** her seviyede `make up`'ın ilk adımı olan profil
(`platform/lib/profile.sh`) karar verir: Chaos Mesh 02+, CNPG 09+, Loki/Alloy/Tempo yalnızca 11, Argo 12+,
cert-manager/Kyverno 13+; KEDA hep açık (park edilmesi namespace silmeyi kilitler), Grafana varsayılan açık.
Kullanılmayan bileşen 0 replikaya iner; seviyenin istediği bir bileşen hiç kurulmamışsa profil hangi komutla
kurulacağını söyleyip durur. Sıkışırsa: kind'ı 1 cp + 2 worker'a düşür.

### 2.3 Ortak Make hedefleri (`ladder.mk` — her seviyede aynı)

```
make up            # profil → build → push(local registry) → kubectl apply -k deploy/ → wait → smoke → Grafana linki
make down          # namespace sil (önce CNPG nesneleri, finalizer'larıyla)
make status        # pod/servis/ingress/hpa
make load S=mixed  # platform/k6/scenarios/<S>.js; level tag'i ile Prometheus'a yazar (aynı senaryolar her seviyede)
make repro P=P02-01               # problems/P02-01.sh (adımları basar, ölçer, REPRODUCED/NOT-REPRODUCED)
make chaos C=pg-delay-2s          # platform/chaos/<C>.yaml'ı bu namespace'e uygular (make unchaos)
make grafana                      # Grafana'nın "Ladder" klasörünü açar (ingress üzerinden: grafana.localtest.me)
make env | set E=… | unset E=… | reset   # alıştırma ayarları: göster / ver / sil / manifest'teki hâline döndür
make logs                         # kubectl logs -f, seviyenin tüm uygulama konteynerleri
make diff-prev                    # diff -ruN ../<önceki> . (README, go.sum, problems, bin hariç)
make verify-prev                  # önceki seviyenin problems/*.sh'sini bu namespace'e koşar
make test | lint                  # go test -race ./... | go vet + iskelet lint
```

### 2.4 `problems/*.sh` kontratı

- Girdi: `NS`, `BASE_URL`, `PROM_URL`, `GRAFANA_URL`, `LADDER_ROOT` env; `CONFIRM=1` yıkıcı adımlar için zorunlu.
- Çıktı: adımları yazar, gözlemi ölçer (k6 özet / PromQL sorgusu / curl sayımı), son satır
  `REPRODUCED` (exit 0) ya da `NOT-REPRODUCED` (exit 1). Ölçemediğini anlayan script exit 2 (SKIPPED) verir.
- `--explain` README'deki ilgili bölümü basar.
- Ölçüm için Prometheus HTTP API (`/api/v1/query`) kullanılır; böylece "Grafana'da gördüğün"
  ile "script'in ölçtüğü" aynı PromQL'dir.

`tools/ladder-matrix` bütün scriptleri bütün seviyelere koşup kök README'deki matrisi üretir
(uzun sürer: seviyeleri sırayla ayağa kaldırır; yıkıcı deneyler seri koşar).

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
`create · redirect · mixed · steady · hot-key · burst · abuser · read-your-writes · stairs · scan`.
Senaryo seviyeyi bilmez; `BASE_URL` ve `LEVEL` tag'i alır. Aynı `make load S=redirect`'i 02'de ve
04'te koşup `postgres` dashboard'unda DB qps'i kıyaslamak merdivenin temel egzersizidir.

**Chaos şablonları tek yerde (`platform/chaos/`), `NS` ile parametreli:**
`pg-delay-200ms · pg-delay-2s · pg-loss-30 · pg-loss-50 · redis-delay-200ms · redis-delay-3s · redis-kill ·
redpanda-delay · consumer-kill-30s · replica-delay · pod-kill-app · node-freeze`. Şablonun ilk satırı hedef
etiketi taşır; o etiket bu seviyede pod bulmuyorsa `make chaos` "bu seviyede hedef yok" der ve çıkar.

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
| 07 | `07-services-autoscaling` | Servisleri ayır, otomatik ölçekle | redirect/api/analytics servisleri, HPA, KEDA | Tek deployment iki profil | Darboğaz DB/Redis'e taşınır, throttling, cold start |
| 08 | `08-rate-limiting` | Gürültülü komşu | Redis'te dağıtık limiter, ingress limit, XFF | Pod başına yanlış limit | Limiter'ın kendi bağımlılığı, fail-open/closed |
| 09 | `09-database-scaling` | Veritabanı darboğazı | CNPG primary+replica, Pooler (rw/ro), okuma/yazma ayrımı, partition | Pool, SPOF, okuma yükü | Replikasyon gecikmesi, read-your-writes |
| 10 | `10-resilience` | Hata izolasyonu | timeout bütçesi, retry+jitter, breaker, bulkhead, shedding, chaos | Kaskad çökmeler | Ayar karmaşıklığı |
| 11 | `11-observability-deep` | Neden yavaş? | OTel trace, exemplar, log↔trace, SLO, burn-rate alarm, pprof | "Hangi hop?" sorusu | Sampling, kardinalite, alarm yorgunluğu |
| 12 | `12-delivery` | Güvenli dağıtım | Argo Rollouts canary + analiz, expand/contract | Kötü sürüm %100'e gider | Migration/rollback uyumu, drift |
| 13 | `13-security-tenancy` | Kim, neye, ne kadar | API key, RLS, NetworkPolicy, Kyverno, SSRF koruması, konteyner sertleştirme | Header ile tenant, açık ağ | Operasyonel sürtünme |
| 14 | `14-modern` | Son hal | L1+L2 + pub/sub geçersiz kılma, 3 partition, kapasite modeli, game day | Kalanlar | "Yolun devamı" listesi |

---

## 4. Seviye seviye detay

Her seviye için: amaç → çözülenler → eklenenler → **sorunlar tablosu** (ID · belirti · reproduce · Grafana sinyali · çözüm) → seviye içi alıştırmalar → bilerek bırakılanlar.
Tablolar kataloğun özetidir; her sorunun adım adım üretimi, ölçüsü ve Grafana yolu seviyenin README §6'sındadır.
**TRAP_…** = sorun o bayrakla açılan seviye içi alıştırmadır (varsayılan kapalı; `make repro` açıp kapatır).

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
| P00-07 | Sunucu timeout'u yok (slowloris): yarım bağlantılar hiç kapanmaz | port-forward ile doğrudan pod'a 300 yarım bağlantı; sunucu boşta kalanı hiç kapatmaz | CPU düşük, goroutine sayısı yok — "kör nokta" dersi | 01 |
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
(Prometheus: RED + go runtime + iş metrikleri, hepsi sıfırla pre-register; `slog` JSON;
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
| P01-03 | Tek replika + PDB = güvenlik yanılsaması: drain ya PDB'ye takılır ya zorlanınca kesinti | `kubectl drain <uygulamanın düğümü>` k6 altında | availability paneli, kesinti saniyesi | 02 |
| P01-04 | Bellek büyümesi görünür ama çözümsüz | k6 create sürekli | `go_memstats_heap_alloc_bytes` merdiven gibi | 02 · 03 |
| P01-05 | Süreç içi rate limit N pod'da N kat gevşer | (02'de reproduce) | — | 08 |
| P01-06 | **TRAP_METRIC_LABEL_CODE**: kısa kodu metrik label'ı yaparsan kardinalite patlar | bayrak açık, 100 k link | `prometheus_tsdb_head_series` fırlar, Grafana yavaşlar | seviye içi |
| P01-07 | **TRAP_LIVENESS_STRICT**: sağlık ucu zincirin (hız sınırlayıcının) arkasında → yükte restart fırtınası | bayrak açık + k6 burst | probe reddedilir → restart → kalan pod'a daha çok yük | seviye içi |
| P01-08 | Click sayacı hâlâ istek yolunda ve bellekte | — | `clicks_total` da restartta sıfırlanır | 05 · 06 |

---

### 02 — `02-postgres` · "Kalıcılık ve yatay ölçek"

**Amaç:** Durumu sürecin dışına çıkar. Uygulama stateless olunca N replika, drain, rollout
sorunsuz. Ama artık *her* istek ağ üzerinden DB'ye gidiyor.

**Çözülenler:** P00-02/P01-01, P00-03/P01-02, P01-03 (3 replika + PDB + anti-affinity), P01-04, P01-08 (kısmen).
**Kod:** `pgx/v5` pool, `goose` embedded migration, `INSERT … ON CONFLICT DO NOTHING` + retry ile kod
üretimi, `ListByTenant` (index'siz — bilerek), click sayacı senkron `UPDATE links SET clicks=clicks+1` (bilerek).
Pool metrikleri (`acquire_count`, `acquire_duration`, `empty_acquire`) expose edilir.
**Deploy:** Postgres 17 StatefulSet + postgres-exporter sidecar (operator yok — bilerek), app 3 replika, şema `cmd/migrate` Job'uyla (migration'ı her pod'da koşmak P02-07'nin tuzağı).
**Grafana'da yeni dolanlar:** `postgres` (connections vs max, tps, seq scan, locks, pool acquire).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P02-01 | Her redirect = DB sorgusu | `make load S=redirect` 2 k rps | PG CPU %100, p99 yükselir; `pg_stat_statements` tepe SELECT | 03/04 |
| P02-02 | Bağlantı havuzu taşması: 10 replika × pool 25 > `max_connections=100` | `scale --replicas=10` + load | `pg_stat_activity_count` tavana; app 503 (`too many clients`) | 09 (Pooler) |
| P02-03 | DB tek nokta; failover yok | `kubectl delete pod postgres-0` | 30–60 s %100 hata | 09 |
| P02-04 | Per-pod rate limit: 10 rps × 3 pod ≈ 30 rps geçer, dağılım dengesizse adaletsiz | k6 tek IP, kabul edilen rps ölç | `ratelimit_allow` pod bazlı | 08 |
| P02-05 | Index yok → seq scan; 1 M satırda `list` saniyeler sürer | `generate_series` ile seed; list çağır | `pg_stat_user_tables_seq_scan` | seviye içi (migration 002) |
| P02-06 | Yavaş sorgu + timeout yok → havuz dolar → kaskad | `make chaos C=pg-delay-2s` | pool `empty_acquire` artar, readiness düşer | `statement_timeout` (seviye içi) · 10 |
| P02-07 | **TRAP_MIGRATE_IN_MAIN**: migration'ı N pod aynı anda koşar → kilit hatası/yarış | tuzakla sıfırdan çok replikalı deploy | crash loop ilk saniyeler | seviye içi (Job) |
| P02-08 | Senkron click `UPDATE` → hot link'te satır kilidi kuyruğu, WAL şişmesi | `make load S=hot-key` 500 VU tek kod | `pg_locks`, redirect p99, WAL bytes | 05 · 06 |
| P02-09 | Sır düz metin (git + Secret + env) | `kubectl get deploy -o yaml`, git | — | 13 |
| P02-10 | **TRAP_READYZ_CHECKS_DB**: readiness bağımlılığı kontrol edince kısmi arıza TAM kesinti olur | tuzağı aç + DB'yi yavaşlat | hazır pod sayısı, 5xx | seviye içi (readiness ≠ bağımlılık sağlığı) · 10 |

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
| P03-05 | **TRAP_NO_SINGLEFLIGHT**: TTL dolan hot key'de stampede | bayrak + hot-key load + `C=pg-delay-200ms` | DB qps ani tepe, `cache_stampede_wait`=0 | seviye içi |
| P03-06 | **TRAP_NO_NEGATIVE_CACHE**: yok olan kod taraması hep miss → DB | `k6 scan` (KEYS ile sınırlı bir yok-kod havuzu) | `cache_miss` = DB qps | seviye içi |
| P03-07 | **TRAP_NO_TTL_JITTER**: aynı anda yazılan anahtarlar aynı anda dolar → periyodik DB tepesi | tuzağı aç, 1 sn çözünürlükle örnekle | tepe/ortalama DB qps | seviye içi (jitter) |

---

### 04 — `04-redis-cache` · "Paylaşılan önbellek"

**Amaç:** Cache'i tek yere taşı; tutarlılık ve soğuk cache biter, ama cache artık ağda ve
kendisi bir bağımlılık.

**Çözülenler:** P03-01..04.
**Kod:** `go-redis/v9`, cache-aside `GET/SET EX/DEL`, TTL jitter, negative cache, per-pod singleflight; cache hatası = fatal **değil** (log + metric + DB'ye düş). `/debug/keys` ucu `TRAP_DEBUG_KEYS` açıkken `KEYS *` çalıştırır (P04-07).
**Deploy:** Redis 7 StatefulSet + redis_exporter, `maxmemory 64mb`, policy `noeviction` (bilerek).
**Grafana'da yeni dolanlar:** `redis`; `cache` panelinde L2 satırı.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P04-01 | Redis düşünce her şey DB'ye düşer → P02-01 geri gelir (ya da fallback yoksa 500) | `delete pod redis-0` k6 altında | `redis_up`=0, DB qps tepe | 10 · 14 (L1) |
| P04-02 | +1 ağ RTT: p50 03'e göre yüksek | 03 ve 04 p50 panelini yan yana | latency karşılaştırma | 14 (L1+L2) |
| P04-03 | Hot key: tek link trafiğin %50'si → tek Redis CPU | `make load S=hot-key` | `redis_cpu`, komut/s tavan | 14 (L1) |
| P04-04 | **TRAP_NO_TTL_JITTER**: deploy sonrası tüm anahtarlar aynı anda dolar → DB tepe | bayrak; 60 s bekle | DB qps periyodik tepe | seviye içi |
| P04-05 | Cache-aside yarışı: okuma-doldurma sürerken silinen kayıt önbelleğe bayat olarak geri yazılır | `TRAP_READ_FILL_DELAY_MS` ile pencereyi büyüt, doldurma sırasında DELETE | stale redirect sayısı | tartışma (versiyonlu anahtar) |
| P04-06 | `maxmemory` + `noeviction` → `OOM command not allowed` → yazmalar sessizce durur | `maxmemory` 4 MB'a indir, ~6 KB'lık URL'lerle doldur | `redis_memory_used_bytes` tavan, `cache_load_error` | seviye içi (`allkeys-lru`) |
| P04-07 | **TRAP_DEBUG_KEYS**: `/debug/keys` → `KEYS *` Redis'i kilitler, tüm redirect'ler bekler | Redis'e 300 bin anahtar (Lua, tek komut), yük altında uç 20 sn boyunca aralıksız çağrılır | Redis latency tepe | seviye içi (`SCAN`/sayaç) |

---

### 05 — `05-async-analytics` · "Yazmayı okuma yolundan çıkar"

**Amaç:** Click kaydı redirect'i asla bekletmesin. En ucuz asenkron: süreç içi bounded kuyruk +
batch yazıcı. Kayıp ve back pressure ile tanışırız.

**Çözülenler:** P02-08.
**Kod:** `internal/analytics` (linkly'den: bounded channel, batch/flush, drop metriği), `clicks_daily (code, day)` toplam tablosu, `GET /api/links/{code}/stats`. Shutdown sırası: server → drain queue → DB.
**Grafana'da yeni dolanlar:** `analytics` (enqueued/dropped/written, queue depth, **k6 tıklama − DB tıklama** farkı).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P05-01 | At-most-once: sert ölümde tampondakiler kaybolur | flush aralığını uzat, redirect yükü altında pod'ları grace 0 ile öldür; k6 sayısı vs DB | "gap" paneli | 06 |
| P05-02 | Kuyruk dolunca drop (görünür); **TRAP_UNBOUNDED_QUEUE** ile OOM | `ANALYTICS_QUEUE_SIZE=500` + `C=pg-delay-2s` + hot-key yükü; bayrakla OOMKilled | `analytics_dropped`; working set | 06 · 07 |
| P05-03 | Analitik yazımı redirect ile aynı pod ve aynı DB havuzunda yarışır | click burst → redirect p99 | p99 vs write batch | 06 · 07 |
| P05-04 | Toplama ölçeklenir, ayrıntı ölçeklenmez: tıklama başına satır tutmanın bedeli | geçici bir `clicks_detail` tablosu doldur, toplam tabloyla kıyasla | stats latency | 09 (partition) |
| P05-05 | `terminationGracePeriodSeconds` kısa → drain yarım kalır | 5 s'ye çek, rollout | gap artar | seviye içi |
| P05-06 | **TRAP_REDIRECT_301**: tarayıcı 301'i önbellekler → click sayılmaz | Chrome'da 5 kez aç → DB'de 1 | `redirect_ok` vs gerçek | seviye içi (302/307) |

---

### 06 — `06-event-stream` · "Olay akışı, ayrı tüketici"

**Amaç:** Click olaylarını broker'a yaz, ayrı bir consumer deployment tüketsin. Dayanıklılık
gelir; teslimat semantiği (duplicate, lag, poison) ile ödenir.

**Çözülenler:** P05-01, P05-03. P05-02 (kuyruk düşürme) bilerek listede yok: sorun kaybolmaz, bir kat aşağı — producer tamponuna — taşınır (P06-05).
**Kod:** `franz-go` producer (async buffer, `acks=all`, shutdown'da flush; redirect asla bloklanmaz), `cmd/analytics-consumer` (grup, batch, DB'ye yaz **sonra** commit — at-least-once), event şeması JSON+`event_id`.
**Deploy:** Redpanda 1 broker (seviyenin `deploy/`'unda StatefulSet) + `topics` Job, topic `clicks` 1 partition (bilerek).
**Grafana'da yeni dolanlar:** `stream` (produce rate, buffer, consumer lag, commit rate, duplicate, DLQ).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P06-01 | En az bir kez → tekrar teslim: consumer yazdıktan sonra commit'ten önce ölürse | `TRAP_COMMIT_DELAY_MS` ile pencereyi aç, yük altında consumer'ı 0'a ölçekle; k6 vs DB | duplicate paneli (>0) | seviye içi: idempotent consumer (`event_id` upsert) |
| P06-02 | Consumer lag: yavaş/ölü consumer → stats bayat | `scale consumer --replicas=0` | lag paneli büyür | 07 (KEDA) |
| P06-03 | 1 partition = 1 tüketici; consumer'ı 3'e çıkarmak işe yaramaz | scale 3, lag değişmez | partition-consumer paneli | seviye içi (repartition) + sıralama tartışması |
| P06-04 | **TRAP_NO_DLQ**: poison message → consumer crashloop, lag sonsuza | `rpk topic produce` ile bozuk JSON | restarts + lag | seviye içi (DLQ topic + skip) |
| P06-05 | Broker düşünce producer buffer dolar: bloklamak mı düşürmek mi? | redpanda StatefulSet'i 0'a ölçekle (`PRODUCER_MAX_BUFFERED` ile) | `producer_buffer`, redirect p99 (bloklarsa!) | seviye içi (asla bloklama) · 14 |
| P06-06 | **TRAP_COMMIT_BEFORE_WRITE**: commit noktası = teslimat garantisi (yazmadan önce commit → at-most-once kayıp) | bayrak + consumer'ı pencerede öldür | kayıp vs duplicate | seçim meselesi |
| P06-07 | Şema evrimi: bilinmeyen sürüm → eski consumer ne yapar? | v2 producer, v1 consumer | hata oranı | seviye içi (sürüm alanı); şema kayıt defteri yolun devamı |

---

### 07 — `07-services-autoscaling` · "Servisleri ayır, otomatik ölçekle"

**Amaç:** Okuma yolu (redirect) ile yazma/yönetim yolu (api) ve tüketici (analytics) farklı
ölçek profillerine sahip → ayrı deployment'lar, ayrı ölçekleme. İskelet aynı: `cmd/` altında üç servis (+ `migrate`), `deploy/` altında üç Deployment.

**Çözülenler:** P06-02 (KEDA Kafka lag).
**Kod:** `cmd/redirect-svc`, `cmd/api-svc`, `cmd/analytics-consumer`, `cmd/migrate`, `internal/` paylaşımlı; `TRAP_LIST_N_PLUS_ONE` açıkken api-svc list ucu her link için ayrı bir stats sorgusu atar (N+1).
**Deploy:** üç Deployment + migration Job; redirect'te HPA (CPU %60, 2–12 replika), analytics'te KEDA `ScaledObject` (Kafka lag); sıkı CPU limit (bilerek); redirect'te `topologySpreadConstraints` (`ScheduleAnyway`).
**Grafana'da yeni dolanlar:** `autoscaling`; `pods-resources` throttling satırı; `app-red` servis bazlı.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P07-01 | HPA gecikir: burst → 60–90 s pod yok → latency penceresi | `k6 burst` | HPA paneli vs p99 | seviye içi (tampon: min replika, hedef) |
| P07-02 | Ölçekleme darboğazı DB'ye taşır | HPA ölçeklerken yük | PG CPU tavan, app boş | 09 |
| P07-03 | Yeni pod hazır ama havuz/cache soğuk → ilk istekler yavaş | scale-out anında p99 | pod-yaş vs latency | seviye içi (warm-up, readiness) |
| P07-04 | CPU limit sıkı → throttling; CPU %50 görünürken p99 fırlar | `make load S=mixed` | `container_cpu_cfs_throttled_seconds_total` | seviye içi (limit kaldır/artır) |
| P07-05 | Node kapasitesi bitti → Pending; kind'da autoscaler yok | `kubectl scale` ile kapasitenin üstüne | `kube_pod_status_phase{Pending}` | tartışma (bulutta cluster autoscaler/Karpenter) |
| P07-06 | **TRAP_LIST_N_PLUS_ONE**: maliyet sonuç kümesiyle orantılı — 100 link'lik list = 100 stats sorgusu | bayrak + list ucu p99 | sorgu sayısı | seviye içi (toplu sorgu) · 14 |
| P07-07 | Node donunca yedeklilik işe yaramaz | `docker pause <uygulamanın düğümü>`; 40 s NotReady, 5 dk evict | availability | 10 |
| P07-08 | **TRAP_READY_ALWAYS**: her zaman hazır diyen probe → bozuk pod trafik alır | bayrak + DB'siz pod | 500'ler | seviye içi |

---

### 08 — `08-rate-limiting` · "Gürültülü komşu"

**Amaç:** Bir kötü/aç client diğerlerini yavaşlatmasın. Redis'te dağıtık limiter (Lua kayan
pencere; `TRAP_FIXED_WINDOW` ile sabit pencere), tenant ve IP bazlı, `429 + Retry-After`; ingress'te ilk hat.

**Çözülenler:** P01-05/P02-04 borcu (dağıtık limiter). `problems/SOLVES` gerekçeli boş: `verify-prev` yalnızca
bir önceki seviyenin (07) scriptlerini koşar ve 08 onların hiçbirini çözmez.
**Kod:** `internal/ratelimit/redis.go` (Lua script atomik), anahtar: IP / tenant / global; XFF'e yalnızca güvenilen hop sayısı kadar sağdan güven (`TRUSTED_PROXY_HOPS`; `TRAP_IGNORE_XFF` / `TRAP_TRUST_ANY_XFF` bilerek var).
**Deploy:** Ingress annotasyonları `limit-rps` + `limit-burst-multiplier`. XFF davranışı Ingress'te değil, controller ConfigMap'inde (`platform/manifests/ingress-nginx-config.yaml`).
**Grafana'da yeni dolanlar:** `ratelimit` (artık anahtar bazlı, dağıtık).

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P08-01 | Limiter Redis'e bağımlı: Redis yokken fail-open mı fail-closed mı? | Redis'i sil | 429 oranı 0 ya da %100 | karar (fail-open) + alarm (11) |
| P08-02 | Her isteğe +2 Redis gidiş-gelişi (tenant + IP) | 04 vs 08 p50 | latency | seviye içi (pipeline) |
| P08-03 | **TRAP_IGNORE_XFF / TRAP_TRUST_ANY_XFF**: XFF'i yok saymak limiti ADALETSİZ (herkes tek kova), körü körüne güvenmek ETKİSİZ (spoof ile atlatılır) yapar | iki tuzak + abuser senaryosu | 429 dağılımı, key_type | seviye içi (güven sınırı: sağdan hop say) |
| P08-04 | Sabit pencere (`TRAP_FIXED_WINDOW`): sınırda 2× burst geçer | `make load S=burst` (pencere sınırına hizalı) | kabul edilen/s tepe | seviye içi (kayan pencere) |
| P08-05 | **TRAP_GLOBAL_LIMIT**: global limit anahtarı = Redis hot key | bayrak + load | Redis CPU | seviye içi (anahtar parçalama) |
| P08-06 | Gürültülü komşu izole ediliyor mu? Büyük müşteri vs abuser | 2 tenant senaryosu | tenant bazlı p99 | 13 (tier kotaları) |

---

### 09 — `09-database-scaling` · "Veritabanı darboğazı"

**Amaç:** DB'yi operatörle yönet: primary + replica, otomatik failover, PgBouncer Pooler,
okuma/yazma ayrımı, günlük partition'lar. Yedek/PITR bilerek yapılandırılmaz (P09-06).

**Çözülenler:** P02-02 (Pooler), P02-03 (failover); P07-02 büyük ölçüde (okumalar replikaya).
**Kod:** iki pool (`-rw`, `-ro`), okuma tercihi ayarı; yazmadan sonra kısa bir süre primary'den okuma (sticky pencere — P09-01'in çözümü, `TRAP_NO_STICKY` ile kapanır).
**Deploy:** CNPG `Cluster` (2 instance), iki `Pooler` (`pg-pooler-rw` / `pg-pooler-ro`, transaction mode), `processed_events` günlük RANGE partition. Nesne deposu ve yedek yok — P09-06 nedenini anlatır.
**Grafana'da yeni dolanlar:** `postgres` replication lag / failover satırları; `app-business` RYW ihlal sayacı.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P09-01 | Replikasyon gecikmesi → **read-your-writes ihlali**: oluştur → hemen redirect → 404 | replikada `pg_wal_replay_pause()` + `TRAP_NO_STICKY` + `k6 read-your-writes` | RYW ihlal sayacı, lag | seviye içi (sticky okuma penceresi) |
| P09-02 | Failover penceresi: primary ölür → 10–30 s yazma hatası ya da asılı kalan yazma; app'in yeniden bağlanması | `delete pod <primary>` | 5xx, yazma p99, küme durumu (healthy → failing over → healthy) | 10 (retry + idempotency) |
| P09-03 | **TRAP_PREPARED_STATEMENTS**: transaction pooling + pgx prepared statements → `prepared statement … does not exist` | bayrakla Pooler üzerinden | 500 oranı | seviye içi (`default_query_exec_mode=exec`) |
| P09-04 | Uzun okuma replikada iptal: `canceling statement due to conflict with recovery` | uzun list + yoğun yazma | hata logu | tartışma (`hot_standby_feedback`) |
| P09-05 | Silme pahalı: partition'sız retention | eski günleri `DELETE` ile vs partition `DROP` ile sil | süre, WAL, dead tuple | seviye içi (partition) |
| P09-06 | Replikasyon yedek değildir: primary'de silinen veri replikadan da gider | primary'de sil → replikada ara | — | yolun devamı: WAL arşivi + base backup + geri yükleme tatbikatı (bir `barmanObjectStore` bloğu; asıl iş tatbikat) |

---

### 10 — `10-resilience` · "Hata izolasyonu"

**Amaç:** Bağımlılık kısmen bozulduğunda sistem *kısmen* bozulsun, tamamen değil. Her
deney önce "koruma kapalı" ile kaskadı gösterir, sonra "açık" ile kıyaslar.

**Çözülenler:** P04-01; P02-06 ve P09-02'nin etkisi büyük ölçüde emilir.
**Kod:** uçtan uca `context` deadline bütçesi, retry (exp backoff + jitter + retry budget), kendi devre kesicisi (`internal/resilience`), bağımlılık başına semaphore (bulkhead), load shedding (in-flight limiti → hızlı 503), degrade modları (Redis yok → DB'ye sınırlı eşzamanlılık; DB yok → cache'ten redirect, create 503). Readiness: **sadece kendi** durumu; bağımlılık sağlığı metrik olarak.
**Deploy:** arızalar paylaşılan `platform/chaos/` şablonlarından (`make chaos C=`); her deney önce korumasız, sonra korumalı koşar.
**Grafana'da yeni dolanlar:** `resilience`.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P10-01 | Retry fırtınası: %30 hata + 3 naive retry → 3× yük → tam çöküş | `TRAP_NAIVE_RETRY` + `C=pg-loss-30` | DB qps ×3, breaker yok | jitter + budget |
| P10-02 | Readiness bağımlılığa bağlı → Redis'te kısa kesinti → **tüm** pod'lar NotReady → endpoint 0 → tam kesinti | `TRAP_READY_CHECKS_REDIS` + Redis'i 10 s durdur | endpoint sayısı 0 | readiness = kendi durumu |
| P10-03 | Timeout hizasızlığı: client 1 s vazgeçer, sunucu 30 s çalışmaya devam eder → boşa iş | `C=pg-delay-2s` + k6 timeout 1 s | in-flight artar, DB yükü artar | context propagation |
| P10-04 | **TRAP_NO_BREAKER**: devre kesici yok / half-open flapping, eşik ayarı | `C=pg-loss-50` | breaker state timeline | seviye içi (ayar) |
| P10-05 | Yavaş bağımlılık, ölü bağımlılıktan beterdir: timeout yok → goroutine/bellek şişer → OOM | `TRAP_NO_DEP_TIMEOUT` + `C=redis-delay-3s` | goroutine sayısı, working set | dependency timeout |
| P10-06 | Load shedding yok → herkes yavaş; var → bazıları hızlı 503, kabul edilenlerin p99 sabit | `SHED_ENABLED` aç/kapa + `C=redis-delay-200ms` + stairs yükü | p99 (kabul) vs 503 oranı | shedding |

Liveness'ın yük altındaki davranışı 01'de (P01-07), readiness'ın bağımlılığa bağlanması burada (P10-02) ölçülür;
aynı tuzak iki seviyede koşturulmaz.

---

### 11 — `11-observability-deep` · "Neden yavaş?"

**Amaç:** "p99 yüksek" → "hangi servis, hangi hop, hangi sorgu?" Metrik + log + trace + profil
birbirine bağlı; alarm SLO'dan türetilir.

**Kod:** OpenTelemetry SDK (HTTP + pgx + redis + Kafka header propagation), exemplar'lı histogramlar, `slog` içine `trace_id`, iç portta (`:6060`, Service/Ingress yok) `net/http/pprof`, bilerek bir sıcak nokta (`TRAP_REGEX_PER_REQUEST`).
**Deploy:** Alloy (OTLP → Tempo; pod log'ları → Loki), elle yazılmış SLO kuralları (`deploy/slo.yaml`: redirect erişilebilirliği %99.9, kayıt kuralları + çok pencereli burn-rate alarmları), Alertmanager (alıcı tanımlı değil: alarmlar ateşler, kimseye gitmez — §9), dashboards-as-code (JSON repo'da, Grafana'da düzenleme kapalı).
**Grafana'da yeni dolanlar:** `slo`; `app-red` exemplar noktaları → Tempo; Loki'de `trace_id` linki.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P11-01 | "p99 yüksek, nerede?" | `C=redis-delay-200ms`; önce trace kapalı tahmin et, sonra Tempo | exemplar → trace | tracing |
| P11-02 | Kafka üzerinden trace kopar | `TRAP_NO_KAFKA_PROPAGATION` | analytics span'ları yetim | header propagation |
| P11-03 | %100 sampling 5 k rps'te collector/Tempo'yu boğar; head sampling nadir hataları kaçırır | sampling 1.0 + load | Alloy CPU, Tempo ingest | oran + tail-based tartışması |
| P11-04 | Eşik alarmı (`error>1%`) flapping; burn-rate alarmı sakin | `C=pg-loss-50` ile kısa hata dalgası | Alertmanager timeline | multi-window burn-rate |
| P11-05 | Debug log seviyesi yükte Loki'yi limitler (`429`/rate limit) | `LOG_LEVEL=debug` + load | Loki ingest reject | seviyeler + log sampling |
| P11-06 | **TRAP_TENANT_LABEL**: kardinalite — tenant id label, 10 k tenant | k6 10 k tenant | head series | seviye içi (label değil exemplar/log) |
| P11-07 | Elle düzenlenen dashboard drift eder | Grafana'da düzenle, `make up` | fark | dashboards-as-code |
| P11-08 | **TRAP_REGEX_PER_REQUEST**: CPU hot spot — istek başına regex derleme, panellerde yalnızca CPU artışı görünür | bayrak + yük; 20 sn CPU profili (pprof, `kubectl get --raw`) | sebep panelde yok; `regexp` kareleri profilde | profil (sürekli profil yolun devamı) |

---

### 12 — `12-delivery` · "Güvenli dağıtım"

**Amaç:** Kötü sürüm %100'e gitmesin, migration deploy'u kırmasın, kümedeki sapma görünür olsun.
Argo Rollouts canary (Prometheus analizli). `make up` yine kustomize; Argo bu seviyenin *konusu*. Argo CD kurulu
ama bilerek bir Application'a bağlanmaz: P12-03, sürekli karşılaştırma, self-heal ve görünürlüğün yokluğunu ölçer.

**Kod:** kötü sürüm `BAD_VERSION_ERROR_PCT` ortam değişkeniyle (redirect'lerin bir kısmı 500 döner); expand/contract migration örneği.
**Deploy:** `deploy/` aynı; redirect için Deployment yerine `Rollout` CR (canary 10 → analiz → 50 → 30 sn bekle → analiz; `AnalysisTemplate` `redirect-success-rate`: hata oranı ≤ %2, p99 ≤ 300 ms); api-svc düz Deployment.
**Grafana'da yeni dolanlar:** `rollout`.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P12-01 | Kötü sürüm rolling update ile %100'e gider | `BAD_VERSION_ERROR_PCT=25` ile yeni sürüm, yük altında | hata oranı | canary + analiz → otomatik geri alma |
| P12-02 | Kırıcı migration (kolon rename) rolling update sırasında eski pod'ları kırar | yük altında `ALTER TABLE links RENAME COLUMN url TO url_old` | 500'ler pencere | seviye içi (expand/contract) |
| P12-03 | Drift: elle yapılan değişiklik — kimse karşılaştırmaz, sessizce geri alınır | replicas'ı elle değiştir, sonra yeniden apply | "Hazır pod (sürüme göre)" 3 → 5 → 3; drift'in kendisi görünmez (Application yok) | Argo CD (kurulu, bağlanmamış) |
| P12-04 | `:latest` etiketi → belirsiz, geri alınamaz sürüm (doğrulama scripti: merdiven içerik hash'li etiket kullanır) | latest ile deploy | — | 13 (Kyverno) |
| P12-05 | Canary + cache anahtar formatı değişimi → karışık davranış | v2 anahtar öneki | cache miss tepe | tartışma (uyumlu anahtar) |
| P12-06 | App geri alındı, migration geri alınmadı | P12-02 sonrası rollback | — | tartışma + runbook |

---

### 13 — `13-security-tenancy` · "Kim, neye, ne kadar"

**Amaç:** Tenant sınırı header'dan değil kimlikten türesin; DB kendini korusun (RLS); ağ
varsayılan kapalı; policy engine kuralları uygulasın. Sır yönetimi ve tedarik zinciri kısmen kalır — neyin
eksik olduğu ölçülerek söylenir (P13-04, P13-08).

**Kod:** API key (sha256 hash'li, sabit zamanlı karşılaştırma, tenant'a bağlı; OIDC/JWT yok — §9), `internal/tenant` (context), RLS (`SET LOCAL app.tenant_id`), SSRF/open-redirect sertleştirme (DNS çözüp özel aralıkları reddet; TOCTOU sınırı README'de).
**Deploy:** NetworkPolicy (default deny + izin listesi), Kyverno `linkly-ladder-baseline` (Enforce: `disallow-latest-tag`, `require-memory-limit`, `require-probes`), konteyner sertleştirme (distroless, non-root, RO root fs, drop ALL). cert-manager ve sealed-secrets kurulu, bilerek kullanılmaz (TLS yok; sırlar düz metin — P13-04); imaj tarama/imza yok (P13-08).
**Grafana'da yeni dolanlar:** `security`.

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P13-01 | **TRAP_HEADER_TENANT**: `X-Tenant-ID` header → A, B'nin linkini siler | curl ile spoof | 403 yok | seviye içi (tenant = API key) |
| P13-02 | Tek sorguda unutulan tenant filtresi **sessiz** sızıntı | uygulama rolüyle (`SET ROLE linkly`) WHERE'siz sorgu | sonuçta yabancı satır | seviye içi (RLS: 0 satır) |
| P13-03 | Her pod Postgres/Redis'e erişir | `kubectl run busybox` → `nc redis 6379` | — | NetworkPolicy |
| P13-04 | Sırlar git'te düz metin (P02-09) | `kubectl get secret`, git log | — | kısmen (sealed-secrets kurulu, kullanılmıyor) |
| P13-05 | **TRAP_NO_DNS_CHECK**: `http://169.254.169.254/` ya da özel IP'ye çözülen host kabul edilir | curl | `create_rejected_unsafe` | seviye içi (DNS çözüm + blok; TOCTOU kalır) |
| P13-06 | Enumeration maliyeti: 404 taraması | k6 rastgele/ardışık | 404 oranı | kısmen (404 oranına özel limit yok) |
| P13-07 | README ≠ garanti: `:latest` / limitsiz pod deploy edilir | apply | Kyverno reject | seviye içi (Kyverno) |
| P13-08 | Konteyner/tedarik zinciri sertleştirme: shell, yazılabilir kök fs, capability'ler, root | pod'u denetle | — | kısmen (imaj tarama/imza yok) |

---

### 14 — `14-modern` · "Son hal"

**Amaç:** 01–13'ün tamamı tek sistemde + son kilometre: L1+L2 önbellek (pod LRU + Redis + pub/sub
geçersiz kılma), Redis `allkeys-lru`, `clicks` topic'i 3 partition (tüketici paralelliği gerçek olur), ölçülmüş
kapasite modeli ve bütün korumaları aynı anda sınayan bir game day.

**Ayrıca:**
- **Kapasite modeli** (`14-modern/docs-capacity.md`): SDP'nin zarf arkası hesabını *gerçek k6 ölçümleriyle* yap —
  redirect/pod, Redis ops/çekirdek, PG rps/replica; "1 M link/gün, 100 M redirect/gün için kaç pod?"
- **Game day** (P14-05): tek yük altında üst üste üç arıza — Redis gecikmesi, DB paket kaybı, pod öldürme;
  erişilebilirlik, breaker/shed/retry ve kalan hata bütçesi ölçülür.
- **Yolun devamı** (dürüst liste, 14 README §9): tek Redis (Sentinel/Valkey HA), tek broker/RF=1, tek
  cluster/tek bölge (multi-region aktif-aktif, DNS failover), cluster autoscaler, yedek/PITR + geri yükleme
  tatbikatı, gRPC, Gateway API + Linkerd, sürekli profil (Pyroscope), imaj tarama/imza, maliyet modeli.

**Sorunlar:**

| ID | Sorun | Reproduce | Ölçü | Çözüm |
|----|-------|-----------|------|-------|
| P14-01 | L1'in geri dönüşü: ağ adımını ödemeden isabet | L1 açık/kapalı p50 + Redis ops | p50, L1 hit oranı | seviye içi (L1+L2) |
| P14-02 | **TRAP_NO_INVALIDATION_PUBSUB**: her kopya bir geçersiz kılma kanalı borçlanır | sil → diğer pod'dan oku, pub/sub açık/kapalı | bayat yanıt sayısı | seviye içi (pub/sub + kısa TTL) |
| P14-03 | Partition tavanı kalktı: tüketici paralelliği gerçek | KEDA `paused-replicas=3` ile 3 tüketici + hot-key yükü | aktif tüketici, kayıt/s, lag | seviye içi (3 partition) |
| P14-04 | Kapasite modeli: zarf arkası hesabı ÖLÇÜLMÜŞ sayılarla | stairs ile tek pod kapasitesi | rps/pod, p99 | `docs-capacity.md` |
| P14-05 | GAME DAY: üç arıza üst üste | `k6 steady` altında `C=redis-delay-200ms` + `C=pg-loss-30` + pod kill | erişilebilirlik %, breaker/shed/retry, kalan hata bütçesi | prova |

---

## 5. Seviye README şablonu (`docs/LEVEL-TEMPLATE.md`)

Her README aynı 10 başlığı aynı sırada taşır; 4 ve 5 **her seviyede kelimesi kelimesine aynıdır**
(`make up` → `curl` → `make grafana`; API kontratı linki). Değişen içerik 1–3 ve 6–10'dadır.

```
# NN — <ad> · "<slogan>"
> Giriş bloğu: Bu seviyede ne yaşayacaksın? · Bu seviye olmasa ne olur? · Yeni gelen teknolojiler
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
**Belirti:** app 503 döner, Postgres `FATAL: sorry, too many clients already` der.
**Neden:** 10 replika × pool 25 = 250 > max_connections=100. Her pod kendi havuzunu "tek başınaymış gibi" boyutlar.
**Reproduce (adım adım):**
  1. `make up` (3 replika, sağlıklı)
  2. `make load S=redirect` (ikinci terminalde, 2 dk)
  3. `kubectl -n lvl02 scale deploy/linkly --replicas=10`
  4. 20–30 s içinde k6 `http_req_failed` > 0; `make repro P=P02-02` aynı adımları otomatik koşar ve ölçer
**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now&refresh=10s) — script 10 replikaya çıkınca aç (giriş: admin / ladder)
- "Bağlantılar ve üst sınır" → bağlantı çizgileri yükle tırmanır ve 100'deki `üst sınır` çizgisine yapışır
**Nerede çözülüyor:** 09 (Pooler). Geçici çare: pool'u 100/replika'ya böl — ama replika sayısı değişince tekrar bozulur.
```

`tools/lint-grafana.py` her `**Grafana'da gör:**` bloğunun var olan dashboard'lara ve panellere işaret ettiğini denetler.

**API kontratı** (her seviyede aynı; sonradan eklenenler işaretli):
`POST /api/links` · `GET /{code}` (302) · `GET /api/links/{code}` · `DELETE /api/links/{code}` ·
`GET /api/links` (02+) · `GET /api/links/{code}/stats` (05+) · `/healthz /readyz /metrics` (01+).
Tenant: `X-Tenant-ID` (02–12, README'de "kimlik değildir" uyarısıyla) → API key (13+).

**Metrik adları** (01'den itibaren sabit; dashboard'lar seviyeler arası kıyaslanabilir olsun):
`http_requests_total{route,method,code}`, `http_request_duration_seconds`, `redirect_*`, `create_*`,
`cache_*`, `ratelimit_*`, `analytics_*`, `dependency_request_duration_seconds{dep}`, `breaker_state{dep}`.

---

## 6. Kararlar

| # | Karar | Seçilen | Alternatif (neden değil) |
|---|---|---|---|
| 1 | Broker | Redpanda (tek binary, laptop dostu, Kafka API) — ADR-0001 | Strimzi Kafka (gerçek dünyaya en yakın, ağır), NATS JetStream (Kafka semantiği değil) |
| 2 | 02'de Postgres | Düz StatefulSet (operatör *ihtiyacını* 09'da yaşamak için) | CNPG baştan |
| 3 | Deploy aracı | Her seviyede kustomize (`kubectl apply -k deploy/`); Argo Rollouts 12'de *konu*, `make up` değişmez — ADR-0002 | Araç merdiveni (YAML→Kustomize→Helm): tekdüzeliği bozar |
| 4 | k6 | Mac'te, ingress'e, Prometheus remote-write | k6-operator cluster içinde |
| 5 | Repo | Tek repo `linkly-ladder`, seviye = Go modülü, `go.work` | Seviye başına repo |
| 6 | Mevcut `linkly` | Dokunma; paket kaynağı olarak kullan | Merdivene taşı |
| 7 | SLO kuralları | 11–14 `deploy/slo.yaml`'da elle yazılmış PrometheusRule | Sloth: burn-rate matematiğini bir üretecin arkasına saklar |
| 8 | Log/trace yığını | Kurulu; profil yalnızca 11'de açar | Her seviyede açık: 6 çekirdekli VM'de ölçülen sistemden bütçe çalar |
| 9 | 14'ün kapsamı | Kapasite modeli + game day; gRPC, Linkerd, Gateway API, Redis HA "yolun devamı" | Hepsini kurmak: ölçülmüş bir tavan yerine bir bileşen kataloğu |
| 10 | Kimlik (13) | API key (sha256, sabit zamanlı karşılaştırma) | OIDC/JWT (Dex, Keycloak): ders kimlik doğrulamanın kendisi, protokol seçimi değil |
