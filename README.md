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
cd platform && make full         # küme + tüm operatörler + Prometheus/Grafana  (bir kere, ~20-25 dk)
cd ../00-naive && make up        # seviye ayağa kalkar (platform profili dahil)
make repro P=P00-01              # sorunu kendi gözünle gör
make grafana                     # aynı sorunu panelde gör (admin / ladder)
```

İlk kez mi? **[Sıfırdan başlangıç](#sıfırdan-başlangıç)** — kurulumdan ilk soruna, seviye geçişinden
temizliğe kadar adım adım. Önce aşağıdaki iki tabloya göz at: projede adı geçen her araç ve her kavram
orada tek cümleyle anlatılıyor.

## Kullanılan teknolojiler

Her araç bu projede tek bir iş yapar. **İlk** sütunu aracın hangi seviyede sahneye çıktığını söyler;
"kurulum" yazanlar platformla bir kez gelir ve her seviyede arka planda çalışır. Bir seviye README'si
bir araç andığında karşılığı burada.

### Çalışma ortamı — her şeyin üzerinde koştuğu yer

| Araç | Ne işe yarar | Bu projede | İlk |
|---|---|---|---|
| **Docker Desktop** | Mac'te Linux konteynerlerini çalıştıran sanal makine (VM) | Kümenin tamamı bu VM'in içinde; CPU/bellek sınırı *Settings → Resources*'tan | kurulum |
| **kind** | "Kubernetes in Docker": her Kubernetes düğümü bir Docker konteyneri | `linkly` kümesi: 1 control-plane + 3 worker; Docker Desktop'ta `linkly` grubu | kurulum |
| **Kubernetes** | Konteynerleri düğümlere yerleştiren, ölünce yeniden başlatan, trafiği dağıtan orkestratör | Her seviye kendi namespace'inde (`lvl00` … `lvl14`) | 00 |
| **kubectl** | Kubernetes'in komut satırı | `kubectl -n lvl00 get pods` gibi her gözlem | 00 |
| **Helm** | Kubernetes için paket yöneticisi (paket = *chart*) | Platform bileşenlerini kurar; ayarları `platform/helm/*.values.yaml` | kurulum |
| **Kustomize** | YAML dosyalarını birleştirip ortak etiket ekleyen, kubectl'e gömülü araç | Her seviyenin `deploy/kustomization.yaml`'ı | 00 |
| **Calico** | Pod'lar arası ağı kuran eklenti (CNI) ve NetworkPolicy'yi uygulayan taraf | kind'ın varsayılan ağı NetworkPolicy uygulamaz; 13'ün ağ kuralları Calico sayesinde çalışır | kurulum |
| **ingress-nginx** | Küme dışından gelen HTTP'yi alan adına göre doğru servise yollayan ters vekil (reverse proxy) | `lvl00.localtest.me` → lvl00; 08+'da kaba hız sınırı (`limit-rps`) | 00 |
| **localtest.me** | Genel DNS'te her alt adı `127.0.0.1`'e çözen alan adı | `/etc/hosts` düzenlemeden `grafana.localtest.me`, `lvlNN.localtest.me` | 00 |
| **Yerel registry** (`linkly-registry`, :5001) | Konteyner imajı deposu | `make up` imajı buraya iter, küme buradan çeker | 00 |
| **metrics-server** | Pod'ların anlık CPU/bellek değerleri | `kubectl top`; HPA'nın CPU sinyali | 07 |
| **make** | Uzun komutları kısa hedef adlarıyla çalıştırır | `make up`, `make repro`, `make load` … ([listesi](#her-seviyede-aynı-komutlar)) | 00 |
| **jq · python3** | JSON işleme · yardımcı scriptler | Reproduce scriptleri, lint, dashboard üretimi | 00 |

### Uygulama — kodun içindekiler

| Araç | Ne işe yarar | Bu projede | İlk |
|---|---|---|---|
| **Go** | Derlenen, eşzamanlılığı dilin içinde olan programlama dili | Bütün servisler; imajlar Docker içinde derlenir | 00 |
| **net/http** | Go'nun standart HTTP sunucusu | 00'da korumasız; 01'den itibaren timeout'lar ve graceful shutdown | 00 |
| **log/slog** | Go'nun yapılandırılmış (JSON) log paketi | Her istek bir JSON satırı; 11'de `trace_id` taşır | 01 |
| **prometheus/client_golang** | Uygulamanın kendi metriklerini `/metrics` ucunda yayınlar | İstek sayısı, süre histogramı, havuz, önbellek, kuyruk metrikleri | 01 |
| **pgx** | Go'nun Postgres sürücüsü ve bağlantı havuzu | Havuz beklemesi `db_pool_acquire_duration_seconds` ile ölçülür | 02 |
| **goose** | Veritabanı şema migration aracı | `migrate` Job'ı; 12'de expand/contract | 02 |
| **go-redis** | Go'nun Redis istemcisi | Önbellek (04), hız sınırı (08), geçersiz kılma yayını (14) | 04 |
| **franz-go** | Go'nun Kafka istemcisi | Tıklama olaylarını üretir ve tüketir | 06 |
| **OpenTelemetry SDK** | Trace (bir isteğin servisler arası yolculuğu) üretmenin standart yolu | Span'ler OTLP ile Alloy'a, oradan Tempo'ya | 11 |
| **pprof** | Go'nun yerleşik CPU/bellek profilleyicisi | `:6060` portunda; "CPU'yu hangi satır yiyor?" | 11 |

### Veri — durumun yaşadığı yerler

| Araç | Ne işe yarar | Bu projede | İlk |
|---|---|---|---|
| **PostgreSQL 17** | İlişkisel veritabanı | Linkler ve günlük tıklama sayıları | 02 |
| **postgres-exporter** | Postgres'in iç durumunu Prometheus metriğine çevirir | Bağlantılar, kilitler, sorgu istatistikleri (02–08) | 02 |
| **CloudNativePG (CNPG)** | Postgres'i Kubernetes'te yöneten operatör: primary + replika, otomatik failover | `pg` cluster'ı: 1 primary + 1 replika | 09 |
| **PgBouncer** | Postgres önünde bağlantı havuzlayıcı | CNPG *Pooler*: `pg-pooler-rw` (yazma), `pg-pooler-ro` (okuma) | 09 |
| **Redis 7** | Bellek içi anahtar-değer deposu | Paylaşılan önbellek (04), hız sınırı sayacı — Lua ile atomik (08), pub/sub ile geçersiz kılma (14) | 04 |
| **redis_exporter** | Redis metrikleri | Bellek, komut/sn, isabet, bağlantılar | 04 |
| **Redpanda** | Kafka API'siyle konuşan, tek ikili dosyalı olay akışı (dayanıklı log) sunucusu | Tıklama olayları topic'i; tüketici grubu, DLQ | 06 |

### Gözlemlenebilirlik — sistemin içini görmek

| Araç | Ne işe yarar | Bu projede | İlk |
|---|---|---|---|
| **Prometheus** | Metrikleri **toplar ve saklar**: hedeflerin `/metrics` ucunu periyodik okur (*scrape*) | Uygulama 10 sn, küme 30 sn aralıkla; 6 saat saklar; k6 sonuçları da buraya yazılır | kurulum |
| **PromQL** | Prometheus'un sorgu dili | Her panel ve her `make repro` ölçümü bir PromQL sorgusu | 00 |
| **Grafana** | Metrik, log ve trace'i panellerde **gösterir**; veri tutmaz, sorgular | 16 dashboard, `Ladder` klasörü — http://grafana.localtest.me (admin / ladder) | kurulum |
| **prometheus-operator** | Prometheus'u Kubernetes nesneleriyle yapılandırır: *ServiceMonitor* (neyi kazı), *PrometheusRule* (kayıt ve alarm kuralları) | Her seviyenin `servicemonitor.yaml`'ı; 11+ `slo.yaml` | 01 |
| **kube-state-metrics** | Kubernetes nesnelerinin durumunu metrik yapar | Restart sayısı, replika, hazır endpoint — `01 · Pods & Resources` | 00 |
| **cAdvisor** (kubelet'in içinde) | Konteyner başına CPU ve bellek kullanımı | 00'ın metrik ucu yokken tek göz | 00 |
| **node-exporter** | Düğüm (makine) metrikleri | Düğüm CPU/bellek | kurulum |
| **Alertmanager** | Prometheus'un ürettiği alarmları toplar, gruplar, bildirir | SLO burn-rate alarmları | 11 |
| **Loki** | Log deposu — Grafana'nın log tarafı | Pod logları; `trace_id` tıklanınca Tempo'daki trace açılır | 11 |
| **Alloy** | Toplayıcı ajan: pod loglarını Loki'ye, trace'leri Tempo'ya taşır | Her düğümde bir kopya (DaemonSet) | 11 |
| **Tempo** | Trace deposu | "İstek nerede yavaşladı?" sorusunun cevabı | 11 |
| **Exemplar** | Histogram noktasına iliştirilmiş örnek trace kimliği | Gecikme panelinde noktaya tıkla → o isteğin trace'i | 11 |

### Yük, arıza ve ölçekleme

| Araç | Ne işe yarar | Bu projede | İlk |
|---|---|---|---|
| **k6** | Yük üretici: sanal kullanıcılarla (VU) HTTP isteği yağdırır | `make load S=…`, 10 senaryo (`platform/k6/scenarios`); sonuçlar `15 · k6` panelinde | 00 |
| **Chaos Mesh** | Kontrollü arıza: pod öldürme, ağa gecikme/kayıp ekleme | `make chaos C=…`, 12 şablon (`platform/chaos`) | 02 |
| **HPA** | Kubernetes'in yerleşik yatay ölçekleyicisi: CPU'ya göre replika sayısı | redirect-svc | 07 |
| **KEDA** | Olay kaynaklı ölçekleyici: kuyruk gecikmesine (*lag*) göre replika sayısı | analytics-consumer | 07 |

### Dağıtım ve güvenlik

| Araç | Ne işe yarar | Bu projede | İlk |
|---|---|---|---|
| **Argo Rollouts** | Kademeli dağıtım: canary adımları + Prometheus'a bakan otomatik analiz | redirect-svc bir *Rollout*; kötü sürüm canary'de geri alınır | 12 |
| **Argo CD** | GitOps: kümeyi Git'teki manifest'lere eşitler, sapmayı gösterir | Kurulu; Application bilerek tanımsız (P12-03 neden olduğunu gösterir) — http://argocd.localtest.me | 12 |
| **API anahtarı (sha256)** | Kiracı kimliği: istemcinin anahtarı hash'lenip sabit zamanda karşılaştırılır | 13+ `Authorization: Bearer …` | 13 |
| **Postgres RLS** | Satır düzeyi güvenlik: kiracı filtresini uygulama değil veritabanı uygular | Unutulan `WHERE tenant = …` sızıntıya dönüşmez | 13 |
| **NetworkPolicy** | Pod'lar arası trafik için izin listesi | Varsayılan-reddet; yalnızca gereken bağlantılar açık | 13 |
| **Kyverno** | Admission denetleyicisi: kurala uymayan manifest kümeye hiç giremez | `:latest` yasak, bellek limiti ve probe zorunlu | 13 |
| **sealed-secrets** | Sırrı kümenin anahtarıyla şifreleyip Git'e koymayı sağlar | Kurulu; P13-04 sırların hâlâ düz metin olduğunu gösterir | 13 |
| **cert-manager** | TLS sertifikası üretir ve yeniler | Kurulu; ingress bilerek HTTP (13 §9) | 13 |

### Merdivenin kendi araçları

| Araç | Ne işe yarar |
|---|---|
| `ladder.mk` | Her seviyenin Makefile'ı bunu içe alır: `make up/down/load/repro/chaos/set/grafana …` |
| `problems/PNN-XX.sh` | Bir sorunu ölçerek üreten script; hükmü `REPRODUCED` / `NOT-REPRODUCED` / `SKIPPED` |
| `platform/lib/profile.sh` | Seviyenin kullanmadığı platform bileşenlerini kapatır, gerekenleri açar (`make up`'ın ilk adımı) |
| `platform/lib/wipe.sh` | `make wipe`: verileri siler, kurulumu korur |
| `platform/dashboards/gen.py` | 16 Grafana dashboard'unu tek kaynaktan üretir |
| `tools/lint-skeleton.sh` · `tools/lint-grafana.py` | Seviyelerin aynı iskelette kaldığını ve README'deki her panel adının gerçekten var olduğunu denetler |

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

## Merdiven — 00'dan 14'e ne yaşayacaksın

| # | Klasör | Slogan | Yeni gelen | Getirdiği acı |
|---|---|---|---|---|
| 00 | [`00-naive`](00-naive) | Tek dosya, tek pod, bellek | — | Çöker, unutur, ölçeklenmez, kördür |
| 01 | [`01-hardened`](01-hardened) | Tek süreç ama düzgün | mutex, probe, graceful shutdown, timeout, metrics | Hâlâ unutur ve ölçeklenmez |
| 02 | [`02-postgres`](02-postgres) | Kalıcılık ve yatay ölçek | Postgres, stateless N replika | Her redirect DB'ye; pool biter |
| 03 | [`03-local-cache`](03-local-cache) | Süreç içi önbellek | LRU + TTL + singleflight | Pod'lar arası tutarsızlık |
| 04 | [`04-redis-cache`](04-redis-cache) | Paylaşılan önbellek | Redis cache-aside | Redis SPOF, hot key |
| 05 | [`05-async-analytics`](05-async-analytics) | Yazmayı okuma yolundan çıkar | Bounded kuyruk + batch writer | At-most-once kayıp |
| 06 | [`06-event-stream`](06-event-stream) | Olay akışı | Redpanda + consumer | Duplicate, lag, poison |
| 07 | [`07-services-autoscaling`](07-services-autoscaling) | Servisleri ayır | 3 servis, HPA, KEDA | Darboğaz DB'ye kayar |
| 08 | [`08-rate-limiting`](08-rate-limiting) | Gürültülü komşu | Dağıtık limiter | Limiter'ın kendi bağımlılığı |
| 09 | [`09-database-scaling`](09-database-scaling) | DB darboğazı | CNPG, Pooler, partition | Replikasyon gecikmesi |
| 10 | [`10-resilience`](10-resilience) | Hata izolasyonu | timeout, retry, breaker, shedding | Ayar karmaşıklığı |
| 11 | [`11-observability-deep`](11-observability-deep) | Neden yavaş? | trace, exemplar, SLO, profil | Sampling, kardinalite |
| 12 | [`12-delivery`](12-delivery) | Güvenli dağıtım | Argo Rollouts canary, expand/contract | Migration/rollback uyumu |
| 13 | [`13-security-tenancy`](13-security-tenancy) | Kim, neye, ne kadar | API anahtarı, RLS, NetworkPolicy, Kyverno | Operasyonel sürtünme |
| 14 | [`14-modern`](14-modern) | Son hal | L1+L2 önbellek, kapasite modeli, game day | "Yolun devamı" listesi |

Her seviyede ne yaşayacağın ve o seviye olmasaydı ne olacağı (ayrıntısı her seviye README'sinin en başında):

**00 — naive.** *Yaşayacağın:* "çalışan" bir servisin kaç yoldan kırıldığı — 50 eşzamanlı kullanıcıda
süreç çöker, restart bütün linkleri siler, ikinci replika rastgele 404 verir, dağıtımda istekler düşer,
bellek sınırsız büyüyüp OOMKilled olur, yavaş bir istemci sunucuyu kilitler, hiçbir şey ölçülmez.
*Olmasa:* sonraki 14 seviyenin her parçası "neden var?" sorusuna cevapsız kalır; bu seviye merdivenin gerekçesi.

**01 — hardened.** *Yaşayacağın:* aynı tek süreç disiplinle yazılınca çökmenin, dağıtım hatalarının ve
körlüğün kapanması; kalıcılık ve ölçek sorunlarının artık panelde **görünür** olması; tek replika + PDB'nin
sahte güvencesi; kısa kodu metrik etiketi yapmanın Prometheus'u şişirmesi.
*Olmasa:* 00'ın çöküşleri sürer ve sonraki seviyelerin sorunlarını ölçecek metrik olmaz.

**02 — postgres.** *Yaşayacağın:* durum süreçten çıkınca N replikanın, temiz rollout'un ve node drain'in
bedava gelmesi; karşılığında her redirect'in bir DB sorgusu olması, bağlantı havuzunun tükenmesi,
indekssiz tabloda seq scan, yavaş DB'nin havuzu tıkaması, sıcak linkin satır kilidi kuyruğu. İlk kez
Chaos Mesh ile veritabanına arıza enjekte edersin.
*Olmasa:* her restart linkleri siler, ikinci replika açılamaz.

**03 — local-cache.** *Yaşayacağın:* pod belleğindeki önbelleğin DB yükünü silmesi; karşılığında silinen
linkin diğer pod'larda yaşamaya devam etmesi, her rollout'ta soğuk önbellek ve DB'de testere dişi,
singleflight/negatif önbellek/TTL jitter kapatılınca izdiham.
*Olmasa:* her redirect veritabanına gider; trafik artınca havuz ve DB darboğaz olur.

**04 — redis-cache.** *Yaşayacağın:* tek paylaşılan önbelleğin 03'ün tutarsızlıklarını kapatması;
karşılığında Redis ölünce bütün yükün DB'ye inmesi, her okumaya bir ağ adımı eklenmesi, sıcak anahtar,
cache-aside yarışı, `noeviction` ve `KEYS *` tuzakları.
*Olmasa:* silinen link pod'larda yaşar, her rollout DB'yi yakar, isabet oranı replika sayısıyla düşer.

**05 — async-analytics.** *Yaşayacağın:* tıklama sayacını istek yolundan çıkarıp sınırlı bir kuyruğa ve
toplu yazıcıya vermek; "en fazla bir kez" teslimatın bedeli: sert ölümde ve dolu kuyrukta tıklama kaybı.
*Olmasa:* popüler bir linkin her tıklaması aynı satırı kilitler ve redirect'ler bu yazmayı bekler.

**06 — event-stream.** *Yaşayacağın:* olayları dayanıklı bir loga yazıp ayrı bir tüketiciyle işlemek;
en-az-bir-kez teslimat ve çift sayma, tüketici gecikmesi, zehirli mesajın hattı durdurması, commit
noktasının teslimat garantisini belirlemesi.
*Olmasa:* pod sert ölünce tampondaki tıklamalar kaybolur; yazıcı redirect ile aynı süreci paylaşır.

**07 — services-autoscaling.** *Yaşayacağın:* tek uygulamayı üç servise ayırıp her birine kendi ölçekleme
sinyalini vermek; HPA'nın geç kalması, ölçeklemenin darboğazı DB'ye taşıması, CPU limitinin gecikme
üretmesi, düğüm kapasitesi bitince Pending, donan düğüm.
*Olmasa:* okuma, yazma ve tüketim tek replika sayısını paylaşır — biri yük alınca hepsi birlikte ölçeklenir.

**08 — rate-limiting.** *Yaşayacağın:* hız sınırını Redis'te paylaşılan bir sayaca taşıyınca limitin
replika sayısından bağımsız olması; limiter'ın kendi bağımlılığı, her isteğe iki ağ çağrısı,
`X-Forwarded-For` tuzağı, sabit pencerede 2× burst, gürültülü komşunun izolasyonu.
*Olmasa:* süreç içi limit N replikada N katına çıkar; tek bir kiracı herkesi yavaşlatır.

**09 — database-scaling.** *Yaşayacağın:* Postgres'i operatörle primary + replika ve PgBouncer ile
yönetmek; read-your-writes ihlali, failover penceresi, transaction pooling tuzağı, replikada WAL
çakışması, partition'sız silmenin pahalılığı, replikasyonun yedek olmadığı.
*Olmasa:* tek Postgres tek arıza noktasıdır ve bağlantı sayısı replika × havuz ile duvara çarpar.

**10 — resilience.** *Yaşayacağın:* bir bağımlılık kısmen bozulunca sistemin kısmen çalışması — timeout
bütçesi, bütçeli retry, devre kesici, bulkhead, yük atma; bütçesiz retry'ın yükü katlaması, yavaş
bağımlılığın ölüden beter olması.
*Olmasa:* yavaşlayan bir Redis ya da DB bütün istek havuzunu doldurur; tek bağımlılığın arızası bütün servisin arızası olur.

**11 — observability-deep.** *Yaşayacağın:* "p99 yüksek — ama nerede?" sorusunu trace, exemplar, log ve
profille cevaplamak; trace'in Kafka sınırında kopması, sampling takası, eşik alarmı ile burn-rate
alarmının farkı, gözlemlenebilirliğin kendi kapasitesi, kardinalite.
*Olmasa:* metrik "yavaş" der ama "nerede"yi söylemez; tahminle optimize edilir.

**12 — delivery.** *Yaşayacağın:* kötü bir sürümün canary'de, trafiğin ~1/4'ündeyken otomatik analizle
yakalanıp geri alınması; kırıcı migration, drift, `:latest`, canary ile stable'ın paylaşılan durum
uyumsuzluğu, uygulama geri alınınca şemanın geri alınmaması.
*Olmasa:* her dağıtım "değiştir ve umut et"tir; kötü sürüm trafiğin tamamına ulaşır.

**13 — security-tenancy.** *Yaşayacağın:* kiracı kimliğinin başlıktan değil hash'li API anahtarından
gelmesi; başlıkla kiracı taklidi, unutulan tenant filtresi ve RLS, varsayılan-reddet ağ, düz metin
sırlar, DNS ile gizlenen iç adresler, link kodu taraması, README kuralının Kyverno ile kapıya dönüşmesi.
*Olmasa:* `X-Tenant-ID` yazan herkes başka kiracı olur, unutulan bir filtre bütün kiracıların verisini
sızdırır, herhangi bir pod veritabanına bağlanabilir.

**14 — modern.** *Yaşayacağın:* kalan borçları kapatmak (L1+L2 önbellek ve pub/sub ile geçersiz kılma,
3 partition, `allkeys-lru`) ve yeni bedellerini; bu kümede ölçülmüş bir kapasite modeli; bütün
korumaları aynı anda sınayan game day.
*Olmasa:* korumalar tek tek sınanmış olur ama birlikte hiç; sistemin gerçek tavanı tahmin olarak kalır.

## Tekdüzelik (en önemli kural)

15 seviyenin hepsi **aynı iskelete, aynı Makefile'a, aynı `make up` yoluna, aynı Grafana dashboard'larına,
aynı k6 senaryolarına ve aynı chaos şablonlarına** sahiptir. Seviyeler arasında değişen yalnızca iki şey vardır:

1. **Uygulama kodu** (`cmd/`, `internal/`, `deploy/`)
2. **README'deki adım adım reproduce edilebilir sorunlar** (`problems/PNN-XX.sh`)

Bir seviyeyi öğrendiysen hepsini öğrendin. `tools/lint-skeleton.sh` sapmayı CI'da hata sayar.

| Seviyede olan | Seviyede olmayan (platform/'da tek kopya) |
|---|---|
| `README.md` (10 sabit başlık), `Makefile` (3 satır), `go.mod`, `Dockerfile` (ortak), `cmd/`, `internal/`, `deploy/`, `problems/` | dashboard'lar, k6 senaryoları, chaos şablonları, helm values, cluster kurulumu |

## Sıfırdan başlangıç

Bu bölüm, projeyi hiç görmemiş biri için baştan sona yazıldı. Sırayla git; her adımın sonunda
"ne görmelisin" satırı var. Bir yerde takılırsan en alttaki **Takılırsan** tablosuna bak.

### 0. Neye ihtiyacın var

| Gereken | Neden / not |
|---|---|
| **Docker Desktop**, Settings → Resources: **en az 6 CPU / 10 GB**, mümkünse 8 CPU / 12 GB | Her şey bir kind kümesinde (Docker içinde 4 Kubernetes düğümü) koşar. 6 CPU ile 00–12 rahat; 13–14'te bütün operatörler açık olduğu için VM doygunluğa yaklaşır ve ölçümler gürültülenir |
| `brew install kind kubectl helm k6 jq` | kind: küme · kubectl/helm: kurulum · k6: yük üretici · jq: script'ler |
| `git`, `python3`, `make` | macOS'ta hazır gelir (`xcode-select --install`) |
| Go 1.26+ (**isteğe bağlı**) | Yalnızca `make test`/`make lint` için; imajlar Docker içinde derlenir |
| Boş portlar: **80, 443, 5001** | 80/443 ingress'e, 5001 yerel imaj registry'sine gider |
| İnternet | İmajlar ve helm chart'ları indirilir. `*.localtest.me` adresleri genel DNS'te 127.0.0.1'e çözülür |

macOS'ta geliştirildi ve denendi; Linux'ta çalışması beklenir ama denenmedi.
Kurumsal ağdaysan (Zscaler, Cloudflare Gateway gibi TLS araya girmesi) ek bir şey yapma: kurulum,
kök sertifikayı düğümlere kendisi kurar (`platform/kind/trust-ca.sh`).

### 1. Platformu kur (bir kez, ~20–25 dk)

```bash
git clone https://github.com/bulutaysarac/linkly-ladder.git
cd linkly-ladder/platform
make full
```

`make full`: kind kümesi (1 control-plane + 3 worker, adı `linkly`) + Calico + yerel registry +
ingress + Prometheus/Grafana/Loki + Chaos Mesh + KEDA + CloudNativePG + Tempo + Argo CD/Rollouts +
cert-manager/Kyverno. Hepsini bir kez kurarsın; her seviye yalnızca kendi ihtiyacını açık tutar
(profil), gerisi kapalı durur.

**Ne görmelisin:** son satırlarda `✔ cert-manager + sealed-secrets + kyverno`. `make status` dört
düğümü `Ready` gösterir. Docker Desktop'ta konteynerler **`linkly`** grubu altındadır.
(Makine dar ise önce `make minimal` — yalnızca 00–01 için — ya da `make standard` — 02–10.)

| Adres | Ne | Giriş |
|---|---|---|
| http://grafana.localtest.me | Paneller (`Ladder` klasörü, üstte `level` seçici) | admin / ladder |
| http://prometheus.localtest.me | Ham metrikler, PromQL | — |
| http://argocd.localtest.me | GitOps (12+) | admin / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| http://lvlNN.localtest.me | NN. seviyenin kendisi (örn. `lvl00`) | 13+: API anahtarı |

### 2. İlk seviye: 00-naive (~10 dk)

```bash
cd ../00-naive
make up
```

`make up` sırasıyla: seviyenin platform profilini uygular → servisleri Docker'da derler →
registry'ye iter → Kubernetes'e kurar → hazır olmasını bekler → bir link oluşturup açarak dener.
**Ne görmelisin:** `smoke ✔ POST /api/links → <kod>, GET /<kod> → 301` ve `✔ lvl00 ayakta` (~1 dk; ilk
derlemede daha uzun).

Şimdi uygulamayı elle dene:

```bash
code=$(curl -s -XPOST http://lvl00.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl00.localtest.me/$code   # 301 → https://example.com
make grafana                                          # tarayıcıda Ladder panelleri (admin / ladder)
```

301 mi? Evet — ve bu 00'ın sorunlarından biri (P00-10: tarayıcı kalıcı yönlendirmeyi önbellekler, tıklama
sayılmaz). 01'den itibaren 302 döner. Merdivende "garip" görünen her davranışın README'de bir karşılığı vardır.

### 3. Bir sorunu yaşa

Her seviyenin README'si aynı 10 başlığa sahiptir. Bir seviyede **şu sırayla** oku:

| Bölüm | Neden oku |
|---|---|
| §1 Bu seviye ne? · §2 Mimari | Ne kuruldu, neden |
| §3 Önceki seviyeden çözülenler | Bir önceki seviyede yaşadığın hangi acıya cevap |
| **§6 Reproduce edilebilir sorunlar** | **Asıl ders.** Her sorun: belirti, neden, adım adım elle üretme, Grafana'da nerede görüneceği, hangi seviyede çözüldüğü |
| §7 Alıştırmalar | Bir çözümü bilerek bozup sorunun geri geldiğini görmek |
| §8 Gözlemlenebilirlik · §9 Bilerek bırakılanlar · §10 `make diff-prev` | Paneller, kapsam dışı kalanlar, kod farkının okuma rehberi |

Örnek — 00'ın ilk sorunu (**P00-01**, eşzamanlı yazma süreci öldürür). §6'daki adımlar:

```bash
kubectl -n lvl00 get pods -w                           # İKİNCİ terminalde açık bırak
make load S=create K6_ARGS="--vus 50 --duration 30s"  # 50 eşzamanlı kullanıcı
```

**Ne görmelisin:** birkaç saniye içinde ikinci terminalde `RESTARTS` artar;
`kubectl -n lvl00 logs -l app.kubernetes.io/name=linkly --previous | head` →
`fatal error: concurrent map writes`. Grafana → `01 · Pods & Resources` → "Yeniden başlatma sayısı".

Aynı deneyi tek komutla da koşabilirsin — script ölçer ve hükmünü basar:

```bash
make repro P=P00-01      # → REPRODUCED (sorun var) / NOT-REPRODUCED (yok) / SKIPPED (ölçülemedi)
```

Yıkıcı adımı olan scriptler (düğüm dondurma, pod öldürme…) onay ister: `CONFIRM=1 make repro P=…`.
Bir seviyedeki tüm sorunları sırayla koşmak 20–60 dk sürer; önce birkaçını **elle** yaşa.

### 4. Alıştırmalar (bir çözümü bilerek boz)

Her README'nin §7'si, bir çözümü kapatan `TRAP_*` bayraklarını ve "elle denemeye değer" ayarları
listeler. Örnek — 03'ün önbelleğini çalışma kümesinden küçült:

```bash
cd ../03-local-cache && make up
make load S=mixed K6_ARGS="--duration 30s"   # normal: Grafana → 04 · Cache → isabet oranı ~%100
make set E="CACHE_CAPACITY=100"              # pod'lar yeni değerle yeniden başlar, hazır olunca döner
make load S=mixed K6_ARGS="--duration 30s"   # isabet ~%20'ye çöker, atılan kayıt 0 → ~2000/s, DB'ye yığılan istekler 5xx üretir
make env                                     # şu an ne ayarlı? → CACHE_CAPACITY=100
make reset                                   # HER ŞEYİ deploy/'daki hâline döndür (CACHE_CAPACITY=50000)
```

`make unset E=X` bir değişkeni yalnızca siler; manifest'te tanımlı bir ayarı eski değerine döndürmek
için `make reset` kullan. `make repro` scriptleri tuzakları **kendileri** açıp kapatır ve bitince ortamı
eski hâline getirir — elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`.

### 5. Sonraki seviyeye geç

```bash
make down                  # bu seviyeyi kaldır (namespace silinir)
cd ../01-hardened
make diff-prev | less      # 00 → 01 kod farkı: çözümün KENDİSİ (uzun; §10 nasıl okunacağını anlatır)
make up
make verify-prev           # 00'ın sorunlarını burada tekrar koşar
```

`verify-prev` çıktısı: `BEKLENEN` sütununda `NOT-REPRODUCED` yazan satırlar bu seviyenin çözdüğünü
iddia ettikleridir (`problems/SOLVES`) — sonuç uyuşmazsa satır `✘` alır. `(açık kalabilir)` yazanlar
bilerek sonraki seviyelere bırakılmıştır. **Aynı anda tek seviye çalıştır**: makine buna göre ayarlı.

### 6. Günün sonunda

```bash
make down                        # açık seviyeyi kaldır
make -C ../platform stop         # kümeyi DURDUR (silmez) — yarın: make -C platform start
```

Docker Desktop'ta `linkly` grubunun **sil** düğmesi tüm kümeyi siler; durdurmak için `make stop`
kullan.

**Verileri sıfırlamak, kurulumu korumak** — Grafana'yı boş bir sayfayla, deneyleri temiz bir kümeyle
baştan almak için (kök klasörde):

```bash
make wipe                        # neyin silineceğini yazar, hiçbir şey silmez
make wipe CONFIRM=1              # siler (~2-3 dk)
```

Silinenler: bütün seviye namespace'leri (`lvl00` … `lvl14`) ve içlerindeki Postgres/Redis/Redpanda
verisi, Prometheus'un bütün metrikleri (k6 koşuları dahil), Tempo'nun trace'leri, Loki'nin logları,
Alertmanager'ın durumu, seviyelerin kurduğu Kyverno kuralları ve `/tmp/k6-*.summary*.json`.
Kalanlar: küme, kurulu bileşenler, Grafana dashboard'ları ve registry'deki imajlar — bir sonraki
`make up` derleme ve kurulum beklemeden ~1 dk'da hazır olur. Grafana'nın kendisi veri tutmaz, yalnızca
gösterir; paneller bu yüzden sorguladıkları depolar boşalınca boşalır.

Her şeyi kaldırmak (küme dahil): `make -C platform destroy`.

### Takılırsan

| Belirti | Sebep | Ne yap |
|---|---|---|
| `make up`: `✘ seviye NN şu platform bileşenlerini istiyor ama kurulu değil: …` | O seviyenin operatörü kurulmamış | Mesajdaki komut, ya da `make -C platform full` |
| `failed calling webhook … connection refused` | Bir operatör (CNPG, Kyverno) yeniden başlıyor | `make up` kendisi 3 kez dener; yine olursa 1 dk bekleyip tekrar `make up` |
| `lvlNN siliniyor, bitmesi bekleniyor…` uzun sürüyor | Önceki `make down` henüz bitmedi | Bekle; 5 dk'yı geçerse `kubectl get ns lvlNN -o yaml` → `status.conditions` |
| `Forbidden` / `TLS handshake timeout` / komutlar çok yavaş | VM doygun, API sunucusu yavaş (en sık sebep) | Mac'te ağır işleri kapat; `docker stats` ile `linkly-*` toplamına bak (`kubectl top` yanıltır); gerekirse `make -C platform stop && make -C platform start` |
| `make grafana` boş sayfa / 502 | Grafana kapalı (otomatik turlar `GRAFANA=0` ile kapatır) | `make profile` (Grafana'yı açar) |
| `lvlNN.localtest.me` açılmıyor | DNS filtreleniyor ya da seviye ayakta değil | `dig lvl00.localtest.me` → 127.0.0.1 olmalı; değilse `/etc/hosts`'a `127.0.0.1 lvl00.localtest.me grafana.localtest.me prometheus.localtest.me` ekle |
| `port is already allocated` (80/443/5001) | Portu başka bir şey tutuyor (başka bir kind kümesi, yerel bir web sunucusu) | `lsof -i :80` ile bul ve kapat; başka bir kind kümesiyse `kind get clusters` → `kind delete cluster --name <ad>` |
| 13+'da POST `401` | Yönetim uçları API anahtarı ister | README §4'teki `Authorization: Bearer …` başlıklı komutu kullan |
| Script `SKIPPED` dedi | Ölçüm yapılamadı (ortam hazır değil) — sahte hüküm vermek yerine durdu | Script çıktısındaki sarı uyarıyı oku; genelde `make up` ile düzelir |
| Grafana'da eski deneylerin çizgileri yenisine karışıyor | Prometheus 6 saat saklar; önceki koşular aynı panellerde | Zaman aralığını daralt ("Last 15 minutes") ya da baştan başla: `make wipe CONFIRM=1` |
| Her şey tuhaf | — | `make status` (seviye), `make -C platform status` (platform), `make logs` |

Kendi deneyini yazacaksan: [docs/PROBLEM-TEMPLATE.md](docs/PROBLEM-TEMPLATE.md) ve aşağıdaki
[Ölçüm kuralları](#ölçüm-kuralları).

## Grafana'yı okumak

Adres: **http://grafana.localtest.me** · kullanıcı **`admin`** · şifre **`ladder`** (yerel, sabit —
değiştirmen istenmez). Panelleri **Dashboards → Ladder** klasöründe bulursun. Seviye README'lerindeki
her "**Grafana'da gör:**" linki dashboard'u o seviye seçili ve son 15 dakika açık olarak açar;
aşağıdakiler, açtığın sayfayı okuyabilmen için.

### Sayfanın üstü

| Öğe | Ne yapar | Deneyde |
|---|---|---|
| `level` seçici (sol üst) | Aynı paneller her seviye için: `lvl00` … `lvl14` | Çalıştığın seviye. Yanlış seviye = boş panel |
| Zaman aralığı (sağ üst, "Last 15 minutes") | Grafiğin kapsadığı pencere | Deneyi **kapsamalı**: 30 dk önce koştuysan "Last 1 hour" |
| Yenileme (⟳ yanındaki ok) | Otomatik güncelleme | Deney sırasında **10s** |

Bir panelde: fareyi çizginin üstünde gezdir → o anki değerler; lejanttaki bir seriye tıkla →
yalnız o seri; panel başlığı → ⋮ → **View** (büyüt) · **Explore** (sorguyu gör ve değiştir).

### "No data" ne demek — ve ne DEMEK DEĞİL

"No data" **sıfır demek değildir**, "burada ölçülen bir şey yok" demektir. Sırayla bak:

1. **Seviye bu metriği üretiyor mu?** Her seviye README'sinin §8'i hangi panellerin dolu, hangilerinin
   bilerek boş olduğunu listeler. Örneğin 00'ın `/metrics` ucu yoktur, `02 · App RED` 00'da boştur.
2. **`level` doğru mu?** Seçici başka bir seviyedeyse her şey boş görünür.
3. **Zaman aralığı deneyi kapsıyor mu?** Deney aralığın dışında kaldıysa çizgi yoktur.
4. **Yeni mi başladı?** Prometheus uygulama metriklerini 10 sn'de, küme metriklerini (pod, restart,
   CPU) 30 sn'de bir toplar ve paneller 1 dk'lık ortalama çizer: yeni bir olay **30–90 sn gecikmeyle**
   ve yumuşatılmış görünür. Birkaç saniyelik bir sıçrama düzleşir — README o durumda kanıtı terminalde gösterir.
5. **Grafana/Prometheus ayakta mı?** `make -C platform status`; Grafana için `make profile`.

### k6 "Dönen durum kodları" panelindeki kodlar (istemcinin gördüğü)

| Kod | Anlamı | Kimden geliyor |
|---|---|---|
| `201` | Link oluşturuldu | Uygulama |
| `301` / `302` | Yönlendirme — kısa linkin normal cevabı (00'da 301, sonrasında 302) | Uygulama |
| `404` | Böyle bir kod yok | Uygulama |
| `429` | Hız sınırı: "yavaşla" | Uygulama (08+) |
| `500` | Uygulama içinde hata | Uygulama |
| `502` | Bağlantı istek sırasında koptu — çoğunlukla pod istek işlerken öldü | Ingress |
| `503` | Gönderilecek hazır pod yok (ya da 08+'da ingress'in kendi hız sınırı) | Ingress **ya da** uygulama |
| `504` | Uygulama zamanında cevap vermedi | Ingress |
| `0` | Bağlantı hiç kurulamadı | — |

**Hatalar sayıca şişer:** k6'nın sanal kullanıcıları cevap gelir gelmez yeni istek atar. Ölü bir
pod'un 503'ü mikro saniyede döner, başarılı bir istek milisaniyeler sürer; aynı sürede yüz kat fazla
hata sayılır. "Kaç istek başarısız?" sorusunu **süreye** göre oku (panelde çizginin ne kadar uzun
sürdüğü), sayıya göre değil. `02 · App RED` (uygulamanın saydığı) ile `15 · k6` (istemcinin gördüğü)
arasındaki fark, aradaki bir katmanın (ingress, hız sınırı) ürettiği cevaptır.

### Grafana "ne oldu"yu gösterir, "neden"i log söyler

Bir pod öldüyse panel `Error` der; sebebi ölen sürecin son logundadır:
```bash
kubectl -n lvlNN get pods                                  # RESTARTS sütunu 0'dan büyük olan pod'u bul
kubectl -n lvlNN logs <pod-adı> --previous --tail=30       # o pod'un ÖLMEDEN önceki son satırları
make logs                                                  # tüm uygulama pod'larının şu anki logları (canlı akar; Ctrl+C)
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

Diğer adresler: http://prometheus.localtest.me (ham metrik, giriş yok) · http://argocd.localtest.me
(12+; kullanıcı `admin`, şifre kurulumda rastgele üretilir:
`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

## Her seviyede aynı komutlar

```
make up        # profil → build → push → deploy → rollout → smoke
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

Kök klasörde: `make wipe CONFIRM=1` (bütün verileri sil, kurulumu koru) · `make verify` (kümesiz
doğrulama: gofmt, vet, lint, test) · `make help` (hepsi).

## Ortamın kendisi de ölçülür

Bir deneyin sonucu, altındaki kümenin durumundan bağımsız değildir: doygun bir VM'de ölçülen gecikme
uygulamanın değil kümenin gecikmesidir. Platform bu yüzden aşağıdaki kurallarla kurulur; bir sonuç
"açıklanamaz" göründüğünde ilk bakılacak yer burası.

| Kural | Neden | Nerede |
|---|---|---|
| Seviye yalnızca kendi bileşenlerini açık tutar | Bütün operatörler ve tam gözlem yığını boşta 6 çekirdeğin ~5.6'sını yer; VM swap'e girer, kubelet NotReady olur ve ölçüm uygulamayı değil ölmekte olan kümeyi ölçer | `platform/lib/profile.sh` (`make up`'ın ilk adımı) |
| Prometheus kısa saklar, ölçülü kazır (6 saat · uygulama 10 sn · küme 30 sn) | Merdiven kısa deneyler koşar; uzun saklama ve sık kazıma, gözlenen sistemle aynı CPU/bellek bütçesinden yer | `platform/helm/kube-prometheus-stack.values.yaml` |
| Bellek limiti kararlı duruma değil kurtarma yoluna göre seçilir | Sert bir yeniden başlamadan sonra Prometheus WAL'ı oynatır ve kararlı durumdan çok daha fazla bellek ister; limit dar olursa oynatma ortasında OOM olur ve döngüye girer | aynı dosya (`limits.memory: 3Gi`) |
| Grafana'nın bellek limiti çalışma kümesinin rahat üstünde | Chart, Go çöp toplayıcısının hedefini (GOMEMLIMIT) limitin %90'ına koyar; hedef çalışma kümesine yakınsa GC durmadan çalışır, paneller saniyelerce bekler ve probe'lar düşer | aynı dosya (`grafana.resources`) |
| Lider kiraları uzun (60 / 45 / 5 sn) | Doygun bir VM'de kira yazması onlarca saniye sürebilir; kısa kira controller'ları durmadan yeniden başlatır | `platform/kind/cluster.yaml`, `platform/Makefile` |
| Kyverno'nun kaynak webhook'ları hata durumunda geçirir (fail-open) | Kyverno yeniden başlarken kümedeki her `kubectl apply` durmasın; politika kuralları yine zorunlu | `platform/Makefile` (`security`) |
| KEDA her seviyede açık | Kapalı bir KEDA `external.metrics.k8s.io` APIService'ini endpoint'siz bırakır; API keşfi bozulur ve namespace denetleyicisi hiçbir namespace'i silemez | `platform/lib/profile.sh` |
| Redpanda topic'leri görünür bir Job ile oluşur | Broker ayarları `--set redpanda.*` bayraklarıyla verilemez (v24.2.7 bunları reddeder); Job'ın sonucu `kubectl get jobs`'ta okunur | seviyelerin `deploy/redpanda.yaml`'ı |
| Yük testleri hız sınırından muaf ayrı bir girişten gider | Uygulama ve ingress hız sınırları, kapasite ölçen bir yükü de reddeder; muafiyet başlık + Secret ile, limiter'ı sınayan deneyler ise genel girişi kullanır | `lvlNN-load.localtest.me`, `platform/lib/loadtest.sh` |
| Düğüm dondurma deneyi düğümün Ready'ye döndüğünü doğrulayarak biter | `docker pause`/`unpause` sonrası containerd'nin PLEG'i ölü kalabilir; düğüm fark edilmeden NotReady kalır | P07-07 |
| Her altyapı bileşeninin ServiceMonitor'ü var; scriptler metriğin varlığını önce sorar | Var olmayan bir metrik 0 gibi okunur; "0" ile "ölçülmedi" ayrılmazsa script "sorun yok" der | seviyelerin `servicemonitor.yaml`'ı, `need_metric` |
| `make deploy`, önceki namespace'in silinmesini bekler | `make down` silmeyi arka planda bırakır; hemen ardından gelen kurulum "namespace is being terminated" ile düşer | `ladder.mk` |
| `make stop`, `docker stop`'tan önce düğümün içinde kubelet ve containerd'yi durdurur | `docker stop` bir systemd konteynerine SIGKILL gönderirse containerd'nin meta veri deposu yazma ortasında kalabilir | `platform/Makefile` (`stop`) |

## Ölçüm kuralları

Bu merdivenin ikinci öğretisi sistemler hakkında değil, **ölçüm** hakkında. Her kural, uyulmadığında
scriptin "sorun yok" deyip sorunun yine de orada olduğu bir durumu önler. Yeni bir reproduce yazarken
listeye bak ([docs/PROBLEM-TEMPLATE.md](docs/PROBLEM-TEMPLATE.md)).

| Kural | Uyulmazsa |
|---|---|
| Ölçüm **penceresi**, ölçtüğün olaydan kısa olmamalı | `rate(...[1m])` 45 sn'lik bir yükün yarısını kaçırır, oranı boşta geçen zamanla seyreltir |
| Ölçüm **çözünürlüğü**, olaydan ince olmalı | 1-2 sn'lik bir TTL darbesi 10-30 sn'lik kazımada düzleşir → P03-07 pod'un `/metrics` ucunu saniyede bir örnekler |
| İki fazı **ayrı** ölç | `increase(...[3m])` iki fazı karıştırır; doğrusu yük öncesi/sonrası sayaç farkı (P03-04) |
| Deneyin **hazırlığı** da arızaya tabidir | Chaos yükten önce uygulanırsa k6'nın hazırlık adımı zaman aşımına uğrar ve yük hiç koşmaz → `seedLinks` zaman bütçelidir (P05-02) |
| **Hangi** iki olayın yarıştığını yaz | Yanlış pencereyi büyütmek yarışı üretmez; `defer` ile büyütülen pencere hiç büyümez (P04-05) |
| Sorunlar birbirini **maskeler** | Eşzamanlılık çökmesi çakışma ve OOM kanıtını saklar → izole ederken 1 VU |
| Anlık metrik, **ölüp dirilen** süreci kaçırır | Tepe bellek + `OOMKilled`/exit 137 kanıtı şart |
| Korumayı **kim** veriyor? | 413'ü uygulama değil ingress verebilir → pod'a port-forward ile doğrudan test et |
| Yük, probe'un **failureThreshold**'undan uzun sürmeli | Aksi hâlde probe hiç düşmez ve "probe iyi" sonucu çıkar |
| Bağımlılığın hazır olması **önkoşuldur**, ölçüm değil | Önceki deneyin öldürdüğü Redis, sonraki deneyi ilgisiz bir hatayla düşürür → `dep_pod` |
| Deney kümeyi **temiz** bırakır | Takılı kalan bir cordon, ilgisiz bir seviyeyi "rollout timeout" ile düşürür → `on_cleanup` + `trap` |
| Kanıtı okunabilirlik uğruna **kırpma** | `EXPLAIN` çıktısını `head -3` ile kırpmak, aranan "Parallel Seq Scan" satırını keser |
| Çıkış koduna değil, **çıktı işaretine** bak | Çöken bir script (exit 1), `verify-prev`'de NOT-REPRODUCED sayılırsa yeşil yanar |
| **Var olmayan metrik** sıfırla aynı görünür | ServiceMonitor'ü olmayan bir bileşende `promq` 0 döner ve script "sorun yok" der → `need_metric` |
| Eşik, iddian olmadan **oluşmayacak** bir şeyi ölçmeli | `busy_p99 >= base_p99` gürültüyle geçilir; ayırt edici işaret paylaşılan havuzda bekleme |
| Deney **kendisi müdahale ederse** iki seviye aynı çıkar | Tüketiciyi kendisi açan bir P06-02, "07 bunu çözdü" iddiasını sınayamaz |
| Arızanın işareti her zaman **hata kodu değildir** | Donmuş bir düğümde 5xx yoktur, yalnızca iş bitmez (120 sn'de 13 istek) |
| Bir korumanın değerini ölçerken **diğer korumayı kaldır** | 5 sn'lik preStop, readiness'ın "HAYIR" demesinin etkisini gizler |
| **Düşemeyen** bir deney, deney değildir | Tuzağı hiç açmayan bir script her koşulda aynı hükmü verir. Karar yazınca sor: *iddiam yanlış olsaydı bu ölçü ne gösterirdi?* |
| Tuzağın **koda bağlı** olduğunu doğrula | Config'de tanımlı ama kodda okunmayan bir `TRAP_*` açılır, sistem değişmez, script yine karar basar → lint kuralı 9 |
| `>=` / `<=` kararları **0 vs 0'da geçer** | Başarısız bir ölçüm, geçen bir deneye dönüşür |
| **Boş** ölçüm, olumsuz ölçüm değildir | Pod çıktı üretmeden okunan log "yetkisiz pod DB'ye ulaştı" gibi görünür; oysa engellenmiştir (P13-03) |
| Koruma devreye girdiğinde **neyi değerlendirdiğini** sor | Analiz Prometheus'a ulaşamadığı için duran bir canary, "kötü sürüm yakalandı" diye okunabilir (P12-01) |
| Cevabı **kendi yapılandırmanla sabitlenmiş** soruyu sorma | `hot_standby_feedback=on` iken "çakışma oldu mu?" sorusunun cevabı zaten hayırdır (P09-04) |
| **Hangi rolle** baktığını söyle | RLS açıkken `postgres` süper kullanıcısı tüm satırları görür: politika çalışır, sen göremezsin (P13-02) |
| Yavaşlatacağın **süreci doğru seç** | Yarışın penceresi offset commit'indeyse veritabanını geciktirmek yarışı üretmez (P06-01) |
| Aracın **kendi hatasını susturma** | `curl -f` gövdeyi atar; geriye "curl 22" kalır ve Prometheus'un gerçek hata mesajı kaybolur |
| Yük üretecinin **gerçekten koştuğunu** doğrula | Senaryo tanımlı k6 dosyalarında `--duration` koşuyu hiç başlatmaz; `\|\| true` bunu yutarsa 0 istek "fark yok" diye okunur → `k6run.sh` bayrakları çevirir |
| **Belgelediğin aracı bağla** | README'nin önerdiği pprof komutu, `net/http/pprof` kayıtlı değilse okuyucuya "teknik çalışmıyor" dedirtir |
| Hata mesajı **neyin** başarısız olduğunu göstermeli | Kırpılmış bir sorgu metni iki farklı bozuk sorguyu aynı gösterir; Prometheus'un verdiği sütun numarası işe yaramaz → `promq` sorgunun tamamını basar |
| İç içe tırnaklı **komut ikamesi** argümanı bozar | `num "$(promq "…{a=\\"x\\",b=\\"y\\"}…")"` içinde iç tırnak erken biter, `{a,b}` bash'in süslü parantez genişletmesine girer ve sorgu `parse error` alıp 0 döner |
| **Nil bir bağımlılığın** arkasındaki bayrak kapalı değil, görünmezdir | Bağımlılığı hiç verilmemiş bir kod yolu bayrağı okur, nil görür ve hiçbir şey yapmaz; hiçbir şey patlamaz, yalnızca deney anlamsızlaşır |
| **Bayat** bir çıktı dosyası, bu koşunun çıktısı sanılır | Diskte kalan bir `$K6_SUMMARY`, k6 hiç başlamadığında önceki koşunun sayılarını verir → her koşu dosyayı önce siler |
| Sayaç deltası **kazıma aralığından hızlı** okunamaz | Kazıma aralığı dolmadan okunan fark, önceki trafiğin artığını ölçer → `settle_scrape` |
| **Tabansız** bir tepe, tepe değildir | "KEYS * gecikmeyi fırlattı" demek için KEYS olmadan gecikmenin ne olduğu da ölçülmelidir (P04-07) |
| **Reddedilen** çağrı, bağımlılığa giden çağrı değildir | Devre kesici açıkken "bağımlılık çağrısı"nın çoğu hiç gitmez; iki fazın istek sayısı farklıysa mutlak sayı değil **oran** karşılaştırılır (P10-04) |
| Bekleme bütçesi, beklediğin şeyin **toparlanma süresinden** kısa olmamalı | CNPG replikası dönmeden biten bir bekleme, sonraki scripte "ortam bozuk" dedirtir — ortamı değil önceki deneyi tarif eden bir hata |
| Arızayı **kaldırmak**, etkisinin geçmesi demek değil | Chaos nesnesi silindiğinde CNPG replikayı hâlâ yeniden başlatıyor olabilir; bekleyecek yer, bozan scriptin kendisi |
| **ATLANDI** ile **HATA** aynı kovaya girmemeli | Ölçemediğini fark edip 2 ile çıkan script dürüst davranır; ikisini karıştıran rapor ölçüm disiplinini cezalandırır |
| `grep -c` sıfırda **"0" basar ve 1 ile çıkar** | Alışkanlıkla eklenen `\|\| echo 0` değişkeni `0\n0` yapar; sonraki `(( ))` sözdizimi hatası verir ve bekleme döngüsü hiç sağlanmayacak bir koşulu bekler |
| **Bulamamak hata değildir** | `grep` eşleşme bulamazsa 1 döner; `pipefail` + atama + `set -e` scripti hüküm basmadan öldürür — üstelik genelde sağlıklı yolda |
| `${var:-varsayılan}` içindeki **kesme işareti** tırnak açar | "Endpoint'e" gibi bir varsayılan kapanış `}`'ını yutar ve script `bad substitution` ile ölür — yalnızca değişken boşken |
| Ölçü, **desteklediği iddiaya** göre daraltılmalı | "Uygulama yedekliliği" toplam 5xx ile ölçülürse, `drain`'in tek Postgres'i tahliye etmesinden gelen 5xx'ler de sayılır (P01-03) |
| Pod'un **"Running" olması**, servisin cevap vermesi değildir | WAL oynatan bir Prometheus Running görünürken her sorguya 503 döner |
| **Agrege bir APIService'i endpoint'siz bırakma** | Park edilen tek bir bileşen (KEDA), API keşfini bozup küme çapında namespace silmeyi durdurur |
| **Her zaman boş** bir panel, olmayan panelden kötüdür | Kazınmayan bir metrik "ihlal yok" gibi okunur, "veri yok" değil |

## Sayılarla

| | |
|---|---|
| Seviye | 15 (`00-naive` … `14-modern`) |
| Reproduce scripti | **108** (`PNN-XX.sh`, her biri REPRODUCED/NOT-REPRODUCED/SKIPPED döner) |
| `TRAP_*` alıştırma bayrağı | 33 |
| Go satırı (yorumlar dahil) | ~69 000 |
| Türkçe README | ~5 000 satır |
| Paylaşılan Grafana dashboard'u | 16 (`$level` dropdown'lı, tek set) |
| k6 senaryosu · chaos şablonu | 10 · 12 |
