# 06 — event-stream · "Olay akışı, ayrı tüketici"

## 1. Bu seviye ne?

Tıklama olayları süreç belleğinden çıkıp **dayanıklı bir loga** (Redpanda, Kafka API) yazılıyor;
onları **ayrı bir deployment** (`analytics-consumer`) okuyup veritabanına işliyor. 05'in iki büyük
açığı kapanıyor: sert ölümde kayıp (P05-01) ve yazıcının okuma yoluyla aynı süreci paylaşması
(P05-03). Karşılığında dağıtık sistemlerin asıl konusu geliyor: **teslimat garantisi**. Artık
en-az-bir-kez teslimat ve dolayısıyla **çift sayma** riski var — idempotency ile emiliyor.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress] --> A

  subgraph A["linkly × 3 (okuma yolu)"]
    P["producer<br/>acks=all · sınırlı tampon"]
  end

  A -->|"GET"| R[(redis)]
  A -.->|"MISS"| PG[("postgres")]
  P ==>|"clicks topic<br/>key = kısa kod"| K[("redpanda<br/>1 broker · 1 partition")]

  K ==>|"consumer group"| CN["analytics-consumer × 1<br/>yaz → sonra commit"]
  CN -->|"idempotent upsert"| PG
  CN -.->|"ayrıştırılamayan"| DLQ[("clicks-dlq")]
```

İki ayrı süreç, iki ayrı ölçeklenme kararı, iki ayrı arıza alanı. Redirect artık ne veritabanına
ne de broker'a **bağımlı**: ikisi de düşse yönlendirme çalışır, yalnızca analitik durur.

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P05-01 | At-most-once: sert ölümde tampon kaybolur | Olay, `acks=all` ile dayanıklı loga yazılıyor; tüketici çökse de kayıt topic'te duruyor ve yeniden teslim ediliyor |
| P05-03 | Yazıcı okumayla aynı süreç/havuzu paylaşıyor | `cmd/analytics-consumer` ayrı binary, ayrı Deployment, ayrı CPU limiti, ayrı `pgxpool` (10 bağlantı) |

**P05-02 (kuyruk düşürme) listede yok** ve bu bilinçli: sorun kaybolmadı, **bir kat aşağı taşındı**.
Kafka istemcisi de asenkron ve varsayılan olarak sınırsız tamponlar; broker düşerse kayıtlar bellekte
birikir. Bu yüzden producer'da kendi sınırımızı tutup düşürüyoruz (P06-05). *Her asenkron sınırın
bir üst sınırı ve bir düşürme politikası olmalı — katman değişse de kural değişmiyor.*

## 4. Ayağa kaldırma

Platform bir kere kurulur (`cd platform && make minimal`). Sonra bu klasörde:

```bash
make up            # build → push → deploy → rollout wait → smoke
curl -s -XPOST http://lvl06.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'
curl -I http://lvl06.localtest.me/<code>
make grafana       # Ladder klasörü, level=lvl06
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make down
```

Akışa bakmak için:
```bash
RP=$(kubectl -n lvl06 get pod -l app.kubernetes.io/name=redpanda -o name)
kubectl -n lvl06 exec -it $RP -- rpk topic describe clicks
kubectl -n lvl06 exec -it $RP -- rpk group describe analytics      # lag burada
kubectl -n lvl06 exec -it $RP -- rpk topic consume clicks-dlq -n 5 # ölü mektuplar
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). Dışarıdan davranış değişikliği yok.

`/stats` hâlâ `X-Stats-Freshness: eventual` diyor — ama artık "eventual" farklı bir şey demek:
05'te *kaybolabilir*di, 06'da **kaybolmaz, sadece gecikir**. Aynı başlık, güçlenmiş bir garanti.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P06-01 | En az bir kez → tekrar teslim (çift sayma riski) | `CONFIRM=1 make repro P=P06-01` | Stream → records by result | seviye içi (idempotency) |
| P06-02 | Tüketici gecikmesi: analitik bayatlıyor | `make repro P=P06-02` | Stream → consumer lag | 07 (KEDA) |
| P06-03 | Tek partition = tek tüketici tavanı | `CONFIRM=1 make repro P=P06-03` | Stream → lag by partition | seviye içi (repartition) |
| P06-04 | Poison message boru hattını rehin alır | `make repro P=P06-04` | Stream → dlq | seviye içi (DLQ) |
| P06-05 | Broker düşünce tampon dolar | `CONFIRM=1 make repro P=P06-05` | Stream → producer buffer & drops | seviye içi · 14 |
| P06-06 | **TRAP** commit noktası = teslimat garantisi | `CONFIRM=1 make repro P=P06-06` | Stream → duplicate | seçim meselesi |
| P06-07 | Şema evrimi: bilinmeyen sürüm | `make repro P=P06-07` | Stream → unknown_version | seviye içi · 14 (registry) |

---

### P06-01 · En az bir kez teslimat → tekrar teslim → idempotency

**Belirti:** Tüketici parti yazıp commit edemeden ölürse aynı olaylar tekrar gelir.
`consumer_records_total{result="duplicate"}` artar, **tıklama sayısı artmaz**.
**Neden:** Commit noktası yazmadan **sonra**. Aradaki her ölüm yeniden teslimle sonuçlanır — bu bir
hata değil, seçilmiş garantinin ta kendisi. Çift saymayı `processed_events` tablosu engelliyor:
`INSERT … ON CONFLICT DO NOTHING RETURNING` ile hangi olayın gerçekten *iddia edildiği* belirleniyor.
[Topic · Konu: En az bir kez, idempotency, atomiklik]

**Reproduce (adım adım):** `CONFIRM=1 make repro P=P06-01` — tüketiciyi **önce durdurup** 2000
tıklamalık bir birikim yaratır, sonra açıp birikimi işlerken üç kez öldürür, son sayımı ve
`duplicate` sayacını gösterir.

**Ölçüm dersi:** İlk hâlde tıklamalar üretilirken tüketici de çalışıyordu; olayları anında işleyip
commit ettiği için öldürdüğümüzde ortada **commit edilmemiş parti kalmıyordu**. Deney, ölçmek
istediği durumu hiç oluşturmadan "tekrar teslim gözlenmedi" diyordu. *Bir yarışı ölçmek istiyorsan
önce o yarışın oluşacağı koşulu kurmak zorundasın.*

**Grafana:** `08 · Stream` → "consumer records by result"; `07 · Analytics` → tıklama farkı.
**Kritik ayrıntı:** İddia ve sayım **aynı transaction'da** commit ediliyor. Aralarında bir çökme,
tam da engellemeye çalıştığımız çift sayımı yeniden yaratırdı.
**Bedeli:** Saklama penceresi boyunca tıklama başına bir satır. *"Tam bir kez etki"nin fiyatı budur;
bedava bir garanti yoktur.*

---

### P06-02 · Tüketici gecikmesi: veri kaybolmuyor, bayatlıyor

**Belirti:** Tüketici durduğunda `/stats` eski değeri göstermeye devam eder; geri açıldığında
birikmiş olaylar işlenir ve sayı yakalar.
**Neden:** Log dayanıklı; tüketici yalnızca **nerede kaldığını** (offset) takip ediyor.
[Topic · Konu: Lag, dayanıklı log]

**Reproduce (adım adım):** `make repro P=P06-02` — tüketiciyi `replicas=0` yapar, 2000 tıklama
üretir (paralel), bayatlığı ölçer, geri açıp yakalama süresini ölçer.

**Grafana:** `08 · Stream` → "consumer lag by partition", "produced vs consumed vs written".
**Nerede çözülüyor:** 07 — KEDA lag'i **ölçekleme sinyali** yapacak. Ama dikkat: tek partition varsa
tüketici artırmak işe yaramaz (P06-03). Lag bir hata değil bir **ölçüdür**; eşiği bir ürün kararıdır.
**05 ile fark:** Aynı senaryo 05'te kalıcı kayıptı. Şimdi yalnızca gecikme.

---

### P06-03 · Tek partition = tek tüketici tavanı

**Belirti:** Tüketiciyi 3 replikaya çıkarıyorsun, işleme hızı değişmiyor; iki pod boşta oturuyor.
**Neden:** Kafka'da paralelliğin üst sınırı **partition sayısıdır**: bir partition'ı aynı grupta
yalnızca bir tüketici okuyabilir. [Topic · Konu: Partition, paralellik tavanı]

**Reproduce (adım adım):** `CONFIRM=1 make repro P=P06-03` — 1 ve 3 replika ile işleme hızını ve
gerçekten iş yapan pod sayısını karşılaştırır.

**Grafana:** `08 · Stream` → "consumer lag by partition", "consumer commit/s & pods".
**Çözüm:** `rpk topic add-partitions clicks -n 6`.
**Bedeli:** Partition **başına** sıra garantisi vardır, global sıra yoktur. Anahtarı kısa kod seçmemiz
bu yüzden: aynı linkin olayları aynı partition'a düşer ve sırası korunur. Aynı seçim P06-05'te
sıcak bir linkin tek partition'a yüklenmesi demek — *aynı madalyonun iki yüzü.*

---

### P06-04 · Poison message boru hattını rehin alır

**Belirti:** Ayrıştırılamayan tek bir mesaj, DLQ olmadan **arkasındaki her şeyi** durdurur:
offset ilerlemez, lag sınırsız büyür.
**Neden:** Tüketici işleyemediği mesajda sadece hata verirse, aynı mesaj sonsuza kadar yeniden
teslim edilir. [Topic · Konu: Poison message, DLQ]

**Reproduce (adım adım):** `make repro P=P06-04` — topic'e bozuk JSON basar, ardından geçerli
tıklamalar üretir ve **arkadakilerin işlenip işlenmediğini** ölçer.

**Grafana:** `08 · Stream` → "consumer records by result" (`dlq`), "consumer lag by partition".
**Kural:** Bir tüketici, işleyemediği mesaj için bir **çıkış yolu** tanımlamak zorundadır —
atla+say, DLQ'ya taşı ya da bilinçli olarak dur. *"Tanımlamamak" da bir seçimdir: sonsuza kadar dene.*

---

### P06-05 · Broker düşünce: bloklamak mı düşürmek mi?

**Belirti:** Redpanda tamamen durdurulduğunda **redirect çalışmaya devam eder** (5xx yok);
producer tamponu dolar ve sınırı aşan kayıtlar düşürülür.
**Neden:** `Record()` bloklamıyor ve tampon **sınırlı**. Bloklasaydı bir broker kesintisi doğrudan
bir site kesintisi olurdu; sınırsız tamponlasaydık (kütüphanenin varsayılanı!) bellek dolar, pod
OOM olur ve yine site çökerdi. [Topic · Konu: Bağımlılık izolasyonu, back pressure]

**Reproduce (adım adım):** `CONFIRM=1 make repro P=P06-05` — broker'ı `replicas=0` yapar, aynı yükü
verir, p99 / 5xx / tampon / düşürme / bellek ölçer.

**Grafana:** `08 · Stream` → "producer buffer & drops"; `02 · App RED` → p99.
**Nerede çözülüyor:** Kısmen seviye içi (sınır + düşürme), tam çözüm 14 (3 broker + replikasyon).
*Bir broker kesintisi analitiği bozabilir, redirect'i asla.*

---

### P06-06 · TRAP · Commit noktası teslimat garantisidir

**Belirti:** `TRAP_COMMIT_BEFORE_WRITE=true` ile tüketici öldüğünde tıklamalar **eksik** kalır;
varsayılan modda **eksilmez** (tekrarlar idempotency ile yutulur).
**Neden:** İki seçenek var ve üçüncüsü yok:

| Sıra | Sonuç | Riski |
|---|---|---|
| yaz → commit *(varsayılan)* | en az bir kez | tekrar teslim → çift sayma (idempotency ile emilir) |
| commit → yaz *(TRAP)* | en fazla bir kez | yazma başarısız olursa **veri kaybı** |

[Topic · Konu: Teslimat garantisi, commit noktası]

**Reproduce (adım adım):** `CONFIRM=1 make repro P=P06-06` — her iki modda da önce birikim yaratır
(tüketici kapalı), sonra tüketiciyi işleme sırasında öldürüp son sayımları karşılaştırır.

**Grafana:** `08 · Stream` → "consumer records by result" (`duplicate`).
**Ders:** *Mühendislik, hangi hatayı yaşayacağını seçmektir.* "Tam bir kez teslimat" bir pazarlama
terimidir; gerçekte olan **en-az-bir-kez + idempotent yazma**dır. Ayrıca otomatik commit'in neden
kapalı olduğu da bu tabloda: zamanlayıcıyla commit, garantiyi sessizce ikinci satıra çevirir.

---

### P06-07 · Şema evrimi: bilinmeyen sürüm geldiğinde

**Belirti:** `v:99` bir olay geldiğinde tüketici **çökmüyor**, olayı atlayıp sayıyor ve akış devam ediyor.
**Neden:** Üretici ve tüketici ayrı dağıtılır; bir an gelir ikisi farklı sürümdedir. Tüketici
bilmediği sürümde patlarsa, üreticinin tek satırlık değişikliği tüm analitiği durdurur.
[Topic · Konu: Şema evrimi, geriye/ileriye uyumluluk]

**Reproduce (adım adım):** `make repro P=P06-07` — topic'e `v:99` bir olay basar, ardından normal
tıklamalar üretir, `unknown_version` sayacını ve akışın devam edip etmediğini ölçer.

**Grafana:** `08 · Stream` → "consumer records by result" (`unknown_version`).
**Üç kural:**
1. Tüketici bilmediği **alanları** yok saymalı, bilmediği **sürümü** görünür biçimde atlamalı.
2. Alan **eklemek** uyumludur; alan **silmek** ve alanın **anlamını değiştirmek** değildir.
3. Üreticiyi yeni sürüme geçirmeden **önce** tüketicileri hazırla — sıra önemlidir.

Daha güçlü çözüm: şema kayıt defteri + uyumluluk kuralları (14'te opsiyonel).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_COMMIT_BEFORE_WRITE` | Offset'i yazmadan önce commit eder | `CONFIRM=1 make repro P=P06-06` | Bayrağı kapat (yaz → commit) |
| `TRAP_NO_DLQ` | Bozuk mesajı DLQ'ya taşımaz | `make repro P=P06-04` | Bayrağı kapat |
| `TRAP_REDIRECT_301` | (05'ten devam) | `make repro P=P05-06` (05'te) | — |

Elle denemeye değer:
- `rpk topic add-partitions clicks -n 6` sonra P06-03'ü tekrar koş: tavan kalkar, tüketici
  çoğaltmak **artık** işe yarar. Ölçekleme bazen kodda değil, **topolojide**dir.
- `kubectl -n lvl06 exec $RP -- rpk group describe analytics` ile lag'i canlı izle; aynı anda
  `make load S=hot-key` koş. Sıcak anahtarın tek partition'a yüklendiğini gör (anahtar seçiminin bedeli).
- `PRODUCER_MAX_BUFFERED=100` yap ve broker'ı durdur: düşürme anında başlar. Tampon boyutu
  "ne kadar kesintiye dayanmalıyım" sorusunun cevabıdır.
- `processed_events` tablosunun büyümesini izle: `SELECT count(*) FROM processed_events`.
  İdempotency'nin faturası bu tablodur ve temizlenmesi gerekir (09'da partition + retention).

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| `08 · Stream` | **Dolu** ✨ | produce rate, tampon, consumer lag, commit, duplicate, DLQ |
| `07 · Analytics` | Kısmen | `analytics_*` metrikleri **kayboldu** (kuyruk artık yok); yerine `consumer_*` geldi |
| `05 · Postgres` | Dolu | `op=write_clicks_idem` yeni |
| `04 · Cache` · `06 · Redis` · `02 · App RED` · `03 · App Business` | Dolu | — |
| `09 · Autoscaling` | Boş | HPA/KEDA yok (07) |
| `11 · Resilience` · `12 · SLO` · `13 · Rollout` | Boş | — |

Yeni ve en önemli panel: **"produced vs consumed vs written"**. Üç çizgi üst üste binmeli.
Ayrışıyorlarsa: produced > consumed → lag (P06-02) · consumed > written → yazma hatası ·
written > produced → **çift sayma** (idempotency bozulmuş).

## 9. Bilerek bırakılanlar

- **Tek broker, replikasyon faktörü 1** — broker kaybı = topic kaybı (P06-05 → 14).
- **Tek partition** — tüketici paralellik tavanı 1 (P06-03 → seviye içi egzersiz, 07'de gerekli olacak).
- **Tüketici otomatik ölçeklenmiyor** — lag büyüse de replika sabit (P06-02 → 07, KEDA).
- **`processed_events` temizlenmiyor** — sonsuza kadar büyür. Retention/partition 09'da.
- **Şema kayıt defteri yok** — sözleşme kodda, `Version` alanıyla (P06-07 → 14 opsiyonel).
- **DLQ tüketilmiyor** — mesajlar oraya gidiyor ama kimse okumuyor; incelemek elle.
- **05'ten devreden**: stats önbelleklenmiyor, kiracı kontrolü yok, tek Redis, tek Postgres.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 05 ile farkı gösterir:

1. **`internal/analytics/` SİLİNDİ**, yerine **`internal/stream/`** geldi. Ama `ClickRecorder`
   arayüzü değişmedi — `handlers.go`'daki `a.clicks.Record(code)` satırı **aynı**. 05'te "dar arayüz,
   ucuz değişim" demiştik; faturası burada kesiliyor: süreç içi kuyruk yerine Kafka producer'ı
   koymak, istek yolunda **tek satır bile** değiştirmedi.
2. **`cmd/analytics-consumer/`** (yeni): ayrı binary, kendi `/metrics` ve `/healthz`'i ile.
   *Gözlemlenemeyen bir arka plan süreci, sessizce durduğunda kimsenin fark etmediği süreçtir.*
3. **`internal/store/migrations/004_event_dedup.sql`**: `processed_events`. Bir tablonun tek işi
   "bunu daha önce yaptım mı?" sorusuna cevap vermek olabilir — ve bu, dağıtık bir sistemde
   doğruluğun temelidir.
4. **`WriteClicksIdempotent`**: `ON CONFLICT DO NOTHING RETURNING` + transaction. Bütün garanti
   tek bir SQL ifadesinde yaşıyor.
5. **`deploy/consumer.yaml`** (yeni): `DB_MAX_CONNS=10` — tüketicinin **kendi** havuzu. P05-03'ün
   çözümü bir kod değişikliği değil, bir **süreç sınırı**.
6. **`deploy/redpanda.yaml`**: `default_topic_partitions=1` ve tek broker — ikisi de bilerek yanlış,
   ikisi de bir sorunun kaynağı (P06-03, P06-05).
