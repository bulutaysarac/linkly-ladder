# 06 — event-stream · "Olay akışı, ayrı tüketici"

> **Bu seviyede ne yaşayacaksın?**
> - Pod sert ölse de tıklamaların kaybolmaması (olaylar dayanıklı logda) ve yazıcının ayrı bir servise taşınması — P05-01 ve P05-03 kapanır
> - En-az-bir-kez teslimatın tekrar teslim üretmesi ve idempotency ile emilmesi (P06-01)
> - Tüketici durunca verinin kaybolmayıp bayatlaması — lag (P06-02); tek partition'ın tek tüketici tavanı (P06-03)
> - Tuzaklar: zehirli bir mesajın DLQ olmadan bütün hattı rehin alması (P06-04); commit noktasının teslimat garantisini belirlemesi (P06-06)
> - Broker ölünce bloklamak mı düşürmek mi (P06-05); bilinmeyen bir şema sürümü geldiğinde tüketicinin çökmeden devam etmesi (P06-07)
>
> **Bu seviye olmasa ne olur?** Sert bir ölüm tampondaki tıklamaları siler ve yazıcı redirect ile aynı süreci, aynı bağlantı havuzunu paylaşır.
>
> **Yeni gelen teknolojiler:** Redpanda (Kafka API), franz-go, tüketici grubu, DLQ, `08 · Stream (Redpanda)` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

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
Kafka istemcisi de asenkron, ama tamponu dolunca (franz-go'da varsayılan 10.000 kayıt) `Produce`
çağıranı **bekletir** — yani redirect isteğini; broker düşerse kayıtlar önce bellekte birikir, sonra
istek yolu takılır. Bu yüzden producer'da sınırı biz koyuyoruz, aşanı düşürüyoruz ve kaydı hiç
beklemeyen `TryProduce` ile ekliyoruz (P06-05). *Her asenkron sınırın bir üst sınırı ve bir düşürme
politikası olmalı — katman değişse de kural değişmiyor.*

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl06.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl06.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl06 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P06-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
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
| P06-01 | En az bir kez → tekrar teslim (çift sayma riski) | `CONFIRM=1 make repro P=P06-01` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) → "Tüketici gecikmesi (bölüme göre)" | seviye içi (idempotency) |
| P06-02 | Tüketici gecikmesi: analitik bayatlıyor | `make repro P=P06-02` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) → "Tüketici gecikmesi (bölüme göre)" | 07 (KEDA) |
| P06-03 | Tek partition = tek tüketici tavanı | `CONFIRM=1 make repro P=P06-03` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) → "Onaylama / sn ve tüketici pod sayısı" | seviye içi (repartition) |
| P06-04 | **TRAP** Poison message boru hattını rehin alır | `make repro P=P06-04` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) → "Tüketilen kayıtlar (sonuca göre)" | seviye içi (DLQ) |
| P06-05 | Broker düşünce tampon dolar | `CONFIRM=1 make repro P=P06-05` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl06&from=now-15m&to=now&refresh=10s) → "Üretici tamponu ve atılanlar" | seviye içi · 14 |
| P06-06 | **TRAP** commit noktası = teslimat garantisi | `CONFIRM=1 make repro P=P06-06` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-30m&to=now&refresh=10s) → "Tüketici gecikmesi (bölüme göre)" | seçim meselesi |
| P06-07 | Şema evrimi: bilinmeyen sürüm | `make repro P=P06-07` | [08 · Stream (Redpanda)](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) · [01 · Pods & Resources](http://grafana.localtest.me/d/ladder-pods?var-level=lvl06&from=now-15m&to=now&refresh=10s) → "Tüketilen kayıtlar (sonuca göre)" | seviye içi (şema kaydı kapsam dışı) |

---

### P06-01 · En az bir kez teslimat → tekrar teslim → idempotency

**Belirti:** Tüketici parti yazıp commit edemeden ölürse aynı olaylar tekrar gelir.
`consumer_records_total{result="duplicate"}` artar, **tıklama sayısı artmaz**.
**Neden:** Commit noktası yazmadan **sonra**. Aradaki her ölüm yeniden teslimle sonuçlanır — bu bir
hata değil, seçilmiş garantinin ta kendisi. Çift saymayı `processed_events` tablosu engelliyor:
`INSERT … ON CONFLICT DO NOTHING RETURNING` ile hangi olayın gerçekten *iddia edildiği* belirleniyor.
[Topic · Konu: En az bir kez, idempotency, atomiklik]

**Reproduce (adım adım):** `CONFIRM=1 make repro P=P06-01`
  1. Tüketicide `TRAP_COMMIT_DELAY_MS=30000` açılır: yazma ile offset commit'i arasına 30 sn (§7).
  2. Tüketici **durdurulur**, 2000 tıklamalık birikim topic'te bekler.
  3. Tüketici açılır; ilk parti veritabanında görünür görünmez (tıklama sayısı artmaya başladığı an)
     pod öldürülür — offset'i henüz commit edilmemiştir (script pod'un commit sayacını da basar: 0).
  4. Yeni pod, sert öldürülen üyenin oturumu dolunca (~45 sn) partition'ı alır ve aynı partiyi
     **yeniden** okur. Hüküm yeni pod'un kendi sayacına dayanır: `duplicate > 0` **ve** sayım tam N.

**Ölçüm dersi:** Tekrar teslim kendiliğinden görünmez. Tıklamalar üretilirken tüketici de
çalışıyorsa ortada commit edilmemiş parti kalmaz. Birikim kurulsa bile tüketiciyi açıldıktan sabit
bir süre (ör. 35 sn) sonra öldürmek pencereyi kaçırır: 2000 kayıt tek poll'da okunup tek
transaction'da yazılır ve hemen commit edilir — partition'ı aldıktan sonra bir saniyeden kısa
sürede. Öldürme geldiğinde birikim çoktan yazılmış **ve** commit edilmiştir, tekrar teslim olamaz;
`sayım == N` hükmü yine de geçer, çünkü hiç öldürülmemiş sağlıklı bir tüketici de tam N sayar.
*Bir yarışı ölçmek istiyorsan önce penceresini kurmalı, sonra ona denk geldiğini kanıtlamalısın.*
`TRAP_COMMIT_DELAY_MS` yaz → commit sırasını değiştirmez; her en-az-bir-kez tüketicide var olan
boşluğu bilerek vurulabilecek kadar açık tutar.

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; deney ~4 dk sürer (giriş: admin / ladder)
- "Tüketici gecikmesi (bölüme göre)" → tüketici kapalıyken `bölüm 0` üretilen tıklama kadar (≈2000) yükselir ve yatay kalır. İlk pod birikimi yazdığı hâlde commit etmeden öldüğü için **inmez**; ancak yeni pod partiyi yeniden işleyip 30 sn sonra commit edince 0'a düşer.
- "Onaylama / sn ve tüketici pod sayısı" → `tüketici pod` önce 0'a iner (birikim kuruluyor), sonra 1'e döner; ilk pod hiç commit etmeden öldüğü için `onaylama / sn` ancak yeni pod'la belirir.
- "Tüketilen kayıtlar (sonuca göre)" → yeni pod devraldıktan sonra bir `duplicate` tepesi: aynı olaylar ikinci kez geldi ve idempotency onları saymadı. İlk pod'un `ok`'u çoğu zaman görünmez — yazar yazmaz öldürüldü, kazınmaya vakit kalmadı; script bu yüzden sayaçları Prometheus'tan değil doğrudan pod'dan okur.
- "Üretilen ve tüketilen olaylar (toplam)" → `üretilen` birikim sırasında N kadar sıçrar; `tüketilen` (yalnızca `ok`) N'in **üstüne çıkmaz**: tekrar teslim edilenler çift sayılmadı. İlk pod'un sayacı kaybolduğu için altında da kalabilir; kesin sayım scriptin veritabanından okuduğu sayıdır.
- `07 · Analytics` → tıklama farkı paneli bu deneyde boş kalır: tıklamalar k6 ile değil `curl` ile üretiliyor ve `analytics_*` metriği yok.

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

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; tüketici ~2 dk kapalı kalır (giriş: admin / ladder)
- "Tüketici gecikmesi (bölüme göre)" → tüketici durunca `bölüm 0` üretilen tıklama kadar (≈2000) yükselir ve 120 sn boyunca **yatay** kalır: kimse müdahale etmedikçe kendiliğinden inmez. Script tüketiciyi elle açınca 0'a düşer.
- "Onaylama / sn ve tüketici pod sayısı" → `tüketici pod` 0'da, `onaylama / sn` yok: lag büyürken tüketiciyi geri getiren bir şey yok (07'de KEDA bu çizgiyi lag'e göre yükseltecek).
- "Üretilen ve tüketilen olaylar (toplam)" → `üretilen` yükselir, `tüketilen` yatay kalır; aradaki açıklık lag'in kendisidir. Tüketici açılınca `tüketilen` yetişir: veri kaybolmadı, yalnızca bekledi.

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

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; iki yük fazı var: önce 1, sonra 3 tüketici (giriş: admin / ladder)
- "Onaylama / sn ve tüketici pod sayısı" → `tüketici pod` 1'den 3'e çıkar ama `onaylama / sn` iki fazda da aynı tepeye çıkar: pod sayısı üç katına çıktı, iş hızı değişmedi.
- "Tüketici gecikmesi (bölüme göre)" → tek çizgi (`bölüm 0`), çünkü tek partition var; iki fazda da yük sırasında yükselir ve benzer sürede erir.
- Explore'da: `sum by (pod) (rate(consumer_records_total{namespace="lvl06",result="ok"}[1m]))` → 3 replikalı fazda üç `analytics-…` pod'undan yalnızca **biri** sıfırdan büyük; diğer ikisi partition alamadığı için 0'da düz.

**Çözüm:** `rpk topic add-partitions clicks -n 6`.
**Bedeli:** Partition **başına** sıra garantisi vardır, global sıra yoktur. Anahtarı kısa kod seçmemiz
bu yüzden: aynı linkin olayları aynı partition'a düşer ve sırası korunur. Aynı seçim P06-05'te
sıcak bir linkin tek partition'a yüklenmesi demek — *aynı madalyonun iki yüzü.*

---

### P06-04 · TRAP · Poison message boru hattını rehin alır

**Belirti:** Ayrıştırılamayan tek bir mesaj, DLQ olmadan **arkasındaki her şeyi** durdurur:
offset ilerlemez, lag sınırsız büyür.
**Neden:** Tüketici işleyemediği mesajda sadece hata verirse, aynı mesaj sonsuza kadar yeniden
teslim edilir. [Topic · Konu: Poison message, DLQ]

**Reproduce (adım adım):** `make repro P=P06-04` — iki faz, aynı bozuk kayıt:
  1. `TRAP_NO_DLQ=true` (§7): önce 20 geçerli tıklamanın işlendiği doğrulanır (tüketici sağlam).
     Sonra topic'e, tıklamalarla aynı partition'a düşecek biçimde 3 bozuk JSON ve **arkasından**
     200 geçerli tıklama basılır. 30 sn sonra: kaçı işlendi, grup gecikmesi (`rpk group describe`)
     ne, tüketici aynı kaydı yeniden deniyor mu?
  2. Tuzak kapatılır (DLQ açık): yeni tüketici aynı bozuk kaydı `clicks-dlq`'ya taşır ve bekleyen
     200 tıklamayı işler.
  Hüküm: 1. fazda 0/200, 2. fazda 200/200 işlenirse REPRODUCED. Tuzak açıkken tıklamalar yine
  işlendiyse iddia yanlıştır (NOT-REPRODUCED).

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) — scripti başlattıktan ~1 dk sonra aç; iki faz ~4 dk sürer (giriş: admin / ladder)
- "Tüketilen kayıtlar (sonuca göre)" → tuzak fazında `ok` sıfıra iner ve yerine sabit hızda bir `error` serisi akar (~3/sn): **aynı** 3 bozuk kayıt her saniye yeniden deneniyor, arkasındaki 200 tıklamanın hiçbiri işlenmiyor. DLQ fazında `dlq`'da küçük bir tepe, hemen ardından bekleyen tıklamaların `ok` tepesi.
- "Tüketici gecikmesi (bölüme göre)" → tuzak fazında `bölüm 0` ~200'e çıkar ve orada kalır — üretim sürseydi büyümeye devam ederdi: offset ilerlemiyor. DLQ açılınca 0'a iner.
- "Onaylama / sn ve tüketici pod sayısı" → tuzak fazında `tüketici pod` 1, `onaylama / sn` 0: süreç ayakta, `/healthz` 200 dönüyor, ama hiçbir şey commit edilmiyor.
- "Ölü mektup kutusuna giden / sn" → yalnızca ikinci fazda küçük bir tepe (3 kayıt, bir dakikaya yayılır).

**Kural:** Bir tüketici, işleyemediği mesaj için bir **çıkış yolu** tanımlamak zorundadır —
atla+say, DLQ'ya taşı ya da bilinçli olarak dur. *"Tanımlamamak" da bir seçimdir: sonsuza kadar dene.*
Takılan tüketicinin sağlık ucu "iyiyim" der: *süreç ayakta* ile *iş ilerliyor* aynı şey değildir —
ilerlemenin ölçüsü lag'dir.

---

### P06-05 · Broker düşünce: bloklamak mı düşürmek mi?

**Belirti:** Redpanda tamamen durdurulduğunda **redirect çalışmaya devam eder** (5xx yok);
producer tamponu dolar ve sınırı aşan kayıtlar düşürülür.
**Neden:** `Record()` bloklamıyor ve tampon **sınırlı**. Bloklasaydı bir broker kesintisi doğrudan
bir site kesintisi olurdu — ve kütüphanenin varsayılanı tam olarak bu: franz-go'nun tamponu 10.000
kayıtta dolar ve `Produce` çağıranı bekletir. Sınırsız tamponlasaydık bellek dolar, pod OOM olur ve
yine site çökerdi. Bu yüzden geçerli sınır uygulamanınki (`PRODUCER_MAX_BUFFERED`), istemcininki onun
üstünde yalnızca bir güvenlik ağı, ve kayıt beklemeyen `TryProduce` ile ekleniyor. 10.000'de
bloklamanın birim testi: `internal/stream/producer_test.go`.
[Topic · Konu: Bağımlılık izolasyonu, back pressure]

**Reproduce (adım adım):** `CONFIRM=1 make repro P=P06-05` — tampon sınırını deney boyunca 500'e
indirir (`BUF_TEST`; varsayılan 50.000 kısa bir kesintide hiç dolmaz, düşürme yolu sınanmaz),
broker'ı `replicas=0` yapar, aynı yükü verir, p99 / 5xx / tampon / düşürme / bellek ölçer. Hüküm:
broker yokken hata oranı %1'in altında **ve** düşürülen kayıt > 0.

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl06&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl06&from=now-15m&to=now&refresh=10s) — iki yük fazı var: broker ayakta, sonra broker kapalı (giriş: admin / ladder)
- "Üretici tamponu ve atılanlar" → broker kapanınca "tamponda: linkly-…" çizgileri yükselir ve sınıra (deneyde 500) dayanır; aynı anda "atılan / sn" çizgisi belirir: sınırı aşan kayıtlar bekletilmiyor, düşürülüyor. Broker geri gelince tampon 0'a iner. (Varsayılan 50.000'lik sınırla kısa bir kesintide "atılan" 0 kalır.)
- "Üretilen kayıt / sn" → broker kapalıyken 0'a düşer: tıklama olayları broker'a ulaşmıyor.
- "Broker ayakta mı" → çizgi 0'a inmez, **kesilir**: pod yok, kazınacak hedef de yok. Aynı sebeple "Tüketici gecikmesi (bölüme göre)" de bu arada boştur — lag'i broker'ın kendisi raporluyor.
- "Sunucu hatası oranı (5xx)" (App RED) → iki fazda da 0 civarında: redirect broker'ı beklemiyor.
- "Gecikme (p50 / p95 / p99)" (App RED) → iki fazı karşılaştır; broker kapalıyken de benzer kalmalı. Belirgin bir sıçrama, `Record()`'un istek yolunu bloklamaya başladığı anlamına gelir.
- "Bellek kullanımı" (Pods) → `linkly-…` pod'larının belleği tamponla biraz artar ama limit çizgisinin altında kalır.

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

Varsayılan sırada yazma **başarısız** olursa tüketici aynı partiyi yerinde, geri çekilerek yeniden
dener ve o partinin ötesini okumaz (`internal/stream/consumer.go · writeBatch`): offset commit'i o
ana kadar okunan **her şeyi** kapsar, yani başarısız partiyi atlayıp devam eden bir tüketici sonraki
sağlam partiyle onu da commit eder ve o tıklamalar bir daha gelmez. TRAP sırasında offset yazmadan
önce commit edildiği için korunacak bir şey kalmaz: tek deneme, başarısızlık kayıptır.

**Reproduce (adım adım):** `CONFIRM=1 make repro P=P06-06`
  1. Tüketicide `TRAP_COMMIT_DELAY_MS=30000` açılır: iki adımın arasına 30 sn (§7). Sıra değişmez.
  2. Her fazda tüketici **durdurulur**, 2000 tıklamalık birikim topic'te bekler, sonra tüketici açılır.
  3. **Varsayılan faz:** ilk parti veritabanında görünür görünmez pod öldürülür (o an commit sayacı 0:
     "yazıldı, commit edilmedi"). Yeni pod partiyi yeniden okur; idempotency tekrarı yutar.
  4. **TRAP fazı** (`TRAP_COMMIT_BEFORE_WRITE=true`): pod'un commit sayacı artar artmaz, parti
     veritabanına yazılmadan öldürülür ("commit edildi, yazılmadı"). Yeni pod commit edilmiş
     offset'ten devam eder; o parti bir daha gelmez.
  5. Sayım, broker'daki grup gecikmesi 0'a inip tıklama sayısı durulunca okunur. Hüküm iki gözleme
     dayanır: varsayılan faz **tam** N, TRAP fazı N'in **altında**. Öldürme aralığa denk gelmediyse
     (öldürme anındaki commit/yazma sayıları tutmuyorsa) script hüküm vermez, `exit 2` ile çıkar.

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-30m&to=now&refresh=10s) — iki faz var (varsayılan, sonra TRAP), her biri ~3 dk; 30 dk'lık pencere ikisini de kapsar (giriş: admin / ladder)
- "Tüketici gecikmesi (bölüme göre)" → iki tepe, her faz için bir tane: tüketici kapalıyken birikimle (`N`, varsayılan 2000) yükselir. Varsayılan fazda ilk pod yazdığı hâlde commit etmeden öldüğü için tepe **inmez**, yeni pod partiyi yeniden işleyip 30 sn sonra commit edince 0'a düşer. TRAP fazında tepe ilk pod'un commit'iyle hemen 0'a iner — ama o tıklamalar hiç yazılmadı.
- "Tüketilen kayıtlar (sonuca göre)" → varsayılan fazda yeni pod devraldıktan sonra bir `duplicate` tepesi (tekrar teslim geldi, idempotency yuttu); TRAP fazında `duplicate` görünmez — offset yazmadan önce commit edildiği için tekrar teslim yok.
- "Üretilen ve tüketilen olaylar (toplam)" → TRAP fazında `tüketilen`, `üretilen`in altında kalır: commit edilip yazılamayan kayıtlar bir daha gelmez. Öldürülen pod'ların sayaçları kazınamadan kaybolabilir; kesin karşılaştırma scriptin veritabanından okuduğu sayımdır.

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

**Grafana'da gör:** [`08 · Stream (Redpanda)`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now&refresh=10s) ve [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl06&from=now-15m&to=now&refresh=10s) — scripti başlattıktan ~1 dk sonra aç (giriş: admin / ladder)
- "Tüketilen kayıtlar (sonuca göre)" → `unknown_version` serisinde çok küçük bir tepe (tek kayıt, bir dakikaya yayılır); `ok` kesilmeden devam eder: tüketici v99'u atladı, akış durmadı.
- "Ölü mektup kutusuna giden / sn" → 0 kalır: v99 bozuk değil, geçerli JSON — bu bir poison message (P06-04) değil.
- "Yeniden başlatma sayısı" (Pods) → `analytics-…` pod'unun çizgisi yatay kalır: tüketici çökmedi.

**Üç kural:**
1. Tüketici bilmediği **alanları** yok saymalı, bilmediği **sürümü** görünür biçimde atlamalı.
2. Alan **eklemek** uyumludur; alan **silmek** ve alanın **anlamını değiştirmek** değildir.
3. Üreticiyi yeni sürüme geçirmeden **önce** tüketicileri hazırla — sıra önemlidir.

Daha güçlü çözüm: şema kayıt defteri + uyumluluk kuralları (14'te opsiyonel).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_COMMIT_BEFORE_WRITE` | Offset'i yazmadan önce commit eder | `CONFIRM=1 make repro P=P06-06` | Bayrağı kapat (yaz → commit) |
| `TRAP_NO_DLQ` | Bozuk mesaj için çıkış yolu yok: tüketici aynı kaydı sonsuza kadar yeniden dener, offset ilerlemez, lag büyür | `make repro P=P06-04` | Bayrağı kapat (DLQ) |
| `TRAP_COMMIT_DELAY_MS` | Yazma ile offset commit'i arasına bekleme koyar: varsayılan sırada "yazıldı, commit edilmedi", `TRAP_COMMIT_BEFORE_WRITE` ile "commit edildi, yazılmadı" penceresini açar (garantiyi değiştirmez) | `CONFIRM=1 make repro P=P06-01` · `P06-06` | Bayrağı kapat |
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
| [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl06&from=now-15m&to=now) | **Dolu** ✨ | produce rate, tampon, consumer lag, commit, duplicate, DLQ |
| [`07 · Analytics`](http://grafana.localtest.me/d/ladder-analytics?var-level=lvl06&from=now-15m&to=now) | Kısmen | `analytics_*` metrikleri **kayboldu** (kuyruk artık yok); yerine `consumer_*` geldi |
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl06&from=now-15m&to=now) | Dolu | `op=write_clicks_idem` yeni |
| [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl06&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl06&from=now-15m&to=now) · [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl06&from=now-15m&to=now) · [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl06&from=now-15m&to=now) | Dolu | — |
| [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl06&from=now-15m&to=now) | Boş | HPA/KEDA yok (07) |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl06&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl06&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl06&from=now-15m&to=now) | Boş | — |

Yeni ve en önemli panel: **"Üretilen ve tüketilen olaylar (toplam)"**. İki çizgi (`üretilen`,
`tüketilen`) üst üste binmeli. `tüketilen` yalnızca veritabanına **ilk kez** yazılan olayları sayar
(`result="ok"`); tekrar teslim edilenler `duplicate` olarak ayrı sayılır ve bu çizgiye girmez.
Ayrışıyorlarsa: üretilen > tüketilen → lag (P06-02) ya da yazma hatası (hangisi olduğunu "Tüketilen
kayıtlar (sonuca göre)"deki `error` söyler) · tüketilen > üretilen → **çift sayma** (idempotency bozulmuş).

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
