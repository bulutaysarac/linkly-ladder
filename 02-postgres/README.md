# 02 — postgres · "Kalıcılık ve yatay ölçek"

## 1. Bu seviye ne?

Durum süreçten çıktı: linkler artık Postgres'te, uygulama **durumsuz**. Bu tek kelime N replikayı,
temiz rollout'u, node drain'i ve yatay ölçeklenmeyi satın alıyor — hiçbiri 01'de yoktu, Kubernetes
özelliği eksik olduğu için değil, veri sürecin içinde yaşadığı için. Bedeli şu: artık **her istek**
ağ üzerinden, bu seviyenin hep ayakta ve sonsuz hızlı varsaydığı bir veritabanına gidiyor.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress-nginx<br/>lvl02.localtest.me]
  I --> A1 & A2 & A3

  subgraph APP["linkly · 3 replika · DURUMSUZ"]
    A1[pod 1]
    A2[pod 2]
    A3[pod 3]
  end

  A1 & A2 & A3 -->|pgx havuzu<br/>pod başına 25| PG[("postgres:17<br/>StatefulSet × 1<br/>max_connections=100")]
  J[migrate Job<br/>tek seferlik] -.->|şema| PG
  PG -.->|exporter| PR[(Prometheus)]
  APP -.->|/metrics| PR
```

Kritik asimetri: **uygulama yedekli, veritabanı değil.** Üç pod da aynı tek Postgres'e bağlı;
yedeklilik zincirin en zayıf halkası kadardır (P02-03).

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P00-02 / P01-01 | Restart = tüm linkler gider | Durum Postgres'te; pod'lar silinip yeniden doğsa da veri PVC'de |
| P00-03 / P01-02 | `replicas>1` → rastgele 404 | Tek paylaşılan kaynak; 3 replikanın üçü de aynı veriyi görüyor |
| P01-03 | Tek replika + PDB = yanılsama | 3 replika + `topologySpreadConstraints` + `minAvailable: 2` → drain artık gerçekten güvenli |
| P01-04 | Bellek sınırsız büyür | Uygulama artık veri tutmuyor; bellek istek sayısıyla değil, eşzamanlılıkla ölçekleniyor |

Ayrıca **kısmen**: P01-08 (tıklama sayacı) hâlâ istek yolunda ama artık en azından **kalıcı** —
tam çözümü 05'te. `problems/SOLVES` makine-okunur listeyi tutuyor; `make verify-prev` doğruluyor.

**Çözülmeyenler (bilerek):** P00-08 bellek tavanı artık uygulamada yok ama **Postgres'te var**
(disk, bağlantı, kilit). P01-05 süreç içi limit hâlâ yanlış ve artık gerçekten 3 katı (P02-04).

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl02.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl02.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl02 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P02-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

Veritabanına bakmak için:
```bash
kubectl -n lvl02 exec -it $(kubectl -n lvl02 get pod -l app.kubernetes.io/name=postgres -o name) -c postgres -- psql -U linkly -d linkly
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyede yeni: `GET /api/links` (kiracıya göre listeler) ve `X-Tenant-ID` artık **gerçekten iş
yapıyor** — silme ve listeleme kiracıyla sınırlı. Uyarı: bu bir **kimlik doğrulama değildir**,
header'ı herkes gönderebilir; 13'te gerçek kimliğe bağlanacak.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P02-01 | Her redirect = DB sorgusu | `make repro P=P02-01` | Postgres → DB queries/CPU | 03 · 04 |
| P02-02 | Havuz taşması: replika × pool > max_connections | `CONFIRM=1 make repro P=P02-02` | Postgres → connections vs max | 09 |
| P02-03 | DB tek nokta; failover yok | `CONFIRM=1 make repro P=P02-03` | Postgres → pg_up; App RED → 5xx | 09 |
| P02-04 | Süreç içi limit 3 replikada 3 katı | `CONFIRM=1 make repro P=P02-04` | Rate limit → allow by pod | 08 |
| P02-05 | Index yok → seq scan | `make repro P=P02-05` | Postgres → seq scan / query p99 | seviye içi (002) |
| P02-06 | Yavaş DB + timeout yok → havuz tıkanır | `make repro P=P02-06` | Postgres → acquire wait p99 | seviye içi · 10 |
| P02-07 | **TRAP** migration her pod'da → yarış | `make repro P=P02-07` | Pods → Restart | seviye içi (Job) |
| P02-08 | Sıcak link → satır kilidi kuyruğu | `make repro P=P02-08` | Postgres → locks, dead tuples | 05 · 06 |
| P02-09 | Sır düz metin (git + Secret + env) | `make repro P=P02-09` | — | 13 |
| P02-10 | **TRAP** readiness DB'ye bakar → tam kesinti | `CONFIRM=1 make repro P=P02-10` | Pods → hazır endpoint sayısı | seviye içi · 10 |

---

### P02-01 · Her redirect bir DB sorgusu

**Belirti:** Redirect gecikmesi 01'e göre iki-üç kat arttı; Postgres CPU'su trafikle doğru orantılı
tırmanıyor. Uygulama pod'ları ise büyük ölçüde boşta.
**Neden:** 01'de redirect bir map aramasıydı (nanosaniye). Şimdi **istek başına iki sorgu**: `SELECT`
(linki bul) + `UPDATE` (tıklamayı say). Okuma ağırlıklı bir sistemde (1 yazma : 100–1000 okuma) bu,
yükün tamamını tek bir paylaşılan kaynağa taşımak demek. [Topic · Konu: Okuma yolu, cache-aside gerekçesi]

**Reproduce (adım adım):**
1. `make repro P=P02-01` — 60 sn redirect yükü verir, istek başına sorgu sayısını hesaplar
2. `make grafana` → `05 · Postgres` → "DB queries by op" ve "DB CPU"

**Ölçülen tur:** `563 redirect/s → 1114 DB sorgu/s (istek başına 2.0) · PG CPU 0.31 çekirdek ·
redirect p99 96.7 ms (DB get p99 49.6 ms)`.
**Grafana:** `05 · Postgres` → "DB queries by op", "DB CPU"; `02 · App RED` → "p99 by route".
**Nerede çözülüyor:** `UPDATE`'i 05 (asenkron analitik), `SELECT`'i 03/04 (önbellek) kaldıracak.
Zarf arkası: 10k rps redirect = 20k sorgu/s. Tek Postgres bunu taşımaz — bu yüzden bir URL
kısaltıcıda **önbellek bir optimizasyon değil, mimarinin kendisidir.**

---

### P02-02 · Bağlantı havuzu taşması

**Belirti:** Replika sayısını artırdığında uygulama 503 döner; Postgres logunda
`FATAL: sorry, too many clients already`.
**Neden:** Her pod havuzunu *tek başınaymış gibi* boyutlar. 3 × 25 = 75 < 100 iken sorun yok;
10 × 25 = 250 > 100 olduğu anda Postgres yeni bağlantıları reddeder. Havuz boyutu **yerel** bir karar
gibi görünür ama **global** bir kaynağı tüketir. [Topic · Konu: Bağlantı yönetimi, paylaşılan kaynak]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P02-02` — matematiği basar, 10 replikaya çıkar, yük verir, sayar
2. `kubectl -n lvl02 logs -l app.kubernetes.io/name=linkly | grep -i 'too many clients'`

**Grafana:** `05 · Postgres` → "connections vs max" (tavana yapışır), "App pool: empty acquire/s".
**Nerede çözülüyor:** 09 (PgBouncer/Pooler). Dikkat: doğru cevap havuzu küçültmek **değildir** —
o zaman da uygulama tarafında kuyruk oluşur (P02-06'nın aynısı). Doğru cevap araya bir havuz
yöneticisi koymaktır: yüzlerce uygulama bağlantısı, onlarca gerçek DB bağlantısına eşlenir.

---

### P02-03 · Veritabanı tek nokta

**Belirti:** Postgres pod'u ölünce hem yazma hem **okuma** durur. Uygulamanın üç replikası da ayakta,
hazır ve hiçbir şey yapamıyor.
**Neden:** Yedeklilik zincirin en zayıf halkası kadardır. "3 replika" uygulamanın yedekli olduğunu
söyler, sistemin değil. [Topic · Konu: Tek nokta arıza, yedeklilik sınırı]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P02-03` — yük altında Postgres pod'unu siler, kesinti penceresini ölçer
2. Aynı anda `kubectl -n lvl02 get pods -w` ile uygulama pod'larının **Ready kaldığını** gör

**Grafana:** `05 · Postgres` → "pg_up"; `02 · App RED` → 5xx; `01 · Pods` → "hazır endpoint sayısı"
(bu deneyde **düşmez** — karşılaştır: P02-10'da sıfıra iner).
**Nerede çözülüyor:** 09 (CNPG: primary + 2 replica + otomatik failover). Failover da anlık
değildir; 09 o pencereyi ve `read-your-writes` ihlallerini ölçecek.

---

### P02-04 · Süreç içi hız sınırı 3 replikada 3 katı

**Belirti:** `RATE_LIMIT_PER_SEC=5000` yazıyor ama sistem 15 000 rps geçiriyor.
**Neden:** Token bucket her pod'un belleğinde (P01-05'in aynısı). 01'de bunu görmek için elle
ölçeklemek gerekiyordu; 02'de **zaten 3 replika var**, yani bu artık teorik bir uyarı değil,
üretimdeki mevcut durum. [Topic · Konu: Dağıtık durum, hız sınırlama]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P02-04` — limiti 40 rps'e çeker, 1 pod ve 3 pod ile aynı yükü verir

**Grafana:** `10 · Rate limit` → "allow by pod".
**Nerede çözülüyor:** 08 (Redis'te Lua ile atomik paylaşılan limiter). İroni şu: limitin amacı
**DB'yi** korumaktı; korunacak kaynak tek, koruma ise pod başına — yani tam korunması gereken yerde
replika sayısıyla gevşiyor.

---

### P02-05 · Index yok → seq scan

**Belirti:** `GET /api/links` küçük veride anında, 300 bin satırda saniyeler sürüyor.
**Neden:** `migrations/001` tenant üzerinde index oluşturmuyor (bilerek). `ORDER BY created_at DESC`
ile birlikte sorgu tüm tabloyu tarayıp sıralıyor. "Index unutmak" üretimde tam olarak böyle görünür:
küçük veride fark edilmez, büyük veride olay olur. [Topic · Konu: Index, sorgu planı]

**Reproduce (adım adım):**
1. `make repro P=P02-05` — `generate_series` ile 300 bin satır üretir, `EXPLAIN ANALYZE` planını basar
2. Plan `Seq Scan on links` gösterir; API çağrısının süresi ölçülür
3. **Çözüm:** `MIGRATE_TARGET=2` ile 002 migration'ını uygula, sonra scripti tekrar koş:
   ```bash
   kubectl -n lvl02 set env job/migrate MIGRATE_TARGET=2   # ya da deploy/migrate-job.yaml'ı düzenle
   kubectl -n lvl02 delete job migrate && make up
   ```

**Grafana:** `05 · Postgres` → "seq scan / idx scan", "DB query p99 by op" (`op=list`).
**Nerede çözülüyor:** Seviye içi (`migrations/002_tenant_index.sql`). İkinci ders orada:
`CREATE INDEX CONCURRENTLY` — düz `CREATE INDEX` tabloya ACCESS EXCLUSIVE kilidi koyar ve süre
boyunca **her yazmayı bloklar**; canlı tabloda bu bir kesintidir.

---

### P02-06 · Yavaş DB + sunucu tarafı timeout yok → havuz tıkanır

**Belirti:** Veritabanı yavaşladığında (ölmedi, sadece yavaşladı) uygulama p99'u patlar, in-flight
istek sayısı birikir, pod'lar hazır olmaktan çıkmaya başlar.
**Neden:** Client context'i 3 sn sonra vazgeçiyor ama `STATEMENT_TIMEOUT` boş olduğu için **Postgres
sorguyu çalıştırmaya devam ediyor**: bağlantı meşgul kalıyor, havuz doluyor, yeni istekler bekliyor.
**Vazgeçmek, işin durmasını sağlamaz — yalnızca beklemeyi bırakır.** [Topic · Konu: Timeout bütçesi, kaskad]

**Reproduce (adım adım):**
1. `cd platform && make chaos` (Chaos Mesh gerekli, bir kere)
2. `make repro P=P02-06` — Postgres'e 2 sn gecikme enjekte eder, havuz bekleme süresini ölçer
3. Elle karşılaştırma: `kubectl -n lvl02 set env deploy/linkly STATEMENT_TIMEOUT=2s` sonra tekrar koş

**Grafana:** `05 · Postgres` → "App pool: acquire wait p99", "empty acquire/s";
`11 · Resilience` → "in-flight by pod".
**Nerede çözülüyor:** Seviye içi (`STATEMENT_TIMEOUT`) + 10 (devre kesici, bulkhead, load shedding).
İki önlem gerekiyor ve biri diğerinin yerini tutmaz: timeout işi **durdurur**, devre kesici işi
**göndermeyi bırakır**.

---

### P02-07 · TRAP · Migration'ı her pod kendi açılışında koşarsa

**Belirti:** Tuzak açıkken rollout çırpınır: pod'lar şema kilidi için sıraya girer, en yavaş pod en
son hazır olur, bazen rollout timeout'a düşer.
**Neden:** Şema değişikliği **tek seferlik** bir iştir, uygulamanın açılış rutini değil. N replika
aynı anda migration koşarsa yarışırlar. Daha kötüsü: uygulamayı geri alırsan (rollback) **şema geri
gelmez**. [Topic · Konu: Şema göçü, dağıtım sırası]

**Reproduce (adım adım):**
1. `make repro P=P02-07` — `TRAP_MIGRATE_IN_MAIN=true` açar, tüm pod'ları aynı anda yeniden başlatır
2. Kaç pod'un "migration koşuluyor" dediğini sayar (olması gereken: sıfır — Job yaptı)

**Grafana:** `01 · Pods & Resources` → "Restart sayısı"; `02 · App RED` → 5xx.
**Düzeltme (varsayılan):** `deploy/migrate-job.yaml` — tek seferlik Job; uygulama yalnızca şemanın
hazır olmasını bekler (`cmd/linkly/main.go · waitForSchema`) ve hazır değilse **açılmayı reddeder**:
500 döndüren bir pod, Endpoints'e hiç girmeyen bir pod'dan kötüdür. Atomik olamayan değişiklikler
için expand/contract deseni 12'de.

---

### P02-08 · Sıcak link → satır kilidi kuyruğu

**Belirti:** Trafiğin çoğu tek bir linke gittiğinde redirect p99'u fırlar. Sistemin **en popüler**
linki, en **yavaş** linki olur.
**Neden:** Her redirect aynı satıra `UPDATE links SET clicks = clicks + 1` atıyor. Postgres satır
kilidi tek sıralıdır: eşzamanlı tıklamalar CPU'ya değil **kilit kuyruğuna** girer. Bu, 01'deki
mutex'in veritabanındaki hâli. Üstelik her `UPDATE` yeni bir satır sürümü yazar (MVCC) → ölü satır
birikir, autovacuum yetişmek zorunda kalır. [Topic · Konu: Satır kilidi, MVCC, okuma/yazma yolu]

**Reproduce (adım adım):**
1. `make repro P=P02-08` — önce dağıtık yük (`mixed`), sonra aynı yükün %90'ı tek linke (`hot-key`)
2. `increment_clicks` p99'u ile `get` p99'unu karşılaştırır; ölü satır sayısını okur

**Grafana:** `05 · Postgres` → "locks", "DB query p99 by op", "dead tuples".
**Nerede çözülüyor:** 05 (tıklamayı istek yolundan çıkar: bounded kuyruk + batch writer) ·
06 (dayanıklı olay akışı). Sayaç yazımının okuma yolundan çıkması bu merdivendeki en büyük
tek kazançlardan biri olacak.

---

### P02-09 · Sır düz metin: git'te, Secret'ta, env'de

**Belirti:** Veritabanı parolası repoda düz metin, Kubernetes Secret'ında base64, pod'un ortam
değişkenlerinde açık.
**Neden:** Kubernetes Secret'ı **şifrelemez**, yalnızca base64'ler; etcd at-rest şifrelemesi ayrı bir
ayardır ve varsayılan değildir. [Topic · Konu: Sır yönetimi]

**Reproduce (adım adım):**
1. `make repro P=P02-09` — dört yerden de okumayı dener: git, Secret, deployment env, RBAC
2. Ölçülen tur: `git: evet · kubectl get secret → base64 → 'linkly'`

**Grafana:** `14 · Security` (13'ten itibaren dolacak).
**Nerede çözülüyor:** 13 — sealed-secrets (git'te şifreli, yalnızca cluster çözer), etcd at-rest
şifreleme, NetworkPolicy (her pod DB'ye erişemesin), kısa ömürlü kimlik bilgisi.

---

### P02-10 · TRAP · Readiness'ın bağımlılığı kontrol etmesi

**Belirti:** Tuzak açıkken DB kısa bir süre kesildiğinde **tüm** pod'lar aynı anda Endpoints'ten
düşer; hazır endpoint sayısı **sıfıra** iner ve ingress'in yönlendirecek hiçbir hedefi kalmaz.
**Neden:** "Pod DB'ye ulaşamıyorsa trafik almasın" çok makul görünür ve yanlıştır: **kısmi** bir
arızayı **tam** kesintiye çevirir. Dahası DB geri geldiğinde bütün pod'lar aynı anda geri gelip onu
ikinci kez devirir. [Topic · Konu: Probe semantiği, kaskad]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P02-10` — `TRAP_READYZ_CHECKS_DB=true` açar, Postgres'i siler,
   hazır endpoint sayısını saniye saniye izler
2. **P02-03 ile karşılaştır:** aynı DB arızası, tuzak kapalıyken endpoint'ler 3'te kalıyordu

**Grafana:** `01 · Pods & Resources` → "hazır endpoint sayısı" (sıfıra iner); `02 · App RED` → 5xx.
**Düzeltme (varsayılan):** Readiness "**ben** hazır mıyım?" sorusudur. "Bağımlılığım iyi mi?"
sorusunun cevabı bir **metriktir**; buna verilecek tepki devre kesici ya da degrade moddur (10),
pod'u trafikten düşürmek değil. Birim test karşılığı: `TestReadyzIgnoresDatabaseByDefault`.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_MIGRATE_IN_MAIN` | Migration'ı her pod açılışta koşar | `make repro P=P02-07` | Bayrağı kapat; tek seferlik Job |
| `TRAP_READYZ_CHECKS_DB` | `/readyz` DB'ye ping atar | `CONFIRM=1 make repro P=P02-10` | Bayrağı kapat; readiness sadece kendi durumu |
| `TRAP_METRIC_LABEL_CODE` | (01'den devam) kısa kod label olur | `make repro P=P01-06` (01'de) | Tekil kimlik log/trace'e |
| `TRAP_LIVENESS_STRICT` | (01'den devam) sağlık uçları iş zincirinde | `make repro P=P01-07` (01'de) | Zincirin dışında tut |

Elle denemeye değer:
- `STATEMENT_TIMEOUT=2s` verip P02-06'yı tekrar koş — sunucu tarafı timeout'un farkını ölç.
- `MIGRATE_TARGET=2` ile index'i uygula, P02-05'i tekrar koş: `Seq Scan` → `Index Scan`.
- `DB_MAX_CONNS=5` yap ve `make load S=mixed` koş: havuz küçültmenin P02-02'yi çözmediğini,
  yalnızca kuyruğu uygulamaya taşıdığını gör (P02-06'nın belirtileri).
- `make load S=read-your-writes` — bu seviyede temiz geçer (tek DB). 09'da replikasyon gecikmesiyle
  bozulacak; şimdi koşup **temiz** sonucu kaydetmek, 09'daki farkı görmeni sağlar.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| `05 · Postgres` | **Dolu** ✨ | postgres_exporter + uygulamanın kendi `db_*` metrikleri |
| `02 · App RED` · `03 · App Business` | Dolu | 01'den beri |
| `01 · Pods & Resources` | Dolu | 4 pod (3 app + 1 DB) |
| `10 · Rate limit` | Dolu | Hâlâ süreç içi (P02-04) |
| `00 · Overview` · `15 · k6` | Dolu | — |
| `04 · Cache` | Boş | Önbellek yok (03) |
| `06 · Redis` · `07 · Analytics` · `08 · Stream` | Boş | O bileşenler yok |
| `09 · Autoscaling` | Boş | HPA yok (07) |
| `11 · Resilience` · `12 · SLO` · `13 · Rollout` | Boş | 10/11/12'de |
| `14 · Security` | Kısmen | `create_rejected_unsafe_total` dolu; kimlik yok (13) |

Yeni metrik ailesi: `db_queries_total{op,result}`, `db_query_duration_seconds{op}`,
`db_pool_acquire_duration_seconds`, `db_pool_empty_acquire_total`, `db_pool_{acquired,idle,total,max}_conns`.
**Sınırın iki tarafını da ölçüyoruz:** postgres_exporter veritabanının gördüğünü, uygulama
metrikleri isteğin gördüğünü söyler. İkisi farklı hikâyeler anlatabilir — P02-06 tam olarak o fark.

Not: `links_total` gauge'ı **kaldırıldı**. 01'de pod belleğindeki kayıt sayısıydı; artık anlamı yok
ve pod başına yanlış bir sayı üretirdi. Yanlış metriği silmek, yeni metrik eklemek kadar önemlidir.

## 9. Bilerek bırakılanlar

- **Postgres tek kopya**, operatör yok, yedek yok, PITR yok (P02-03 → 09).
- **`max_connections=100` varsayılanı** ve pod başına 25'lik havuz (P02-02 → 09).
- **`STATEMENT_TIMEOUT` boş** (P02-06 → seviye içi + 10).
- **Tenant index'i yok** — `migrations/002` var ama varsayılan olarak **uygulanmıyor** (P02-05).
- **Tıklama sayacı senkron ve istek yolunda** (P02-08 → 05).
- **Hız sınırı süreç içi** (P02-04 → 08).
- **Sırlar düz metin** (P02-09 → 13).
- **`X-Tenant-ID` kimlik değil** — silme/listeleme onunla sınırlı ama header'ı herkes gönderebilir (13).
- **Önbellek yok**: her okuma DB'ye (P02-01 → 03/04).

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 01 ile farkı gösterir. Sırayla şuna bak:

1. **`internal/store/`**: `memory.go` gitti, `store.go` (arayüz) + `postgres.go` + `fake.go` geldi.
   Arayüzün neredeyse hiç değişmemesi tesadüf değil: `CreateUnique`'in koşullu ekleme semantiği
   01'de SQL'in `ON CONFLICT DO NOTHING`'ine otursun diye seçilmişti. **Dar ve dürüst arayüzü erken
   seçmek, değişimi baştan yazmak yerine tek dosyalık bir işe çevirir.**
2. **`internal/httpapi/handlers.go`**: her handler artık `context` taşıyor ve `dbCtx` ile süre sınırı
   koyuyor. `handleRedirect`'teki iki satır (SELECT + UPDATE) bu seviyenin bütün sorunlarının kaynağı.
3. **`cmd/migrate/`** (yeni): şema değişikliği ayrı bir binary ve ayrı bir Job.
4. **`deploy/postgres.yaml`** (yeni): tek replikalı StatefulSet — operatörün *yokluğu* bilinçli.
5. **`deploy/deployment.yaml`**: `replicas: 3`, `topologySpreadConstraints`, `envFrom: secretRef`.
   PDB `minAvailable: 2` oldu: 01'de aynı nesne yanılsamaydı, değişen PDB değil **yedeklilik**.
6. **`internal/metrics/metrics.go`**: `links_total` silindi, havuz gauge'ları `GaugeFunc` olarak
   eklendi — güncellemeyi hatırlaman gereken bir gauge, bayat kalacak bir gauge'dır.
