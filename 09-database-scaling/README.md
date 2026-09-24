# 09 — database-scaling · "Veritabanı darboğazı"

> **Bu seviyede ne yaşayacaksın?**
> - Postgres'in operatörle yönetilmesi: primary + 1 replika, otomatik failover, önünde PgBouncer; okumalar replikaya, yazmalar primary'ye
> - Yeni yazılan linkin replikada henüz olmaması — read-your-writes ihlali (P09-01)
> - Primary ölünce failover penceresi (P09-02); tuzak: transaction pooling'de prepared statement (P09-03)
> - Replikadaki uzun okumanın WAL ile çakışması (P09-04); partition'sız silmenin pahalılığı (P09-05); replikasyonun yedek olmadığı — silinen satır replikadan da saniyeler içinde gider (P09-06)
>
> **Bu seviye olmasa ne olur?** Tek Postgres tek arıza noktasıdır (P02-03) ve bağlantı sayısı replika × havuz ile duvara çarpar (P02-02).
>
> **Yeni gelen teknolojiler:** CloudNativePG, PgBouncer (Pooler), okuma/yazma ayrımı, tablo partition'ı ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Postgres artık bir operatörle yönetiliyor: **primary + 1 replika**, otomatik failover, önünde
**PgBouncer** (Pooler) ve arkasında partition'lı bir saklama politikası. Uygulama okumayı
replikalara, yazmayı primary'ye gönderiyor. 02'nin iki büyük açığı kapanıyor (bağlantı duvarı ve
tek nokta arıza) — ve yerine **ancak replikan olduğunda sahip olabileceğin** sorunlar geliyor:
replikasyon gecikmesi, read-your-writes, failover penceresi, havuzlama tuzakları.

## 2. Mimari

```mermaid
flowchart LR
  APP["redirect-svc / api-svc / consumer"] -->|yazma| PRW["pg-pooler-rw<br/>PgBouncer · transaction"]
  APP -->|okuma| PRO["pg-pooler-ro<br/>PgBouncer · transaction"]
  PRW --> P[("pg-1 · PRIMARY")]
  PRO --> R1[("pg-2 · replika")]
  P -.->|streaming WAL| R1
  P -.->|failover: terfi| R1
```

Çoğullama oranı 25:1 — 500 uygulama bağlantısı, 20 gerçek arka uç bağlantısı. `max_connections`
**bilerek 100'de bırakıldı**: Pooler'ın neden gerektiğini aynı sayıyla görmek için. Küme iki
instance'lık (`instances: 2`): failover (P09-02) ve replika çakışması (P09-04) tek replikayla
ölçülür; üçüncü kopya yalnızca daha fazla yedeklilik getirir ve bu kümenin belleğine sığmaz
(gerekçe `deploy/cnpg.yaml`'da).

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P02-02 | Havuz taşması: replika × pool > max_connections | PgBouncer transaction pooling: uygulama tarafı bol (500), DB tarafı az (20). Replika sayısı artık `max_connections`'ı ilgilendirmiyor |
| P02-03 | DB tek nokta, failover yok | CNPG `Cluster{instances: 2}` + otomatik terfi. Kesinti **sıfırlanmadı**, süresi ve insan müdahalesi ortadan kalktı (P09-02 pencereyi ölçüyor) |

Ayrıca P07-02 (ölçeklemenin darboğazı DB'ye taşıması) büyük ölçüde kapandı: redirect artık 20
bağlantılık havuzla çalışabiliyor çünkü gerçek DB bağlantısı Pooler'da sabit.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl09.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl09.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl09 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P09-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

Kümeye bakmak için:
```bash
kubectl -n lvl09 get cluster,pooler,pods -l cnpg.io/cluster=pg
kubectl -n lvl09 get pods -l cnpg.io/cluster=pg -L cnpg.io/instanceRole   # kim primary?
```

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Önceki seviye açıksa kapat (aynı anda tek seviye çalışır), bu seviyeyi kur. `make up` Grafana'yı da temizler;
   CNPG kümesi (primary + replika) ve Pooler'lar hazır olmadan döner:
```bash
make -C ../08-rate-limiting down
make up
```
2. 08'in sorunlarını bu seviyede koş (08'in altı scripti sırayla). Koşarken başka komut çalıştırma: aynı pod'lara
   dokunurlar. 09'un kapattığı sorunlar (P02-02, P02-03, bkz. §3) 08'in scriptleri arasında değil, bu yüzden
   `BEKLENEN` sütununda `NOT-REPRODUCED` isteyen satır yok; `CONFIRM=1` isteyen P08-01 `SKIPPED` görünür:
```bash
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P09-01 → P09-06). Her sorunda aynı düzen:
   **Elle** bloklarını sırayla yapıştır (ilk komut `make fresh`: Grafana bu deneye boş başlar) →
   **Terminalde ne görmelisin** ile karşılaştır → **Grafana'da gör** linklerini aç, her madde hangi panelde neyi
   göreceğini söyler. İstersen aynı deneyi `make repro P=…` ile otomatik koş: ölçer ve hükmünü basar.
   P09-01 replikada WAL uygulamasını duraklatır, P09-02 primary'yi siler: ikisinde de son adımı atlama.
4. Bitince açık kalan ayarları geri al ve seviyeyi kapat:
```bash
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md). Dışarıdan değişiklik yok.

**Ama garanti değişti**: `GET /{code}` artık bir replikadan cevaplanabilir, yani **birkaç yüz
milisaniye geçmişten** okuyor olabilir. Yazma sonrası `STICKY_WINDOW` (2 sn) boyunca okumalar
primary'ye yapışır — bu, read-your-writes'ı yaygın durumda korur (işaret Redis'te: oluşturma
api-svc'de, okuma redirect-svc'de olsa da görünür).

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P09-01 | Read-your-writes ihlali | `make repro P=P09-01` | [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl09&from=now-15m&to=now&refresh=10s) · [15 · k6](http://grafana.localtest.me/d/ladder-k6?var-level=lvl09&from=now-15m&to=now&refresh=10s) → "Read-your-writes ihlali" | seviye içi (sticky) |
| P09-02 | Failover penceresi anlık değil | `CONFIRM=1 make repro P=P09-02` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl09&from=now-15m&to=now&refresh=10s) → "Replikasyon gecikmesi" | 10 (retry+idempotency) |
| P09-03 | **TRAP** prepared statement + transaction pooling | `make repro P=P09-03` | [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl09&from=now-15m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl09&from=now-15m&to=now&refresh=10s) → "Yönlendirme sonuçları" | seviye içi |
| P09-04 | Replikada uzun okuma ↔ WAL çakışması | `make repro P=P09-04` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) → Explore ↓ | pazarlık (feedback) |
| P09-05 | Silme pahalı: partition'sız retention | `make repro P=P09-05` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) → "Veritabanı CPU" | seviye içi (partition) |
| P09-06 | Replikasyon yedek değildir | `CONFIRM=1 make repro P=P09-06` | [05 · Postgres](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) → "Replikasyon gecikmesi" | kapsam dışı (14 §9, yolun devamı) |

---

### P09-01 · Read-your-writes ihlali

**Belirti:** Kullanıcı link oluşturur, hemen tıklar ve **kendi yarattığı link için 404** alır.
**Neden:** Replika, primary'nin *daha önceki bir ana* ait kopyasıdır. Oraya gönderilen her okuma
geçmişten bir okumadır. [Topic · Konu: Replikasyon gecikmesi, tutarlılık]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P09-01` — `read-your-writes` senaryosunu (oluştur → hemen oku) iki kez
koşar: önce yapışkan okuma açık ve replika güncel; sonra yapışkan okuma kapalı ve replikada **WAL
uygulaması duraklatılmış** (`pg_wal_replay_pause()`, script sonunda ne olursa olsun devam ettirir).
WAL gelmeye devam eder ama uygulanmaz: replika gerçekten geçmişte kalır ve her saniye bir saniye
daha geride olur.

Elle — `09-database-scaling` klasöründe, sırayla yapıştır. 3. adım replikada WAL uygulamasını duraklatır;
duraklatılmış bir replika sonraki her deneyi bozar, 5. adımı (devam ettirme) atlama:

1. Grafana'yı temizle, CNPG pod'larının hazır olmasını bekle, replikayı bul, WAL uygulaması duraklatılmış mı bak:
```bash
make fresh
kubectl -n lvl09 wait --for=condition=Ready pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole --timeout=180s
kubectl -n lvl09 get pods -l cnpg.io/cluster=pg -L cnpg.io/instanceRole
replica=$(kubectl -n lvl09 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}'); echo "replika: $replica"
kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT pg_is_wal_replay_paused()'
```
2. Yapışkan okuma açık (varsayılan), replika güncel: 30 sn "oluştur → hemen oku", sonra sunucunun saydığı ihlali oku:
```bash
make load S=read-your-writes K6_ARGS="--vus 10 --duration 30s"
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(ryw_violations_total{namespace="lvl09"}[1m]))' | jq -r '"ihlal (sunucu): " + .data.result[0].value[1]'
```
3. Yapışkan okumayı redirect ve api'de kapat (pod'lar yeniden başlar), replikada WAL uygulamasını duraklat:
```bash
make set E="TRAP_NO_STICKY=true" W=redirect
make set E="TRAP_NO_STICKY=true" W=api
sleep 10
kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT pg_wal_replay_pause()'
kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT pg_is_wal_replay_paused()'
```
4. Aynı yükü ver, ihlali oku, replikanın ne kadar geride kaldığına bak:
```bash
make load S=read-your-writes K6_ARGS="--vus 10 --duration 30s"
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(ryw_violations_total{namespace="lvl09"}[1m]))' | jq -r '"ihlal (sunucu): " + .data.result[0].value[1]'
kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT round(EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp()))'
```
5. Geri al — önce WAL uygulamasını devam ettir, sonra yapışkan okumayı aç:
```bash
kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT pg_wal_replay_resume()'
kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT pg_is_wal_replay_paused()'
make reset
```

**Terminalde ne görmelisin:** 1. adımda `pg_is_wal_replay_paused` → `f`. 2. adımda k6 özet satırının
(`k6 lvl09: … 404=…`) altındaki `ryw_violations=0` ve `ihlal (sunucu): 0`: yazma sonrası okumalar primary'ye yapıştı.
3. adımda duraklatma sonrası `t`. 4. adımda `404=` ve `ryw_violations=` sıfırdan büyüktür, `ihlal (sunucu)` da:
kullanıcı kendi az önce yarattığı link için 404 aldı. Son komut replikanın son uygulanan işlemden kaç saniye geride
olduğunu basar — duraklatmadan beri geçen süre kadar (onlarca saniye). 5. adımda yeniden `f`. Not: bu 404'ler
önbelleğe negatif kayıt olarak da yazılır; replika yetişse bile o linkler `CACHE_NEGATIVE_TTL` boyunca 404 dönebilir.

**Grafana'da gör:** [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl09&from=now-15m&to=now&refresh=10s), [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl09&from=now-15m&to=now&refresh=10s) ve [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; iki faz 30'ar sn, arada rollout (giriş: admin / ladder)
- "Read-your-writes ihlali" → birinci fazda (yapışkan okuma açık) **0'da düz**; ikinci fazda sıfırdan ayrılıp yükselir. Bu sayaç sunucu tarafında, okuma replikaya gidip az önce yazılan kodu **bulamadığında** (404) artar — replikanın hata vermesi ya da zaman aşımı ihlal sayılmaz.
- "Senaryoya özel ölçüler" (k6) → `read-your-writes ihlali` aynı anda basamak yapar: istemcinin gözünden aynı olay — kendi yarattığı link için 404.
- "Dönen durum kodları" (k6) → ikinci fazda `302`'lerin yerini `404` alır; bkz. [Grafana'yı okumak](../README.md#grafanayı-okumak).
- "Replikasyon gecikmesi" → replika pod'unun çizgisi birinci fazda 0; duraklatma boyunca **doğrusal tırmanır** (alınan ama uygulanmayan WAL) ve devam ettirilince 0'a düşer. CNPG metrikleri 30 sn'de bir kazındığı için tırmanış bir-iki noktadan ibarettir; script duraklatmanın sonundaki gecikmeyi doğrudan replikadan okuyup basar.
- Explore'da: `sum(rate(db_reads_routed_total{namespace="lvl09"}[1m])) by (target)` → birinci fazda okumaların bir kısmı `primary`'ye yapışır; ikinci fazda hepsi `replica`'ya gider.

**Neden `replica-delay` chaos'u değil?** `platform/chaos/replica-delay.yaml` replikanın
**gönderdiği** paketleri geciktirir, aldığı WAL'i değil. Sonuç bayat değil **yavaş** bir replikadır:
sorgu cevapları ~3 sn geç gelir (3 sn'lik sorgu timeout'unda `503`), WAL onayları geç gittiği için
primary'nin gözünden gecikme ~3 sn görünür (`cnpg_pg_stat_replication_replay_lag_seconds`), ama
replikanın kendi gecikmesi ("Replikasyon gecikmesi" paneli) ~0 kalır ve kimse 404 almaz. Sunucu
sayacı zaman aşımlarını da ihlal saydığı için bu chaos'la deney, tek bir 404 olmadan "ihlal arttı"
derdi. *Yavaş replika ile bayat replika farklı arızalardır; birini ölçüp diğerini raporlama.*

**Çözümler ve bedelleri:**

| Yaklaşım | Bedeli |
|---|---|
| Yapışkan okuma *(uygulanmış)* | Yazma sonrası N sn okuma ölçeklenmesinden ödün; işaret Redis'te, iki servis de görür — Redis yoksa korunmaz |
| Senkron replikasyon | Yazma gecikmesi en yavaş replikaya bağlanır |
| LSN takibi | En doğru, en karmaşık: client yazmanın LSN'ini taşır |
| Yeni kaydı önbelleğe yaz | Ucuz ama yalnızca önbellek isabetinde — 03'te bunu **bilerek** yapmamıştık |

*"Eventual consistency" bir kullanıcıya yapılabilecek en kötü savunmadır: 404 gördüğü an sistem
onun için bozuktur.*

---

### P09-02 · Failover penceresi

**Belirti:** Primary öldürüldüğünde ~10–30 saniye yazma yapılamaz, sonra sistem kendini toparlar.
**Neden:** Terfi anlık değildir: WAL uygulaması, rol ilanı, istemcilerin yeni adrese yönlenmesi.
[Topic · Konu: HA, failover, SLO]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `CONFIRM=1 make repro P=P09-02` (yük altında primary'yi siler, terfi süresini ve
5xx'i ölçer).

Elle — `09-database-scaling` klasöründe, sırayla yapıştır. **Yıkıcı:** 3. adım primary Postgres pod'unu siler;
CNPG replikayı terfi ettirir ve silinen pod'u replika olarak geri kurar. 4. adımda iki instance da hazır olmadan
sonraki soruna geçme:

1. Grafana'yı temizle, CNPG pod'larının hazır olmasını bekle, rollere bak, primary'yi not et:
```bash
make fresh
kubectl -n lvl09 wait --for=condition=Ready pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole --timeout=180s
kubectl -n lvl09 get pods -l cnpg.io/cluster=pg -L cnpg.io/instanceRole
primary=$(kubectl -n lvl09 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}'); echo "primary: $primary"
```
2. İKİNCİ bir terminalde `09-database-scaling` klasöründe karışık yükü (100 okumaya 1 yazma) 120 sn başlat:
```bash
make load S=mixed K6_ARGS="--vus 15 --duration 120s"
```
3. Yük başladıktan ~15 sn sonra İLK terminalde primary'yi sil ve yeni primary ilan edilene kadar her 2 sn'de rolü bas:
```bash
kubectl -n lvl09 delete pod "$primary" --wait=false
for i in $(seq 1 60); do newp=$(kubectl -n lvl09 get pods -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); echo "$((i*2)) sn: primary=${newp:-yok}"; case "$newp" in ""|"$primary") sleep 2 ;; *) break ;; esac; done
```
4. İkinci terminaldeki yük bitince rollere ve kümenin durumuna bak; iki instance da hazır olana kadar bekle:
```bash
kubectl -n lvl09 wait --for=condition=Ready pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole --timeout=300s
kubectl -n lvl09 get pods -l cnpg.io/cluster=pg -L cnpg.io/instanceRole
kubectl -n lvl09 get cluster pg
```

**Terminalde ne görmelisin:** döngü önce eski primary'nin adını (ya da `primary=yok`) basar, sonra replikanın adına
döner: terfi süresi o satırdaki saniyedir (Belirti: ~10–30 sn). İkinci terminaldeki k6 özet satırında
(`k6 lvl09: reqs=… 5xx=…`) `5xx` sıfırdan büyüktür — failover penceresinde düşen istekler (script bunu arar) — ve
yük bitmeden hatalar kesilir: sistem insan müdahalesi olmadan toparlandı. 4. adımda roller yer değiştirmiştir: eski replika `primary`,
silinen pod aynı adla `replica` olarak geri gelmiştir; `kubectl get cluster pg` hazır instance sayısını ve yeni
primary'yi gösterir.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl09&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; yük 120 sn, primary 15. saniyede silinir (giriş: admin / ladder)
- Explore'da: `max by (pod) (cnpg_pg_replication_in_recovery{namespace="lvl09"})` → roller: `0` = primary, `1` = replika. Primary silinince replikanın çizgisi 1'den **0'a** iner (terfi); silinen pod bir süre kaybolur ve **1** olarak (yeni replika) geri gelir.
- "Replikasyon gecikmesi" → çizgiler 0 civarında; silinen pod'un çizgisi **kopar** ve pod replika olarak geri gelince yeniden başlar. Boşluk, o pod'un yeniden kurulma süresidir.
- "5xx (uç noktaya göre)" → primary silinince bir 5xx tepesi (başta yazma yolu `/api/links`: `503 store_error`), saniyeler sonra **kendiliğinden** 0'a döner — insan müdahalesi olmadan. Tepenin genişliği, failover penceresidir.
- "Bağlantılar ve üst sınır" → 09'dan itibaren CNPG'nin `cnpg_backends_total` metriğinden (postgres_exporter yok): primary silinince onun bağlantı çizgileri **kopar**, terfi eden pod'da yeniden kurulur — Pooler'lar yeni primary'ye bağlanıyor. Üst çizgi `max_connections` (100) sabit kalır.

**02 ile fark:** Orada kesinti **insan müdahalesine kadar** sürüyordu. Burada saniyeler — ama sıfır
değil ve olamaz.
**Uygulama tarafında gereken:** yazma hatalarında retry **+ idempotency**. Retry idempotent değilse
failover çift kayıt üretir — 06'daki `processed_events` deseninin yazma yolundaki karşılığı.
*SLO yazarken: "failover var" cümlesi "%100 erişilebilirlik" anlamına gelmez.*

---

### P09-03 · TRAP · Prepared statement + transaction pooling

**Belirti:** `prepared statement "stmtcache_..." does not exist` — **aralıklı**, yük arttıkça sıklaşan.
**Neden:** PgBouncer transaction modunda bağlantı sana yalnızca bir işlem süresince aittir. pgx bir
arka uç bağlantısında hazırlar, başka birinde çalıştırır. [Topic · Konu: Bağlantı çoğullama]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P09-03` (`QueryExecModeExec` (varsayılan) ve prepared modu aynı
`mixed` yüküyle karşılaştırır: DB hata sayısı, 5xx ve redirect loglarındaki `prepared statement` satırları).

Elle — `09-database-scaling` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, yazma Pooler'ının modunu ve arka uç havuz boyunu gör:
```bash
make fresh
kubectl -n lvl09 get pooler pg-pooler-rw -o jsonpath='poolMode={.spec.pgbouncer.poolMode} default_pool_size={.spec.pgbouncer.parameters.default_pool_size}{"\n"}'
```
2. Varsayılan (prepared kapalı): 30 kullanıcıyla 40 sn karışık yük, sonra DB hatalarını say:
```bash
make load S=mixed K6_ARGS="--vus 30 --duration 40s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(db_queries_total{namespace="lvl09",result="error"}[3m]))' | jq -r '"DB hatası: " + .data.result[0].value[1]'
```
3. Tuzağı redirect'te aç (pgx prepared moduna geçer; pod'lar yeniden başlar), aynı yük, aynı sayım, sonra loglara bak:
```bash
make set E="TRAP_PREPARED_STATEMENTS=true" W=redirect
sleep 10
make load S=mixed K6_ARGS="--vus 30 --duration 40s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(db_queries_total{namespace="lvl09",result="error"}[3m]))' | jq -r '"DB hatası: " + .data.result[0].value[1]'
kubectl -n lvl09 logs -l app.kubernetes.io/name=redirect --tail=200 | grep -ci 'prepared statement'
kubectl -n lvl09 logs -l app.kubernetes.io/name=redirect --tail=200 | grep -i -m1 'prepared statement'
```
4. Tuzağı kapat:
```bash
make reset
```

**Terminalde ne görmelisin:** `poolMode=transaction default_pool_size=20`. Varsayılan fazda `DB hatası: 0` ve k6 özet
satırında (`k6 lvl09: …`) `5xx=0`. Tuzak fazında `DB hatası` sıfırdan büyük, `5xx` de (`503 store_error`) — ama her
istekte değil: önbellek isabetleri DB'ye gitmiyor, hata yalnızca DB'ye inen okumalarda ve aralıklı. Log sayımı
sıfırdan büyüktür ve örnek satırda `prepared statement "stmtcache_…" does not exist` geçer: pgx bir arka uç
bağlantısında hazırladı, PgBouncer işlemi başka birine verdi.

**Grafana'da gör:** [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl09&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl09&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; iki faz 40'ar sn, arada redirect rollout'u (giriş: admin / ladder)
- "Yönlendirme sonuçları" → birinci fazda `error` serisi 0'da; ikinci fazda (prepared açık) **aralıklı** sıfırdan ayrılır. Önbellek isabetleri DB'ye gitmediği için hata her istekte değil, yalnızca DB'ye inen okumalarda çıkar.
- "5xx (uç noktaya göre)" → aynı anda `/{code}` için düzensiz 5xx tepeleri (`503 store_error`): kullanıcı, havuzlamanın bir protokol ayrıntısını görüyor.
- Explore'da: `sum(rate(db_queries_total{namespace="lvl09",result="error"}[1m])) by (op)` → birinci fazda 0, ikinci fazda sıfırdan ayrılır ve dalgalanır. (`05 · Postgres` → "Veritabanı sorguları (türe göre)" paneli sonuçları ayırmadan toplar; hatayı orada göremezsin.)

**Genel ders:** *Bağlantıları çoğullayan bir proxy, "bağlantı"nın ne demek olduğunu değiştirir.*
Bağlantı kimliğine dayanan her özellik yeniden gözden geçirilmeli: prepared statement · oturum
değişkenleri (`SET`) · `LISTEN/NOTIFY` · geçici tablolar · advisory lock.
**Seçenekler:** client tarafı exec modu *(uygulanmış)* · PgBouncer'da `max_prepared_statements>0` ·
session pooling (çoğullama oranını, yani Pooler'ı almanın sebebini kaybedersin).

---

### P09-04 · Replikada uzun okuma ↔ WAL çakışması

**Belirti:** `canceling statement due to conflict with recovery` — ya da `hot_standby_feedback=on`
ile: çakışma yok, ama primary'de vacuum gecikir ve şişme artar.
**Neden:** Replika WAL'i uygulamak zorundadır; uzun bir okuma, silinmesi gereken satırları tutar.
[Topic · Konu: Replika çakışmaları, vacuum]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P09-04` (replikada 45 sn'lik uzun bir sorgu başlatıp primary'de
50 bin satırlık yazma + silme + VACUUM yapar; ölü satırları taban → rehinli → serbest diye üç kez sayar,
`pg_stat_database_conflicts`'i okur).

Elle — `09-database-scaling` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, CNPG pod'larının hazır olmasını bekle, primary ile replikayı bul, replikanın
   `hot_standby_feedback` ayarına bak:
```bash
make fresh
kubectl -n lvl09 wait --for=condition=Ready pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole --timeout=180s
prim=$(kubectl -n lvl09 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}'); replica=$(kubectl -n lvl09 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}'); echo "primary: $prim replika: $replica"
kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc 'SHOW hot_standby_feedback'
```
2. Taban: primary'de `links`'i VACUUM et, ölü satır sayısını oku:
```bash
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'VACUUM (ANALYZE) links'
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='links'"
```
3. İKİNCİ bir terminalde `09-database-scaling` klasöründe replikada 45 sn süren bir okuma başlat (primary'nin
   vacuum'unu rehin alır):
```bash
replica=$(kubectl -n lvl09 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}'); kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT count(*) FROM links, pg_sleep(45)'
```
4. Hemen ardından (45 sn dolmadan) İLK terminalde: replikanın rehin aldığı xmin'in yaşı, sonra 50 bin satır çöp üret,
   VACUUM et, ölü satırları say:
```bash
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT coalesce(max(age(backend_xmin)),0) FROM pg_stat_replication WHERE backend_xmin IS NOT NULL'
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "INSERT INTO links (code, url, tenant) SELECT substr(md5(random()::text),1,7)||i, 'https://e/'||i, 'vac' FROM generate_series(1,50000) i ON CONFLICT DO NOTHING"
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "DELETE FROM links WHERE tenant='vac'"
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'VACUUM links'
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='links'"
```
5. İkinci terminaldeki sorgu sonucunu basınca (rehin kalktı) tekrar VACUUM et, ölü satırları ve replikadaki
   çakışmaları say:
```bash
sleep 5
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'VACUUM links'
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='links'"
kubectl -n lvl09 exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc "SELECT confl_snapshot + confl_bufferpin + confl_deadlock + confl_lock + confl_tablespace FROM pg_stat_database_conflicts WHERE datname='linkly'"
```

**Terminalde ne görmelisin:** `hot_standby_feedback` → `on`. Tabanda ölü satır ~0. Rehin alınan xmin'in yaşı yük yokken
küçük bir sayıdır (o ana kadar işlenen yazma işlemi kadar); asıl kanıt ölü satırlardır: `DELETE`'ten sonraki VACUUM
onları **temizleyemez**, sayı ~50 bin kalır. İkinci terminal 45 sn
sonra `links`'in satır sayısını basar — sorgu iptal edilmedi. Rehin kalkınca aynı VACUUM ölü satırları temizler
(sayı tabana iner) ve replikadaki çakışma sayısı `0`'dır: `hot_standby_feedback=on` iptali önledi, bedeli primary'deki
şişmede ödendi. Script ölü satır sayısı rehinliyken hem tabandan hem serbest hâlden büyükse REPRODUCED der. Deney
kendi çöpünü siler; geri alınacak bir şey yok.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; replikadaki uzun sorgu 45 sn sürer, yük yok (giriş: admin / ladder)
- Explore'da: `max by (application_name) (cnpg_pg_stat_replication_backend_xmin_age{namespace="lvl09"})` → primary'nin gözünden replikanın **rehin tuttuğu xmin'in yaşı**: uzun sorgu sürerken geri inmez, sorgu bitince düşer. Artış, o sürede primary'de işlenen işlem sayısı kadardır — yük yoksa küçük bir basamak.
- Explore'da: `sum(increase(cnpg_pg_stat_database_tup_deleted{namespace="lvl09",datname="linkly"}[1m]))` → script'in 50 bin satırlık `DELETE`'i bir tepe olarak görünür: vacuum'un temizleyemediği çöp bu.
- Explore'da: `sum(cnpg_pg_stat_database_conflicts{namespace="lvl09",datname="linkly"})` → **düz** kalır: `hot_standby_feedback=on` olduğu için replikada iptal yok — bedel primary'deki şişmede ödeniyor.
- Ölü satırlar (vacuum bekleyen) paneline bakma — bu seviyede **boştur**: postgres_exporter'ın tablo başına metriğini okur, CNPG bunu yayınlamaz. Ölü satır sayılarını (taban → rehinli → serbest) script terminalde basar; asıl kanıt o üç sayıdır.

**Ders:** *Bir replika "ücretsiz okuma kapasitesi" değildir.* Primary ile arasında bir pazarlık
vardır (`hot_standby_feedback`) ve pazarlığın hangi tarafını seçtiğini bilmezsen, seni o taraf bulur.

---

### P09-05 · Silme pahalı: partition'sız retention

**Belirti:** 500 bin satırlık `DELETE` uzun sürer, ölü satır bırakır ve **tablo küçülmez**.
Bir partition'ı `DROP` etmek milisaniyeler sürer ve borç bırakmaz.
**Neden:** MVCC'de silinen satır "ölü" olarak kalır; yeri vacuum sonrası kullanılabilir, diske geri
vermek `VACUUM FULL` (tam kilit) ister. [Topic · Konu: Partition, retention, MVCC]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P09-05` (düz `processed_events` tablosuna 500 bin satır ekler —
`ROWS` ile değişir —, 1 saatten eski satırları `DELETE` ile siler, ölü satır ve boyutu ölçer; ardından partition'lı
`processed_events_p`'nin en eski partition'ını `DROP` eder ve iki süreyi karşılaştırır).

Elle — `09-database-scaling` klasöründe, sırayla yapıştır. Dikkat: 3. adım `processed_events`'teki 1 saatten eski
**bütün** satırları siler (tüketicinin tekilleştirme kayıtları), 4. adım `processed_events_p`'nin en eski partition'ını
kalıcı olarak düşürür. Migration 005 dokuz günlük partition açar; hepsi tükenirse `make down` + `make up` yeniden kurar:

1. Grafana'yı temizle, primary'yi bul, partition'lı tablonun kaç partition'ı olduğuna bak:
```bash
make fresh
kubectl -n lvl09 wait --for=condition=Ready pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary --timeout=180s
prim=$(kubectl -n lvl09 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}'); echo "primary: $prim"
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT count(*) FROM pg_inherits WHERE inhparent = 'processed_events_p'::regclass"
```
2. Düz tabloya 500 bin satır ekle (her biri bir saniye daha eski), boyutuna bak:
```bash
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "INSERT INTO processed_events (event_id, processed_at) SELECT 'bulk-'||i, now() - (i||' seconds')::interval FROM generate_series(1,500000) i ON CONFLICT DO NOTHING"
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'ANALYZE processed_events'
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT pg_size_pretty(pg_total_relation_size('processed_events'))"
```
3. Saklama süresini `DELETE` ile uygula (süreyi psql ölçer), ölü satırları ve boyutu tekrar oku:
```bash
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -c '\timing on' -c "DELETE FROM processed_events WHERE processed_at < now() - interval '1 hour'"
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='processed_events'"
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT pg_size_pretty(pg_total_relation_size('processed_events'))"
```
4. Aynı temizliği partition'lı tabloda yap: en eski partition'ı düşür:
```bash
oldpart=$(kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent='processed_events_p'::regclass ORDER BY c.relname LIMIT 1"); echo "en eski partition: $oldpart"
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -c '\timing on' -c "DROP TABLE $oldpart"
```

**Terminalde ne görmelisin:** 1. adımda partition sayısı (ilk koşuda 9). 2. adımda tablo boyutu onlarca MB'a çıkar.
3. adımda `DELETE ~496000` (ilk saatin 3600 satırı kalır; önceden var olan eski kayıtlar da silinir) ve `Time:`
satırında yüzlerce milisaniyeden saniyelere varan bir süre; `n_dead_tup` yüz binlerle ölçülür ve boyut **aynı kalır**: satırlar ölü
olarak duruyor, yer diske geri verilmedi. 4. adımda `DROP TABLE` ve `Time:` birkaç milisaniye: partition düşürmek
satır satır silmez, dosyayı atar — ölü satır da vacuum borcu da bırakmaz.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) — scripti başlatınca aç; 500 bin satır ekler, siler, sonra bir partition düşürür; yük yok (giriş: admin / ladder)
- "Veritabanı CPU" → `pg-…` primary pod'unda iki tepe: 500 bin satırlık `INSERT` ve ardından `DELETE`. Partition `DROP`'u bu panelde **görünmez** — satır satır silmiyor, dosyayı atıyor.
- "İşlem / sn" → **kıpırdamaz**: 500 bin satırlık `DELETE` tek bir işlemdir. Maliyeti işlem sayısında değil, dokunduğu satır sayısında ve bıraktığı çöptedir — işlem/sn'ye bakan biri onu hiç görmez.
- Explore'da: `max(cnpg_pg_database_size_bytes{namespace="lvl09",datname="linkly"})` → ekleme sırasında basamakla yükselir ve `DELETE`'ten sonra **inmez**: silinen satırların yeri diske geri verilmiyor.
- Explore'da: `sum(increase(cnpg_pg_stat_database_tup_deleted{namespace="lvl09",datname="linkly"}[1m]))` → `DELETE` yüz binlerce satırlık bir tepe çizer; partition `DROP`'u bu sayaçta **hiç** görünmez.
- "Ölü satırlar (vacuum bekleyen)" → bu seviyede **boştur**: panel postgres_exporter'ın tablo başına metriğini okur, CNPG bunu yayınlamaz. `DELETE`'in bıraktığı ölü satır sayısını ve tablo boyutunu (önce → sonra) script terminalde basar.

**Ders:** *Saklama süresi bir şema kararıdır, bir zamanlanmış iş değil.* Tabloyu zamana göre
bölersen silmek ücretsizleşir; bölmezsen her gece koşan bir `DELETE` cron'uyla ve onun vacuum
borcuyla yaşarsın.

---

### P09-06 · Replikasyon yedek değildir

**Belirti:** Bir satır silindiğinde replikada da **saniyeler içinde** yok olur.
**Neden:** Replikasyon hatayı da kopyalar. [Topic · Konu: Yedekleme, PITR]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `CONFIRM=1 make repro P=P09-06` (yedekleme yapılandırmasına bakar, bir test linki
oluşturur, primary'de siler ve replikada da kaybolduğunu gösterir).

Elle — `09-database-scaling` klasöründe, sırayla yapıştır. Silinen tek satır, bu deneyin kendi oluşturduğu test linkidir:

1. Grafana'yı temizle, primary ile replikayı bul, yedekleme yapılandırmasına ve WAL konumuna bak:
```bash
make fresh
kubectl -n lvl09 wait --for=condition=Ready pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole --timeout=180s
prim=$(kubectl -n lvl09 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}'); repl=$(kubectl -n lvl09 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}'); echo "primary: $prim replika: $repl"
kubectl -n lvl09 get cluster pg -o jsonpath='{.spec.backup}'; echo
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT pg_current_wal_lsn()'
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'SHOW wal_keep_size'
```
2. Bir test linki oluştur, replikaya ulaşsın diye 3 sn bekle, replikada say:
```bash
code=$(curl -s -XPOST http://lvl09.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/oops"}' | jq -r .code); echo "kod: $code"
sleep 3
kubectl -n lvl09 exec "$repl" -c postgres -- psql -U postgres -d linkly -tAc "SELECT count(*) FROM links WHERE code='$code'"
```
3. "Yanlışlıkla" primary'de sil, 3 sn bekle, replikada tekrar say:
```bash
kubectl -n lvl09 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "DELETE FROM links WHERE code='$code'"
sleep 3
kubectl -n lvl09 exec "$repl" -c postgres -- psql -U postgres -d linkly -tAc "SELECT count(*) FROM links WHERE code='$code'"
```

**Terminalde ne görmelisin:** `spec.backup` satırı **boş**: bu seviyede nesne deposu bilerek yapılandırılmadı. WAL
konumu (`0/…` biçiminde bir LSN) ve `wal_keep_size` basılır. Silmeden önce replikada `1`, silmeden 3 sn sonra `0`:
replika hatayı da saniyeler içinde kopyaladı — geri dönülecek bir kopya yok.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now&refresh=10s) — script bittikten sonra aç (giriş: admin / ladder)
- "Replikasyon gecikmesi" → her pod için 0 civarında düz çizgi: replika primary'yi saniyeler içinde yakalıyor — yanlış `DELETE`'i de aynı hızla kopyalıyor. Düşük gecikme burada iyi haber değil, hatanın yayılma hızıdır.
- Tek satırlık silmenin kendisi hiçbir panelde görünmez; kanıt script çıktısındaki `silme öncesi replikada: 1 satır · silme sonrası: 0 satır` satırıdır.

**Ders:** *Yedek, zamanda geri gitme yeteneğidir; replika ise zamanda ileri gitmenin kopyasıdır.*
Gerçek koruma üç ayaklıdır: (1) sürekli WAL arşivleme, (2) periyodik temel yedek, (3) **düzenli
geri yükleme tatbikatı**. Üçüncüsü olmadan ilk ikisi bir temennidir — bu yüzden bu seviyede nesne
deposu **bilerek yapılandırılmadı**: yedeklemeyi "açmak" bir YAML bloğu; asıl mesele tatbikat, ve
tatbikat bu merdivenin kapsamı dışında kalır (14 §9, "yolun devamı").

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_NO_STICKY` | Yazma sonrası yapışkan okumayı kapatır | `make repro P=P09-01` | Bayrağı kapat |
| `TRAP_PREPARED_STATEMENTS` | pgx'i prepared moduna zorlar | `make repro P=P09-03` | Bayrağı kapat |
| `TRAP_GLOBAL_LIMIT` · `TRAP_IGNORE_XFF` · `TRAP_TRUST_ANY_XFF` | (08'den devam) | 08'de | — |

Elle denemeye değer:
- `DATABASE_URL_RO`'yu boşalt: okuma/yazma ayrımı kapanır, 09'un **tüm yeni sorunları kaybolur** —
  ve okuma ölçeklenmesi de. *Tek bir env değişkeni, bir mimari kararın tamamını geri alıyor;
  takasın bu kadar görünür olması iyi bir tasarım işaretidir.*
- `default_pool_size`'ı 2'ye düşür: çoğullama oranı artar, ama işlemler PgBouncer'da kuyruğa girer.
  P02-06'nın aynısını bu kez **proxy'de** görürsün. *Kuyruğu bir katman aşağı itmek, yok etmek değildir.*
- `kubectl -n lvl09 cnpg promote pg pg-2` (plugin varsa) ile planlı bir failover yap: plansız
  olanla süresini karşılaştır.
- `STICKY_WINDOW=30s` yap ve `make load S=mixed` koş: RYW ihlali biter, ama okumaların büyük kısmı
  primary'ye gider — replika boşta kalır. **Tutarlılık ile ölçeklenme arasındaki düğme budur.**

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl09&from=now-15m&to=now) | **Zenginleşti** ✨ — kısmen | CNPG PodMonitor: replikasyon gecikmesi, roller, WAL; bağlantı / üst sınır / işlem/sn / bellekten okuma oranı panelleri CNPG metriklerine düşüyor. postgres_exporter olmadığı için **tablo tarama, kilitler ve ölü satırlar boş**. Ayrıca `db_reads_routed_total` |
| [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl09&from=now-15m&to=now) | Dolu — **RYW ihlali artık gerçek** | 09'a kadar bu sayaç hep 0 idi |
| [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl09&from=now-15m&to=now) · [`09 · Autoscaling`](http://grafana.localtest.me/d/ladder-autoscaling?var-level=lvl09&from=now-15m&to=now) · [`08 · Stream`](http://grafana.localtest.me/d/ladder-stream?var-level=lvl09&from=now-15m&to=now) · [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl09&from=now-15m&to=now) · [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl09&from=now-15m&to=now) | Dolu | — |
| [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl09&from=now-15m&to=now) · [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl09&from=now-15m&to=now) · [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl09&from=now-15m&to=now) | Boş | — |

Yeni okuma alışkanlığı: `db_reads_routed_total{target}`. Okumaların ne kadarı replikaya gidiyor?
Oran beklenenden düşükse ya sticky pencere çok uzun ya da replika sağlıksız — ve ikisi de
"DB yavaş" diye rapor edilir.

## 9. Bilerek bırakılanlar

- **Nesne deposu / PITR yapılandırılmadı** (P09-06; yedek + geri yükleme tatbikatı 14 §9'da "yolun devamı").
- **`max_connections` hâlâ 100** — Pooler olmasa duvar aynı yerde; sayıyı değiştirmemek bilinçli.
- **Yapışkan işaret Redis'te ve fail-open**: Redis yoksa işaret okunamaz, okuma replikaya gider (bkz. `store/recent.go`) — tazelik, yazma yolunu Redis'e bağlamaktan ucuz bir kayıp sayıldı.
- **Partition'lar elle oluşturuluyor** (migration 005, 9 günlük). Üretimde `pg_partman` ya da bir
  operatör gerekir — *"partition'lar kendiliğinden oluşmaz" dersi görünür kalsın diye elle.*
- **`clicks_daily` partition'sız**: satır sayısı kod×gün ile sınırlı olduğu için gerekmedi.
- **Okuma replikası coğrafi değil**: aynı kümede, aynı bölgede. Çok bölgeli okuma kapsam dışı (14 §9, "yolun devamı").
- **08'den devreden**: tek Redis (hem önbellek hem limiter), kimlik yok, tek partition.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 08 ile farkı gösterir:

1. **`internal/store/readwrite.go`** (yeni): `Store` arayüzünü **üçüncü kez** sarmaladık
   (02: Postgres, 03/04: Cached, 09: ReadWrite). Aynı arayüz, üç farklı mimari karar — 01'de
   `CreateUnique`'i koşullu ekleme olarak tasarlamanın faturası burada da kesilmiyor.
2. **`internal/store/recent.go`** (yeni): yapışkan okumanın işareti. Redis'te, çünkü 07'den beri
   oluşturma api-svc'de, okuma redirect-svc'de: süreç içi bir işaret servisler arası hiç eşleşmez.
   Yorumu, bunun neden sessizce fark edilmeden kalacağını anlatıyor.
3. **`deploy/cnpg.yaml`**: `deploy/postgres.yaml`'ın yerini aldı. Karşılaştırmalı oku —
   birkaç satırlık `instances: 2` + `Pooler`, 02'deki 90 satırlık StatefulSet'in yapamadığı her şeyi
   yapıyor. **Operatörün değeri budur; ve tam da bu yüzden 02'de kullanmadık.**
4. **`internal/store/postgres.go` → `OpenWithMode`**: tek satırlık `QueryExecModeExec`, P09-03'ün
   tamamı. Bir proxy eklemek, client kütüphanesinin varsayımlarını geçersiz kılabilir.
5. **`migrations/005`**: `PARTITION BY RANGE` + `NO TRANSACTION`. Partition'lamanın sebebi sorgu
   hızı değil, **silmeyi ucuzlatmak**.
