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
| 02 | [`02-postgres`](02-postgres) | Kalıcılık ve yatay ölçek | Postgres, stateless N replika | Her redirect DB'ye; pool biter |
| 03 | [`03-local-cache`](03-local-cache) | Süreç içi önbellek | LRU + TTL + singleflight | Pod'lar arası tutarsızlık |
| 04 | [`04-redis-cache`](04-redis-cache) | Paylaşılan önbellek | Redis cache-aside | Redis SPOF, hot key |
| 05 | [`05-async-analytics`](05-async-analytics) | Yazmayı okuma yolundan çıkar | Bounded kuyruk + batch writer | At-most-once kayıp |
| 06 | [`06-event-stream`](06-event-stream) | Olay akışı | Redpanda + consumer | Duplicate, lag, poison |
| 07 | [`07-services-autoscaling`](07-services-autoscaling) | Servisleri ayır | 3 servis, HPA, KEDA | Darboğaz DB'ye kayar |
| 08 | [`08-rate-limiting`](08-rate-limiting) | Gürültülü komşu | Dağıtık limiter | Limiter'ın kendi bağımlılığı |
| 09 | [`09-database-scaling`](09-database-scaling) | DB darboğazı | CNPG, Pooler, PITR | Replikasyon gecikmesi |
| 10 | [`10-resilience`](10-resilience) | Hata izolasyonu | timeout, retry, breaker, shedding | Ayar karmaşıklığı |
| 11 | [`11-observability-deep`](11-observability-deep) | Neden yavaş? | trace, exemplar, SLO, profil | Sampling, kardinalite |
| 12 | [`12-delivery`](12-delivery) | Güvenli dağıtım | Argo CD, Rollouts canary | Migration/rollback uyumu |
| 13 | [`13-security-tenancy`](13-security-tenancy) | Kim, neye, ne kadar | JWT, RLS, NetworkPolicy, Kyverno | Operasyonel sürtünme |
| 14 | [`14-modern`](14-modern) | Son hal | Redis HA, L1+L2, gRPC, kapasite modeli | "Yolun devamı" listesi |

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
| 15 seviyenin tamamı (`00-naive` … `14-modern`) | ✅ kod + deploy + README + reproduce scriptleri yazıldı |
| Doğrulama (`make repro`, `make verify-prev`) | 🔄 00-05 doğrulandı (03: 6/7), 06+ sürüyor |
| `platform/lib/profile.sh` (seviyeye göre bileşen aç/kapat) | ✅ **seviyeden önce koş** — küme 6 CPU |

## Faz A ölçüm sonuçları

| | 00-naive | 01-hardened |
|---|---|---|
| Kendi sorunları | 10/10 REPRODUCED | 8/8 REPRODUCED |
| `make verify-prev` | — | 7/7 NOT-REPRODUCED (P00-01/04/05/06/07/09/10) |
| Bilerek açık bırakılan | — | P00-02 kalıcılık · P00-03 ölçek · P00-08 bellek → 02 |
| Birim test | yok (bilerek) | `go test -race ./...` yeşil |

Örnek ölçümler: 4 karakterlik kod 10 000 linkte **3 çakışma** (beklenen 3.4) · 3 replikada
**%66 404** · rollout penceresinde **142×5xx** ayrı, restart sonrası **38 734×404** ayrı sayıldı ·
tepe heap **185 MB / 62 872 link** → OOMKilled · sağlık ucu iş zincirine sokulunca
**77 readiness Unhealthy** olayı (pod ölmeden Endpoints'ten düşüyor).

## Ortamın kendisi de ölçülmeli

Bu merdivenin en pahalı dersi seviyelerin içinden değil, **altından** çıktı: doğrulama turlarındaki
"açıklanamayan" sonuçların çoğu uygulamanın değil, kümenin durumuydu.

| Ne oldu | Nasıl göründü | Kalıcı çözüm |
|---|---|---|
| Redpanda v24.2.7 `--set redpanda.*` bayraklarını reddediyor | Broker 06'dan beri crash-loop; stream deneyleri **ölü broker'ı ölçtü** ("75 bin üretici hatası" bulgu sanıldı) | Bayraklar kaldırıldı; topic'ler görünür bir **Job** ile oluşuyor |
| `docker pause` edilen node, unpause sonrası containerd PLEG'i ölü kalıyor | Bir node ~1 saat NotReady; oradaki Chaos Mesh/Argo/KEDA çürüdü, chaos sessizce çalışmadı | P07-07 containerd'yi restart edip **Ready'yi doğruluyor** |
| Tüm operatörler + gözlemlenebilirlik yığını boşta 6 çekirdeğin 5.6'sını yiyor | VM swap'te; kubelet NotReady, controller-manager lider kaybı, k6 120 sn'de 13 istek | `platform/lib/profile.sh` + Prometheus 6s/30s → CPU %560 → %236 |
| 07'den sonra altyapı ServiceMonitor'ları kayıp | `promq` "0" döndü, script "sorun yok" dedi | Ortak `servicemonitor.yaml` + `need_metric` |
| `make down` namespace'i arka planda siliyor | Sonraki `make up` "namespace is being terminated" ile düştü | `make deploy` silinmeyi **bekliyor** |

## Ölçüm dersleri (deneyleri koşarken öğrenilenler)

Bu merdivenin ikinci öğretisi sistemler hakkında değil, **ölçüm** hakkında. Aşağıdakilerin hepsi
gerçekten başımıza geldi: script "sorun yok" dedi, sorun oradaydı. Yeni bir reproduce yazarken
listeye bak.

| Kural | Nasıl ısırdı |
|---|---|
| Ölçüm **penceresi**, ölçtüğün olaydan kısa olmamalı | `rate(...[1m])` 45 sn'lik yükün yarısını kaçırdı, oranı boşta geçen zamanla seyreltti |
| Ölçüm **çözünürlüğü**, olaydan ince olmalı | 1-2 sn'lik TTL darbesi Prometheus'un 15 sn'lik örneklemesinde düzleşti → pod'un `/metrics` ucunu saniyede bir örnekle (P03-07) |
| İki fazı **ayrı** ölç | `increase(...[3m])` iki ölçümü karıştırdı; doğrusu yük öncesi/sonrası sayaç farkı (P03-04) |
| Deneyin **hazırlığı** da arızaya tabidir | Chaos'u yükten önce uygulayınca k6 setup'ı zaman aşımına uğradı, yük hiç koşmadı (P05-02) → `seedLinks` artık zaman bütçeli |
| **Hangi** iki olayın yarıştığını yaz | Yanlış pencere büyütüldü; üstelik `defer` ile, yani hiç (P04-05) |
| Sorunlar birbirini **maskeler** | Eşzamanlılık çökmesi, çakışma ve OOM kanıtını sakladı → izole ederken 1 VU |
| Anlık metrik, **ölüp dirilen** süreci kaçırır | Tepe bellek + `OOMKilled`/exit 137 kanıtı şart |
| Korumayı **kim** veriyor? | 413'ü uygulama değil ingress veriyordu → pod'a port-forward ile doğrudan test et |
| Yük, probe'un **failureThreshold**'undan uzun sürmeli | Aksi hâlde "probe iyi" dersin |
| Bağımlılığın hazır olması **önkoşuldur**, ölçüm değil | Bir önceki deney Redis'i öldürdü, sonraki deney ilgisiz bir hatayla düştü → `dep_pod` |
| Deney, cluster'ı **temiz** bırakmalı | Takılı kalan bir cordon, ilgisiz bir seviyeyi "rollout timeout" ile patlattı → `on_cleanup` + `trap` |
| Kanıtı okunabilirlik uğruna **kırpma** | `EXPLAIN` çıktısını `head -3` ile kırpmak tam da aradığın "Parallel Seq Scan" satırını kesti |
| Çıkış koduna değil, **çıktı işaretine** bak | Script çökünce (exit 1) `verify-prev` bunu "NOT-REPRODUCED" sanıp yeşil yaktı |
| **Var olmayan metrik** ile sıfır aynı görünür | 07-14'te postgres/redis ServiceMonitor'ları eksikti; `promq` "0" döndü, script "sorun yok" dedi → `need_metric` |
| Eşiğin, iddian olmadan **oluşmayacak** bir şeyi ölçmeli | `busy_p99 >= base_p99` gürültüyle geçilir; ayırt edici işaret paylaşılan havuzda bekleme |
| Deney **kendisi müdahale ederse** iki seviye aynı çıkar | P06-02 tüketiciyi kendi açıyordu; "07 bunu çözdü" iddiası doğrulanamıyordu |
| Arızanın işareti her zaman **hata kodu değildir** | Donmuş node'da 5xx yok, sadece iş bitmiyordu (120 sn'de 13 istek) |
| Bir korumanın değerini ölçerken **diğer korumayı kaldır** | 5 sn'lik preStop, readiness'ın "HAYIR" diyebilmesini gizliyordu |
| **Düşemeyen** bir deney, deney değildir | P08-04 tuzağı hiç açmıyordu; P11-08 "metriklerde görünmez" tezini metrik farkıyla sınıyordu. Karar yazınca sor: *iddiam yanlış olsaydı bu ölçü ne gösterirdi?* |
| Tuzağın **koda bağlı** olduğunu doğrula | Dört `TRAP_*` config'de vardı, kodda hiç okunmuyordu — deney bayrağı açıyor, sistem değişmiyor, script yine karar basıyordu (lint kuralı 9 artık yakalıyor) |
| `>=` / `<=` kararları **0 vs 0'da geçer** | Başarısız bir ölçüm, geçen bir deneye dönüşüyordu — kanıt gibi görünen bir yanlış pozitif |
| **Boş** ölçüm, olumsuz ölçüm değildir | Pod çıktı üretmeden log okununca "yetkisiz pod DB'ye ulaştı" sanıldı; gerçekte engellenmişti (P13-03) |
| Koruma devreye girdiğinde **neyi değerlendirdiğini** sor | Canary, analiz Prometheus'a ULAŞAMADIĞI için durdu; script bunu "kötü sürüm yakalandı" diye okudu (P12-01) |
| Cevabı **kendi yapılandırmanla sabitlenmiş** soruyu sorma | `hot_standby_feedback=on` iken "çakışma oldu mu?" sorusunun cevabı zaten hayırdır (P09-04) |
| **Hangi rolle** baktığını söyle | RLS açıkken `postgres` süper kullanıcısı tüm satırları görüyordu: politika çalışıyordu, biz göremiyorduk (P13-02) |
| Yavaşlatacağın **süreci doğru seç** | Yarışın penceresi offset commit'indeydi; script veritabanını geciktiriyordu (P06-01) |
| Aracın **kendi hatasını susturma** | `curl -f` gövdeyi atıyor, geriye "curl 22" kalıyor ve Prometheus'un gerçek mesajı kayboluyor |
| Yük üretecinin **gerçekten koştuğunu** doğrula | `--duration`, senaryo tanımlı k6 dosyalarında koşuyu hiç başlatmıyor; `\|\| true` bunu yutuyor ve 0 istek "fark yok" diye okunuyordu |
| **Belgelediğin aracı bağla** | README pprof komutu öneriyordu, `net/http/pprof` hiç kaydedilmemişti; okuyucu tekniğin çalışmadığı sonucuna varır |
| Hata mesajı **neyin** başarısız olduğunu göstermeli | `promq` başarısız sorguyu `%.70s` ile kırpıyordu; iki farklı bozuk sorgu ekranda aynı görünüyor ve Prometheus'un verdiği sütun numarası işe yaramıyordu. Kırpmayı kaldırınca 26 dosyadaki hata bir bakışta çözüldü |
| İç içe tırnaklı **komut ikamesi** argümanı bozar | `num "$(promq "…{a=\\"x\\",b=\\"y\\"}…")"` içinde iç tırnaklama erken biter, `{a,b}` bash'in süslü parantez genişletmesine girer ve **parantezler kaybolur**. 45 sorgu sessizce `parse error` alıp 0 döndü; deneyler sıfırları karşılaştırdı |
| **Nil bir bağımlılığın** arkasındaki bayrak kapalı değil, görünmezdir | 07-14'te `api.SetRedis` hiç çağrılmıyordu; `TRAP_READY_CHECKS_REDIS` bayrağını okuyup nil görüyor ve hiçbir şey yapmıyordu. Hiçbir şey patlamaz, hiçbir şey loglanmaz — yalnızca deney anlamsızlaşır |
| **Bayat** bir çıktı dosyası, bu koşunun çıktısı sanılır | `$K6_SUMMARY` koşular arasında diskte kalıyordu; k6 hiç başlamayınca önceki turun sayıları okundu ve 897 istekte 73710 adet 5xx raporlandı |
| Sayaç deltası **kazıma aralığından hızlı** okunamaz | Tek bir list isteği "≈61 sorgu" çıktı (ölçülen, ondan önceki trafiğin artığıydı); araya rollout girince fark negatife inip 0'a kırpıldı → `settle_scrape` |
| **Tabansız** bir tepe, tepe değildir | P04-07 "KEYS * gecikmeyi fırlattı" diyordu ama KEYS olmadan gecikmenin ne olduğunu hiç ölçmemişti |
| **Reddedilen** çağrı, bağımlılığa giden çağrı değildir | Devre kesici açıkken 1663 "bağımlılık çağrısı"nın 1498'i hiç gitmemişti; üstelik iki fazın istek sayısı çok farklı olduğu için mutlak sayı değil **oran** karşılaştırılmalı (P10-04) |
| Bekleme bütçesi, beklediğin şeyin **toparlanma süresinden** kısa olmamalı | CNPG replikası 2 dakikada dönmeyince sonraki script "ortam bozuk" dedi — ortamı değil önceki deneyi tarif eden bir hata |
| Arızayı **kaldırmak**, etkisinin geçmesi demek değil | Chaos nesnesi silindi, CNPG replikayı yeniden başlatıyordu; bedelini bir sonraki script ödedi. Bekleyecek yer, bozan scriptin kendisi |
| **ATLANDI** ile **HATA** aynı kovaya girmemeli | Ölçemediğini fark edip 2 ile çıkan script dürüst davranıyor; ikisini karıştıran rapor, ölçüm disiplinini cezalandırır |
| `grep -c` sıfırda **"0" basar ve 1 ile çıkar** | Alışkanlıkla eklenen `\|\| echo 0` de çalışıp değişkeni `0\\n0` yapıyor; sonraki `(( ))` sözdizimi hatası veriyor ve bekleme döngüsü asla sağlanmayacak bir koşulu bekliyordu |
| **Her zaman boş** bir panel, olmayan panelden kötüdür | Kyverno metrikleri hiç kazınmıyordu: "ihlal yok" gibi okunuyordu, "veri yok" değil |

## Sayılarla

| | |
|---|---|
| Seviye | 15 (`00-naive` … `14-modern`) |
| Reproduce scripti | **108** (`PNN-XX.sh`, her biri REPRODUCED/NOT-REPRODUCED döner) |
| `TRAP_*` alıştırma bayrağı | 33 |
| Go satırı (yorumlar dahil) | ~58 000 |
| Türkçe README | ~4 800 satır |
| Paylaşılan Grafana dashboard'u | 16 (`$level` dropdown'lı, tek set) |
| k6 senaryosu · chaos şablonu | 9 · 10 |

## Kurulum

```bash
brew install kind helm k6 kustomize jq
# Docker Desktop: 6 CPU / 10 GB (Settings → Resources)
cd platform && make minimal          # 00-05 için yeterli
make keda cnpg chaos                 # 06-10
make tempo argo security             # 11-14
```

Her seviye kendi bileşenlerini `deploy/` içinde taşır; platform yalnızca **operatörleri ve
gözlemlenebilirlik yığınını** kurar.

Kurumsal ağdaysan (Cloudflare Gateway / Zscaler gibi TLS araya girmesi) `make cluster` adımı kök CA'yı
otomatik olarak node'lara kurar (`platform/kind/trust-ca.sh`); olmadan image çekilemez.
