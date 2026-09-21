# 05 — async-analytics · "Yazmayı okuma yolundan çıkar"

## 1. Bu seviye ne?

Tıklama sayacı redirect'in içinden çıktı. Artık her yönlendirme, sınırlı bir süreç içi kuyruğa bir
olay bırakıp dönüyor; ayrı bir goroutine olayları **toplayıp** toplu olarak `clicks_daily` tablosuna
yazıyor. P02-08'deki sıcak satır kilidi ortadan kalkıyor. Karşılığında bir **teslimat garantisi**
ödüyoruz: bu kuyruk **en fazla bir kez**. Dolu kuyruk tıklama düşürür, sert ölüm tampondakini
kaybeder. Sayaçlar için doğru, faturalama için yanlış — ve bunu açıkça söylüyoruz.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress] --> A

  subgraph A["linkly pod (× 3)"]
    direction TB
    H["redirect handler<br/>Record() — bloklamaz"]
    Q["bounded channel<br/>20 000 olay"]
    W["batch writer<br/>500 olay / 1 sn"]
    H -->|"non-blocking send"| Q --> W
  end

  A -->|"GET (cache-aside)"| R[(redis)]
  W -->|"tek UPSERT / parti"| PG[("postgres<br/>clicks_daily")]
  A -.->|"yalnızca MISS"| PG
```

Okuma yolu artık DB'ye **hiç yazmıyor**. Yazıcı geri kalsa bile kullanıcı beklemiyor — bu tasarımın
tek vaadi ve `TestRecordNeverBlocks` onu bir testle sabitliyor.

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P02-08 | Sıcak link → satır kilidi kuyruğu | Yazma istek yolundan çıktı; üstelik **toplanıyor**: aynı koda gelen 1000 tıklama tek satır güncellemesi oluyor. Anahtar ne kadar sıcaksa toplama oranı o kadar iyi — yani eski tasarımın en kötü durumu, yeni tasarımın en iyi durumu. |

Tek madde, ama etkisi büyük: `links.clicks` sütunu emekliye ayrıldı, yerine `clicks_daily`
`(code, day)` toplama tablosu geldi (`migrations/003`).

## 4. Ayağa kaldırma

Platform bir kere kurulur (`cd platform && make minimal`). Sonra bu klasörde:

```bash
make up            # build → push → deploy → rollout wait → smoke
curl -s -XPOST http://lvl05.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'
curl -I http://lvl05.localtest.me/<code>
make grafana       # Ladder klasörü, level=lvl05
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyede yeni: **`GET /api/links/{code}/stats`** → `{"code","clicks","by_day":[…]}`.
Yanıt `X-Stats-Freshness: eventual` başlığı taşır — sayı **bayat olabilir**, kuyruk henüz
boşalmadıysa son saniyelerin tıklamaları görünmez. *Bir API'nin verdiği garantiyi söylemek,
garantinin kendisi kadar önemlidir.*

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P05-01 | At-most-once: sert ölümde tampon kaybolur | `CONFIRM=1 make repro P=P05-01` | Analytics → events by result | 06 |
| P05-02 | Kuyruk dolunca düşürme (ve sınırsızın daha kötü olması) | `make repro P=P05-02` | Analytics → queue depth, dropped | 06 · 07 |
| P05-03 | Yazıcı, okumayla aynı süreç ve havuzu paylaşıyor | `make repro P=P05-03` | Postgres → acquire wait | 06 · 07 |
| P05-04 | Toplama ölçeklenir, ayrıntı ölçeklenmez | `make repro P=P05-04` | Analytics → stats p99 | 09 (partition) |
| P05-05 | Kısa grace → drain yarıda kalır | `CONFIRM=1 make repro P=P05-05` | Analytics → written | seviye içi |
| P05-06 | **TRAP** 301 → sayılamayan tıklama | `make repro P=P05-06` | App Business → redirect ok/s | seviye içi |

---

### P05-01 · At-most-once: sert ölümde tampondaki tıklamalar kaybolur

**Belirti:** Pod `--force` ile öldürüldüğünde son saniyelerin tıklamaları hiç yazılmaz. Graceful
kapanışta (rollout) kayıp olmaz.
**Neden:** Kuyruk **süreç belleğinde**. Graceful kapanışta `Stop()` kuyruğu boşaltır; SIGKILL'de
boşaltacak kimse kalmaz. [Topic · Konu: Teslimat garantisi, dayanıklılık]

**Reproduce (adım adım):**
1. `CONFIRM=1 make repro P=P05-01` — flush aralığını 15 sn'ye açar (tampon görünür olsun), bilinen
   sayıda tıklama üretir, önce `--force` ile öldürür, sonra aynı senaryoyu `rollout restart` ile
   tekrarlar ve iki kaybı karşılaştırır

**Ölçüm notu:** Kaybedebileceğin şey, o an **tamponda olandır**. Varsayılan `ANALYTICS_FLUSH_INTERVAL=1s`
ile tampon en fazla 1 saniyelik tıklama tutar; yavaş üreten bir döngüyle öldürdüğünde tamponu çoğu
zaman boş yakalarsın ve deney "kayıp yok" der. Bu, tasarımın güvenli olduğunu değil **ölçümün şanslı**
olduğunu gösterir. Pencereyi bilerek açmak, olayı görünür kılmanın meşru yoludur — yeter ki neyi
değiştirdiğini söyleyesin.

**Grafana:** `07 · Analytics` → "events by result", "k6 tıklama − DB tıklama" farkı.
**Nerede çözülüyor:** 06 — olay süreç belleğinden çıkıp **dayanıklı bir loga** yazılacak
(en az bir kez) ve tüketici idempotent olacak. Orada yeni sorun **çift sayma** olacak:
*garanti seçmek, sorun seçmektir.*

---

### P05-02 · Kuyruk dolunca düşürme — ve alternatifinin neden daha kötü olduğu

**Belirti:** Yazıcı yavaşladığında `analytics_events_total{result="dropped"}` tırmanır. Redirect
gecikmesi **etkilenmez**.
**Neden:** Sınırlı kuyruk dolduğunda `Record()` düşürür ve sayar. Bu kasıtlı: bloklayan bir gönderim
redirect'i yine DB'ye bağlardı — görünmez biçimde, yalnızca yük altında.
[Topic · Konu: Back pressure, bounded queue]

**Reproduce (adım adım):**
1. `make repro P=P05-02` — kuyruğu 500'e küçültür, **önce ısıtır**, sonra Postgres'e 2 sn gecikme
   enjekte eder ve yük verir
2. Alternatifi gör: `kubectl -n lvl05 set env deploy/linkly TRAP_UNBOUNDED_QUEUE=true` → düşürme
   sıfırlanır, working set tırmanır, sonunda **OOMKilled** ve tampondaki her şey gider

**Grafana:** `07 · Analytics` → "events by result", "queue depth by pod"; `02 · App RED` → p99.
**Ölçüm dersi — deneyin SIRASI da bir değişkendir:** İlk hâlde gecikme yükten önce enjekte
ediliyordu; k6'nın `setup()` aşaması 100 link oluşturuyor ve her INSERT 2 sn sürdüğü için setup
zaman aşımına uğrayıp yük hiç koşmuyordu. Script "düşürme olmadı" dedi — ölçtüğü şey kuyruk değil,
kendi kurulum sırasıydı. Bir deney kurarken *hazırlık* adımlarının da arızadan etkilendiğini unutma.

**Ders:** *Gördüğün bir düşüş bir karardır; göremediğin bir bloklama, trafiği bekleyen bir
kesintidir.* Sınırsız kuyruk bir emniyet ağı değil, **ertelenmiş bir çöküştür** — "hiç düşürmeyelim"
isteği sonunda her şeyi düşürmekle biter.

---

### P05-03 · Yazıcı, okumayla aynı süreci ve havuzu paylaşıyor

**Belirti:** Yoğun tıklama trafiğinde redirect p99'u ve havuz bekleme süresi yükselir.
**Neden:** Yazma istek yolundan çıktı ama **süreçten** çıkmadı: aynı pod CPU'su, aynı `pgxpool`,
aynı veritabanı. İzolasyon kısmi. [Topic · Konu: Kaynak izolasyonu, bulkhead]

**Reproduce (adım adım):** `make repro P=P05-03` — yalnız-okuma tabanı ile yoğun tıklama altındaki
p99'u ve havuz bekleme süresini karşılaştırır.

**Grafana:** `07 · Analytics` → "batch write latency p99"; `05 · Postgres` → "App pool: acquire wait p99".
**Nerede çözülüyor:** 06 + 07 — tüketici ayrı bir **süreç** ve ayrı bir deployment olacak: kendi
havuzu, kendi CPU limiti, kendi ölçeklenmesi. *İzolasyon bir arayüz meselesi değil, bir süreç meselesidir.*

---

### P05-04 · Toplama ölçeklenir, ayrıntı ölçeklenmez

**Belirti:** `clicks_daily` 2 milyon tıklamayı tek satırda tutar ve `stats` anında döner. Ayrıntı
tablosu kursaydık aynı cevap için 2 milyon satır taranırdı.
**Neden:** Toplama, veriyi **yazarken** küçültür; ayrıntı **okurken** büyür.
[Topic · Konu: Toplama vs ayrıntı, yazma amplifikasyonu]

**Reproduce (adım adım):** `make repro P=P05-04` — geçici bir `clicks_detail` tablosu kurup 2 M satır
üretir, iki sorgunun planını ve süresini karşılaştırır, sonra tabloyu düşürür.

**Grafana:** `07 · Analytics` → "stats endpoint p99"; `05 · Postgres` → "DB query p99 by op" (`op=stats`).
**Nerede çözülüyor:** Ayrıntı gerçekten gerekiyorsa 09 (RANGE partition by day + eski partition'ları
düşürme). **Ama asıl karar ürün kararıdır:** ayrıntıyı ancak birileri cevapladığı soruyu
adlandırabiliyorsa sakla. Ayrıntıyı sonradan eklemek, toplamayı sonradan eklemekten ucuzdur —
tersi değil (veri zaten yazılmıştır).

---

### P05-05 · Kısa `terminationGracePeriodSeconds` → drain yarıda kalır

**Belirti:** Grace süresi kısaltıldığında rollout başına kaybedilen tıklama sayısı artar.
**Neden:** Drain kodu doğru olabilir; kubelet süreci bitirmesine izin vermezse hiçbir anlamı yok.
[Topic · Konu: Kapatma bütçesi]

**Reproduce (adım adım):** `CONFIRM=1 make repro P=P05-05` — mevcut ayarla ve `grace=3s` (+`preStop=1s`) ile
kaybı ölçüp karşılaştırır.

**Grafana:** `07 · Analytics` → "events by result" (`written`); `01 · Pods` → "Son sonlanma nedeni".
**Kural:** `terminationGracePeriodSeconds` > (preStop beklemesi + `SHUTDOWN_GRACE` + drain süresi).
Bu üç sayı birbirini tanımıyorsa, hangisinin kazandığını kubelet'in SIGKILL'i belirler.
*"Kod doğru" ile "sistem doğru" aynı şey değildir — aradaki fark bir YAML satırı.*

---

### P05-06 · TRAP · 301 tarayıcı önbelleği, sayılamayan tıklama üretir

**Belirti:** Tarayıcıda aynı linki beş kez açıyorsun, `stats` bir tıklama gösteriyor.
**Neden:** 301 kalıcı yönlendirmedir; tarayıcı sonraki istekleri **sunucuya hiç göndermez**.
01'de bu hatayı "önbellek kontrolü sende değil" diye çözmüştük (P00-10) — **aynı hata, farklı
seviyede farklı zarar**: artık tıklamaları ciddi ciddi sayıyoruz ve sayamıyoruz.
[Topic · Konu: HTTP önbellekleme, ölçüm bütünlüğü]

**Reproduce (adım adım):**
1. `make repro P=P05-06` — 302 modunda sayımı ölçer, sonra tuzağı açıp başlıkları karşılaştırır
2. **Elle (asıl ikna edici olan):** Chrome'da linki 5 kez aç → `stats`'a bak → 1 tıklama

**Grafana:** `03 · App Business` → "redirect ok/s" gerçek tıklamanın altında kalır.
**Zarar zinciri:** 301 → tarayıcı önbelleği → sunucuya ulaşmayan istek → sayılamayan tıklama →
yanlış analitik → yanlış iş kararı. *Düzeltilmiş bir hatanın geri gelmesi, ilk hâlinden pahalıya patlar.*

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_UNBOUNDED_QUEUE` | Kuyruğu sınırsız yapar (düşürme yerine büyüme) | `make repro P=P05-02` | Bayrağı kapat |
| `TRAP_REDIRECT_301` | 302 yerine 301 döner | `make repro P=P05-06` | Bayrağı kapat |
| `TRAP_DEBUG_KEYS` · `TRAP_NO_TTL_JITTER` · `TRAP_UPDATE_DELAY_MS` | (04'ten devam) | 04'te | — |

Elle denemeye değer:
- `ANALYTICS_FLUSH_INTERVAL=30s` yap: stats tazeliği 30 saniyeye çıkar. **Tazelik ile yazma yükü
  arasındaki düğme budur** — ve bu düğmeyi çevirmek bir ürün kararıdır, bir ayar değil.
- `ANALYTICS_BATCH_SIZE=1` yap: toplama kapanır, `write_clicks` sorgu sayısı tıklama sayısına eşitlenir.
  02'nin davranışına geri dönersin — ama en azından okuma yolunun dışında.
- `make load S=hot-key` ile `make load S=redirect` altında `analytics_batch_size` histogramını
  karşılaştır: sıcak anahtar toplamanın en iyi çalıştığı durumdur.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| `07 · Analytics` | **Dolu** ✨ | enqueued/dropped/written, kuyruk derinliği, batch süresi/boyutu |
| `05 · Postgres` | Dolu | `op=write_clicks` ve `op=stats` yeni; `increment_clicks` **kayboldu** |
| `04 · Cache` · `06 · Redis` · `02 · App RED` · `03 · App Business` | Dolu | — |
| `08 · Stream` · `09 · Autoscaling` | Boş | — |
| `11 · Resilience` · `12 · SLO` · `13 · Rollout` | Boş | — |

En öğretici panel: **"k6 tıklama − DB tıklama" farkı**. İdeal durumda sıfır olmalı; sıfır değilse
ya düşürme olmuştur (P05-02) ya kayıp (P05-01) ya da kuyruk henüz boşalmamıştır. Üçünü ayırt etmek
için `dropped` ve `queue depth` panellerine birlikte bakılır.

## 9. Bilerek bırakılanlar

- **At-most-once teslimat** — sert ölümde kayıp (P05-01 → 06).
- **Kuyruk süreç belleğinde**, pod başına (P05-01, P05-03 → 06/07).
- **Tüketici ayrı süreç değil**: aynı CPU, aynı havuz, aynı DB (P05-03 → 07).
- **Ayrıntı tablosu yok**, yalnızca günlük toplam (P05-04 → 09 gerekirse).
- **`WriteClicks` idempotent değil**: yeniden deneme çift sayar. 05'te yeniden deneme yok, o yüzden
  sorun çıkmıyor; 06'da en-az-bir-kez gelince bu bir sorun **olacak** ve orada çözülecek.
- **Stats önbelleklenmiyor** ve kiracı kontrolü yok — `/stats` herkese açık (13).
- **04'ten devreden her şey**: tek Redis, tek Postgres, düz metin sırlar, süreç içi hız limiti.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 04 ile farkı gösterir:

1. **`internal/analytics/analytics.go`** (yeni): `Record()`'un `select`/`default` bloğu bu seviyenin
   tamamı. Üç satır: gönderebilirsen gönder, gönderemezsen **düşür ve say**. Bloklamayan gönderim
   ile bloklayan gönderim arasındaki fark, kodda bir `default:` satırı; üretimde bir kesinti.
2. **`internal/httpapi/handlers.go`**: `IncrementClicks(ctx, code)` → `a.clicks.Record(code)`.
   Bir DB çağrısı bir kanal gönderimine dönüştü; `ctx` bile gerekmiyor çünkü beklemiyor.
3. **`internal/store/migrations/003_clicks.sql`**: `clicks_daily(code, day)`. `links.clicks`
   sütunu duruyor ama artık yazılmıyor — **kullanılmayan bir sütun, bir sonraki okuyucunun tuzağıdır**;
   12'de expand/contract ile nasıl düşürüleceği anlatılacak.
4. **`cmd/linkly/main.go`**: kapatma sırasına yeni bir adım girdi — `clicks.Stop()` sunucudan **sonra**.
   Önce boşaltmak, bir parti yazıp sonra kimsenin boşaltmadığı yeni tıklamalar kabul etmek olurdu.
5. **`deploy/deployment.yaml`**: `terminationGracePeriodSeconds: 40 → 60`. Yeni bir kapatma adımı
   eklediğinde kapatma bütçesini de büyütmen gerekir (P05-05 bunu ölçüyor).
6. **`internal/httpapi/server.go`**: `ClickRecorder` arayüzü tek metotlu. 06'da bu arayüzün arkasına
   bir Kafka producer'ı koymak tek satırlık bir iş olacak — **dar arayüz, ucuz değişim**.
