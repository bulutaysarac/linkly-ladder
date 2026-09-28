# Kullanılan araçlar

Bu projede geçen her araç için üç şey: **ne olduğu**, **burada ne işe yaradığı** ve **kendi gözünle nasıl
görebileceğin**. **İlk** sütunu aracın hangi seviyede sahneye çıktığını söyler; "kurulum" yazanlar
platformla (`cd "$LADDER/platform"` → `make full`) gelir ve her seviyede arka planda çalışır.

Komutlar seviye numarası taşıyorsa (`lvl07` gibi) o seviye kuruluyken çalışır. Adresler ve girişler:
[README §1](../README.md#1-platformu-kur-bir-kez-2025-dk).

## Çalışma ortamı

| Araç | Nedir? | Bu projede | Görmek için | İlk |
|---|---|---|---|---|
| **Docker Desktop** | Mac'te Linux konteynerlerini çalıştıran sanal makine | Bütün küme bunun içinde koşar; CPU/bellek sınırı *Settings → Resources*'tan | `docker ps` | kurulum |
| **kind** | "Kubernetes in Docker": her Kubernetes düğümünü bir Docker konteyneri olarak açar | `linkly` kümesi: 1 control-plane + 3 worker; düğüm boşaltma/dondurma deneyleri için birden çok düğüm | `kind get nodes --name linkly` | kurulum |
| **Kubernetes** | Konteynerleri makinelere yerleştiren, ölünce yeniden başlatan, trafiği dağıtan orkestratör | Her seviye kendi namespace'inde: `lvl00` … `lvl14` | `kubectl get ns` | 00 |
| **kubectl** | Kubernetes'in komut satırı | Pod'lara bakmak, log okumak, replika değiştirmek | `kubectl -n lvl00 get pods` | 00 |
| **Helm** | Kubernetes paket yöneticisi; *chart* hazır bir kurulum paketidir | Platform bileşenlerini kurar; ayarlar `platform/helm/*.values.yaml` | `helm list -A` | kurulum |
| **Kustomize** | YAML dosyalarını birleştirip üzerine yama yapan araç (kubectl'in içinde gelir) | Her seviyenin `deploy/kustomization.yaml`'ı; `make deploy` bunu uygular | seviye klasöründe `kubectl kustomize deploy` | 00 |
| **Calico** | Pod'lar arası ağı kuran eklenti (CNI) | kind'in kendi ağı NetworkPolicy uygulamaz; 13'ün ağ kuralları çalışsın diye küme baştan Calico ile kurulur | `kubectl -n kube-system get pods -l k8s-app=calico-node` | kurulum |
| **ingress-nginx** | Kümenin dış kapısı: gelen HTTP isteğini alan adına bakıp doğru servise yollar | `lvl00.localtest.me` → lvl00; 08'den itibaren kaba hız sınırı (503) | `kubectl -n ingress-nginx get pods` | 00 |
| **localtest.me** | Her alt adı `127.0.0.1`'e çözen herkese açık bir alan adı | `/etc/hosts` düzenlemeden `grafana.localtest.me`, `lvl03.localtest.me` … | `dig +short lvl00.localtest.me` | 00 |
| **Yerel registry** | İmaj deposu; Docker Hub'ın makinendeki küçük kopyası (`linkly-registry`) | `make up` derlenen imajı `localhost:5001`'e iter, düğümler oradan çeker | `curl -s localhost:5001/v2/_catalog` | 00 |
| **metrics-server** | Pod ve düğümlerin anlık CPU/bellek ölçümü | `kubectl top` ve HPA bu veriye bakar | `kubectl top pods -n lvl07` | 07 |
| **make** | Uzun komut dizilerine kısa ad veren araç | Her iş bir hedef: `make up`, `make repro`, `make load` … | `make help` | 00 |
| **curl · jq** | HTTP isteği atan komut · JSON'u süzen ve biçimleyen komut | Elle deneme adımları ve scriptlerdeki ölçümler | `curl -s http://lvl01.localtest.me/healthz` | 00 |
| **python3** | Betik dili | Pano üreteci ve README denetleyicileri | — | 00 |

## Uygulama (Go)

| Araç | Nedir? | Bu projede | Görmek için | İlk |
|---|---|---|---|---|
| **Go** | Derlenen, tek ikili dosya üreten, eşzamanlılığı hafif (goroutine) bir dil | Bütün servisler; imajlar Docker içinde derlenir, Mac'e Go kurmak yalnızca test için gerekir | kökte `make test` | 00 |
| **net/http** | Go'nun standart HTTP sunucusu | 00'da korumasız; 01'den itibaren timeout ve düzgün kapanma | `cmd/*/main.go` | 00 |
| **log/slog** | Go'nun yapılandırılmış (JSON) log paketi | Her istek bir JSON satırı; 11'de `trace_id` taşır | `make logs` | 01 |
| **prometheus/client_golang** | Uygulamanın kendi metriklerini `/metrics` adresinde yayınlayan kütüphane | İstek sayısı ve süresi, havuz, önbellek, kuyruk metrikleri; panellerin kaynağı | `curl -s http://lvl01.localtest.me/metrics` | 01 |
| **pgx** | Go için Postgres sürücüsü ve bağlantı havuzu | Havuz dolunca bekleyen istekler ölçülür | `05 · Postgres` panosu | 02 |
| **goose** | Veritabanı şema değişikliklerini (migration) sırayla uygulayan araç | `migrate` Job'ı; 12'de expand/contract | `kubectl -n lvl02 logs job/migrate` | 02 |
| **go-redis** | Go için Redis istemcisi | Önbellek (04), hız sınırı (08), geçersiz kılma yayını (14) | `04 · Cache` panosu | 04 |
| **franz-go** | Kafka protokolünü konuşan Go istemcisi | Tıklama olaylarını üretir ve tüketir | `08 · Stream (Redpanda)` panosu | 06 |
| **OpenTelemetry SDK** | Trace üretmek için açık standart | Bir isteğin servisler arası yolculuğunu kaydeder → Alloy → Tempo | Grafana → Explore → Tempo | 11 |
| **pprof** | Go'nun yerleşik profilleyicisi (`:6060`) | "CPU'yu hangi satır yiyor?" sorusunun cevabı | `go tool pprof -http=: <profil dosyası>` | 11 |

## Veri

| Araç | Nedir? | Bu projede | Görmek için | İlk |
|---|---|---|---|---|
| **PostgreSQL 17** | İlişkisel veritabanı | Linkler ve günlük tıklama sayıları | `kubectl -n lvl02 exec -it postgres-0 -c postgres -- psql -U linkly -d linkly` | 02 |
| **postgres-exporter** | Postgres'in iç durumunu metriğe çeviren yan konteyner | Bağlantı, kilit, sorgu metrikleri (02–08) | `05 · Postgres` panosu | 02 |
| **CloudNativePG (CNPG)** | Kubernetes'te Postgres işleten operatör | Primary + replika, otomatik failover | `kubectl -n lvl09 get clusters.postgresql.cnpg.io` | 09 |
| **PgBouncer** | Postgres önünde duran bağlantı havuzu | `pg-pooler-rw` (yazma), `pg-pooler-ro` (okuma) | `kubectl -n lvl09 get pooler` | 09 |
| **Redis 7** | Bellek içi anahtar-değer deposu | Önbellek (04), hız sınırı sayacı (08), pub/sub ile geçersiz kılma (14) | `kubectl -n lvl04 exec redis-0 -c redis -- redis-cli DBSIZE` | 04 |
| **redis-benchmark** | Redis'in kendi yük aracı | Redis'in tavanını doğrudan ölçmek | Redis pod'unda `redis-benchmark` | 04 |
| **redis_exporter** | Redis'in iç durumunu metriğe çeviren yan konteyner | Bellek, komut/sn, isabet | `06 · Redis` panosu | 04 |
| **Redpanda** | Kafka API'siyle konuşan olay akışı sunucusu (tek ikili, JVM yok) | Tıklama topic'i, tüketici grubu, DLQ | `08 · Stream (Redpanda)` panosu | 06 |
| **rpk** | Redpanda'nın komut satırı | Topic'e ve tüketici grubunun gecikmesine bakmak | `kubectl -n lvl06 exec redpanda-0 -- rpk group describe analytics` | 06 |

## Gözlemlenebilirlik

| Araç | Nedir? | Bu projede | Görmek için | İlk |
|---|---|---|---|---|
| **Prometheus** | Metrikleri belirli aralıkla toplayıp zaman serisi olarak saklayan veritabanı | Uygulama ve küme metrikleri; k6 sonuçları da buraya yazılır | http://prometheus.localtest.me | kurulum |
| **PromQL** | Prometheus'un sorgu dili | Her panel ve her `make repro` ölçümü | Grafana → Explore | 00 |
| **Grafana** | Metrik, log ve trace'i panellerde gösteren arayüz; kendisi veri tutmaz | 16 pano, `Ladder` klasörü, üstte `level` seçici | http://grafana.localtest.me | kurulum |
| **prometheus-operator** | Prometheus'u Kubernetes nesneleriyle yöneten operatör | *ServiceMonitor* (neyi topla), *PrometheusRule* (kayıt/alarm kuralı) | `kubectl get servicemonitor -A` | 01 |
| **kube-state-metrics** | Kubernetes nesnelerinin durumunu metriğe çevirir | Restart sayısı, replika, hazır endpoint | `01 · Pods & Resources` panosu | 00 |
| **cAdvisor** | kubelet'in içinde konteyner başına CPU/bellek ölçen bileşen | 00'da uygulamanın metriği yokken tek göz | `01 · Pods & Resources` panosu | 00 |
| **node-exporter** | Düğümün (makinenin) CPU/bellek/disk metrikleri | Docker VM'inin yükü; panolarda yok, elle sorgulanır | Grafana → Explore: `node_load1` | kurulum |
| **Alertmanager** | Alarmları toplayan, gruplayan ve bildiren bileşen | SLO burn-rate alarmları | http://alertmanager.localtest.me | 11 |
| **Loki** | Log deposu; logları etiketle bulur, içeriği indekslemez | Uygulama logları; `trace_id`'ye tıklayınca Tempo'daki trace açılır | Grafana → Explore → Loki | 11 |
| **Alloy** | Grafana'nın toplayıcı ajanı, her düğümde bir tane | Pod logları → Loki; 11'den itibaren trace'ler → Tempo | `kubectl -n monitoring get pods` | 11 |
| **Tempo** | Trace deposu | "İstek nerede yavaşladı?" | Grafana → Explore → Tempo | 11 |
| **Exemplar** | Bir metrik noktasına iliştirilmiş örnek trace kimliği | Gecikme grafiğindeki noktaya tıkla → o isteğin trace'i | `02 · App RED` panosu | 11 |

## Yük, arıza ve ölçekleme

| Araç | Nedir? | Bu projede | Görmek için | İlk |
|---|---|---|---|---|
| **k6** | Script ile yük üreten test aracı; VU = sanal kullanıcı | `make load S=…`, 10 senaryo (`platform/k6/scenarios`) | `15 · k6 (client tarafı)` panosu | 00 |
| **Chaos Mesh** | Kubernetes'e kontrollü arıza enjekte eden araç | Pod öldürme, Postgres/Redis/Redpanda ağına gecikme ve kayıp: `make chaos C=…`, şablonlar `platform/chaos`'ta (`node-freeze` Chaos Mesh değil: düğümü `docker pause` ile dondurur) | `kubectl get podchaos,networkchaos -A` | 02 |
| **HPA** | Kubernetes'in yerleşik yatay ölçekleyicisi | CPU'ya göre `redirect` replika sayısı | `kubectl -n lvl07 get hpa` | 07 |
| **KEDA** | Kuyruk gecikmesi gibi dış sinyallere göre ölçekleyen araç | Tüketici gecikmesine göre `analytics` replika sayısı | `kubectl -n lvl07 get scaledobject` | 07 |

## Dağıtım ve güvenlik

| Araç | Nedir? | Bu projede | Görmek için | İlk |
|---|---|---|---|---|
| **Argo Rollouts** | Kademeli dağıtım (canary) ve otomatik analiz yapan controller | Yeni sürüm önce az trafik alır; Prometheus'a bakan analiz kötü sürümü geri alır | `kubectl -n lvl12 get rollout` | 12 |
| **Argo CD** | GitOps: kümeyi Git'teki hâline eşitleyen araç | Kurulu; Application bilerek tanımsız (P12-03) | http://argocd.localtest.me | 12 |
| **API anahtarı (sha256)** | Kiracının kimliği; sunucu yalnızca hash'ini saklar | Yazma ucu `Authorization: Bearer …` ister, sabit zamanda karşılaştırılır | `platform/lib/apikey.sh` | 13 |
| **Postgres RLS** | Satır düzeyi güvenlik: hangi satırı kimin göreceğini veritabanı belirler | Kiracı filtresini uygulama değil veritabanı uygular | [13 README](../13-security-tenancy/README.md) | 13 |
| **NetworkPolicy** | Pod'lar arası trafik için izin listesi (uygulayan Calico) | Varsayılan-reddet; yalnızca gereken bağlantılar açık | `kubectl -n lvl13 get networkpolicy` | 13 |
| **Kyverno** | Kümeye girecek manifest'i kurallara göre denetleyen politika motoru | `:latest` yasak, bellek limiti ve probe zorunlu | `kubectl get clusterpolicy` | 13 |
| **sealed-secrets** | Sırrı şifreleyip Git'e güvenle koymayı sağlayan controller | Kurulu; P13-04 sırların hâlâ düz metin olduğunu gösterir | `kubectl get sealedsecrets -A` (boş döner) | 13 |
| **cert-manager** | TLS sertifikası üretip yenileyen operatör | Kurulu; ingress bilerek HTTP | `kubectl -n cert-manager get pods` | 13 |

## Merdivenin kendi araçları

| Dosya | Ne yapar |
|---|---|
| `platform/Makefile` | Platformu kurar/durdurur: `make full`, `make stop`, `make start`, `make status`, `make destroy` |
| `ladder.mk` | Her seviyenin Makefile'ı bunu içe alır: `make up/down/load/repro/chaos/set/reset/grafana …` (`make help`) |
| `Makefile` (kök) | Bütün seviyeler için: `make wipe CONFIRM=1`, `make test`, `make lint`, `make full-run` |
| `problems/PNN-XX.sh` | Bir sorunu ölçerek üreten script; son satırı `REPRODUCED` / `NOT-REPRODUCED` / `SKIPPED` |
| `problems/SOLVES` | Önceki seviyenin bu seviyede artık üretilmemesi gereken sorunları (`make verify-prev` denetler) |
| `platform/lib/repro.sh` | Sorun scriptlerinin ortak kütüphanesi: yük üretme, örnekleme, PromQL, chaos, geri alma |
| `platform/lib/profile.sh` | Seviyenin kullanmadığı platform bileşenlerini kapatır, gerekenleri açar (`make up`'ın ilk adımı) |
| `platform/lib/fresh.sh` | `make fresh`: Grafana'daki geçmiş metrik çizgilerini siler, deney temiz grafikle başlar |
| `platform/lib/setenv.sh` | `make set` / `make unset`: alıştırmalar için uygulamada ayar ve tuzak (`TRAP_*`) açıp kapatır |
| `platform/lib/wipe.sh` | `make wipe`: bütün seviye verilerini siler, kurulumu korur |
| `platform/lib/k6run.sh` · `loadtest.sh` | k6'yı seviyeye göre koşar, sonuçları Prometheus'a yazar; 08+'da yükü hız sınırsız girişten yollar |
| `platform/lib/smoke.sh` | `make up`'ın son adımı: bir link yaratıp 30 kez açar |
| `platform/dashboards/gen.py` | 16 Grafana panosunu tek kaynaktan üretir |
| `platform/kind/registry.sh` · `trust-ca.sh` | Yerel registry'yi kümeye bağlar · kurumsal ağın kök sertifikasını düğümlere kurar |
| `tools/lint-skeleton.sh` · `lint-guide.py` · `lint-grafana.py` | Seviyelerin aynı iskelette kaldığını, README bloklarının yapıştırılabildiğini ve anılan her panelin gerçekten var olduğunu denetler |
| `tools/full-run.sh` · `full-run-report.py` | 00 → 14 tam tur ve Grafana linkli raporu (`make full-run`) |
| `tools/verify-level.sh` · `verify-sweep.sh` | Bir ya da birkaç seviyeyi kur → sorunlarını koş → kaldır |
| `tools/observe-gameday.sh` | 14'teki game day sırasında istemcinin gördüğüyle uygulamanın saydığını yan yana basar |
| `tools/newlevel.sh` | Yeni seviye iskeleti: öncekini kopyalar, adları değiştirir |
| `tools/ladder-matrix/run.sh` | Her sorun scriptini her seviyeye koşar (`make matrix`) |
