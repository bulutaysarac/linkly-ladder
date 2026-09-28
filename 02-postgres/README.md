# 02 — postgres · "Kalıcılık ve yatay ölçek"

> **Bu seviyede ne yaşayacaksın?**
> - Veri süreçten çıkınca 3 replikanın, temiz rollout'un ve düğüm boşaltmanın bedava gelmesi — 00/01'in kalıcılık ve ölçek sorunları kapanır
> - Her yönlendirmenin bir DB sorgusu olması (P02-01) ve bağlantı havuzunun taşması (P02-02)
> - Tek Postgres ölünce her şeyin durması (P02-03); süreç içi hız sınırının 3 replikada 3 katı olması (P02-04)
> - İndeks yokken tam tablo taraması (P02-05); DB yavaşlayınca sunucu timeout'u olmayan havuzun tıkanması (P02-06)
> - Migration'ı her pod koşunca yarış (P02-07), sıcak linkte satır kilidi kuyruğu (P02-08), düz metin sırlar (P02-09), readiness DB'ye bakınca tam kesinti (P02-10)
>
> **Bu seviye olmasa ne olur?** Her restart bütün linkleri siler ve ikinci bir replika açılamaz — çünkü veri sürecin içinde yaşar (P00-02, P00-03, P01-01, P01-02).
>
> **Yeni gelen teknolojiler:** PostgreSQL 17, pgx (bağlantı havuzu), goose (migration Job'ı), postgres-exporter, Chaos Mesh ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Linkler artık Postgres'te; uygulama durumsuz (stateless). Bu, 3 replikayı, temiz rollout'u ve düğüm boşaltmayı
mümkün kılar. Bedeli: her istek artık ağ üzerinden tek bir veritabanına gidiyor.

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

Uygulama yedekli, veritabanı değil: üç pod da aynı tek Postgres'e bağlı (P02-03).

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P00-02 / P01-01 | Uygulama yeniden başlayınca bütün linkler kaybolur | Linkler Postgres veritabanında, kalıcı bir diskte tutulur; pod'lar gelip gider, veri kalır |
| P00-03 / P01-02 | Uygulama birden çok kopyaya çıkınca linkler rastgele 404 verir | Üç kopya da aynı veritabanını okur; hepsi aynı linkleri görür |
| P01-03 | Tek kopyalı servisi koruyan kural (PDB) düğüm bakımını kilitler | 3 kopya farklı düğümlere yayılır; kural "en az 2 kopya ayakta" der (`minAvailable: 2`), bakımda bir kopya kapatılabilir |
| P01-04 | Bellek link sayısıyla sınırsız büyür | Uygulama veriyi kendi belleğinde tutmaz, veritabanından okur |

Kısmen: tıklama sayacı (P01-08) hâlâ yönlendirme isteğinin içinde ama artık kalıcı (veritabanında); istek yolundan tamamen çıkması 05'te.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/02-postgres"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
make link          # example.com'a kısa link oluştur, yönlendirmeyi dene → 302 · başka adres: make link URL=https://…
make grafana       # Ladder klasörü, level=lvl02 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P02-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

Veritabanına `psql` ile bağlanmak için (çıkış: `\q`):
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 exec -it $(kubectl -n lvl02 get pod -l app.kubernetes.io/name=postgres -o name) -c postgres -- psql -U linkly -d linkly
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl02 ayakta` yazar:
```bash
cd "$LADDER/01-hardened"
make down
cd "$LADDER/02-postgres"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/02-postgres"
make up
```
2. 01'in sorunlarını burada koş (koşarken başka komut çalıştırma). `CONFIRM=1` şart: scriptlerin çoğu pod siler ya da
   replika değiştirir, onaysız `SKIPPED` der. `BEKLENEN` sütunu `NOT-REPRODUCED` olan satırlar (P01-01, P01-02, P01-03,
   P01-04, P01-08) bu seviyenin çözdüğünü iddia ettikleri; sonuç uymazsa satır `✘` alır:
```bash
cd "$LADDER/02-postgres"
CONFIRM=1 make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P02-01 → P02-10): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç.
4. Bitince ayarları geri al ve seviyeyi kapat:
```bash
cd "$LADDER/02-postgres"
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyede yeni: `GET /api/links` (kiracıya göre listeler); silme ve listeleme `X-Tenant-ID` ile sınırlı. Bu bir
kimlik doğrulama değil — başlığı herkes gönderebilir (13).

## 6. Reproduce edilebilir sorunlar

Bu seviyede yaşayacağın 10 sorun. Her birini iki yoldan görebilirsin: **Otomatik** — `make repro P=<ID>` deneyi
kendisi yapar, ölçer ve hükmünü basar (`REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` =
ölçülemedi); **Elle** — adımları sırayla yapıştırıp sonucu kendi gözünle görürsün. Her sorunun bölümü aynı
düzende: **Ne oluyor** → **Neden oluyor** → **Bu deney** → adımlar → **Terminalde ne görmelisin** →
**Grafana'da gör** (giriş: admin / ladder) → **Nasıl çözülüyor**.

**Kısa komut** deneyi otomatik başlatır; seviyenin klasöründe çalıştır (önce `cd "$LADDER/02-postgres"`). Başında
`CONFIRM=1` olanlar yıkıcı bir adım içerir (pod silmek, yeniden başlatmak, arıza enjekte etmek gibi); bu onay
olmadan script o adımı yapmaz ve `SKIPPED` basar.

| ID | Kısa komut | Ne olur? | Neden olur? | Nasıl çözülür? |
|---|---|---|---|---|
| P02-01 | `make repro P=P02-01` | Her yönlendirme veritabanına iki sorgu attırır; trafik arttıkça bütün yük tek bir yerde, Postgres'te toplanır | Link her seferinde veritabanından okunur (`SELECT`), tıklama her seferinde veritabanına yazılır (`UPDATE`) | **03/04:** okumalar önbellekten · **05:** tıklama yazması istek yolundan çıkar |
| P02-02 | `CONFIRM=1 make repro P=P02-02` | Uygulama 10 kopyaya çıkınca veritabanı yeni bağlantıları reddeder, istekler 503 alır | Her kopya 25 bağlantılık kendi havuzunu açar: 10 × 25 = 250, Postgres'in sınırı 100 | **09:** bağlantı havuzlayıcı (PgBouncer) çok bağlantıyı az sayıda gerçek bağlantıya indirir |
| P02-03 | `CONFIRM=1 make repro P=P02-03` | Tek veritabanı ölünce 3 kopyalı uygulama da hata verir | Uygulama 3 kopya ama veritabanı tek; yedeklilik en zayıf halka kadardır | **09:** yedekli veritabanı (ana + yedek + otomatik devralma) |
| P02-04 | `CONFIRM=1 make repro P=P02-04` | "Saniyede 40 istek" sınırı pratikte saniyede ~120 | Her kopya sınırı kendi belleğinde sayar ve artık varsayılan 3 kopya var | **08:** ortak sınır sayacı Redis'te |
| P02-05 | `make repro P=P02-05` | Kiracıya göre link listesi, tablo büyüdükçe belirgin yavaşlar | Aranan sütunda indeks yok; veritabanı her seferinde bütün tabloyu okur (seq scan) | **Bu seviyede:** indeks eklenir (`migrations/002`) |
| P02-06 | `make repro P=P02-06` | Veritabanı ölmeden yalnızca yavaşlayınca uygulama da tıkanır ve 503 verir | Uygulama beklemeyi bırakır ama veritabanı sorguyu sürdürür; bağlantılar meşgul kalır, havuz dolar | **Bu seviyede:** veritabanı tarafı zaman aşımı (`STATEMENT_TIMEOUT`) · **10:** devre kesici |
| P02-07 | `make repro P=P02-07` | **Tuzak:** şema değişikliğini her pod kendisi uygularsa pod'lar çöker, şema bozuk kalabilir | Aynı anda açılan pod'lar aynı işe girişip birbirini kilitler | **Bu seviyenin ayarı:** şema değişikliği tek seferlik ayrı bir iş (Job) |
| P02-08 | `make repro P=P02-08` | En popüler link en yavaş link olur | Her tıklama aynı veritabanı satırını günceller; güncellemeler o satırın kilidini sırayla bekler | **05:** tıklamalar kuyrukta toplanıp toplu yazılır · **06:** olay akışı |
| P02-09 | `make repro P=P02-09` | Veritabanı parolası repoyu ya da kümeyi okuyabilen herkese açık | Parola repoda düz metin; Kubernetes Secret'ı şifrelemez, yalnızca kodlar (base64) | **13** (kısmen): ağ kuralları; sırlar hâlâ düz metin (P13-04) |
| P02-10 | `CONFIRM=1 make repro P=P02-10` | **Tuzak:** veritabanı kısa süre gidince uygulamanın bütün kopyaları trafikten çıkar, servis tamamen kesilir | Kopyalar "hazır mısın?" sorusuna "veritabanına ulaşabiliyor muyum?" diye cevap verir; hepsi aynı anda "hayır" der | **Bu seviyenin ayarı:** hazır olma kontrolü yalnızca pod'un kendisine bakar · **10:** devre kesici |

---

### P02-01 · Her redirect bir DB sorgusu

**Ne oluyor:** Her kısa link açıldığında uygulama veritabanına iki sorgu gönderir: linki bulmak için bir okuma,
tıklamayı saymak için bir yazma. Trafik arttıkça bütün yük tek bir paylaşılan kaynakta, Postgres'te toplanır;
yönlendirme süresinin çoğu veritabanında geçer.
**Neden oluyor:** 02'de veri artık uygulamanın belleğinde değil, veritabanında; uygulama hiçbir şeyi hatırlamaz ve
her istekte sorar. Okuma ağırlıklı bir sistemde (bir link bir kez oluşturulur, binlerce kez açılır) bu, en sık
yapılan işin en pahalı yoldan yapılması demek.
**Bu deney:** 30 kullanıcıyla 60 sn yönlendirme yükü verir; saniyedeki yönlendirme ve sorgu sayısını, Postgres'in
CPU kullanımını ve yönlendirme süresini (p99) Prometheus'tan okur.

**Reproduce (adım adım):** Otomatik: `make repro P=P02-01` (60 sn yönlendirme yükü verir; yönlendirme başına sorguyu,
Postgres CPU'sunu ve p99'u hesaplar). Elle:

1. Temiz başla; 30 kullanıcıyla 60 sn yönlendirme yükü ver:
```bash
cd "$LADDER/02-postgres"
make fresh
make load S=redirect K6_ARGS="--vus 30 --duration 60s"
```
2. Son ölçümün gelmesini bekle; saniyedeki yönlendirmeyi, türe göre saniyedeki sorguyu, Postgres CPU'sunu (bir
   çekirdeğin %'si) ve yönlendirme p99'unu (saniye) Prometheus'a sor:
```bash
cd "$LADDER/02-postgres"
sleep 15
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(http_requests_total{namespace="lvl02",route="/{code}"}[2m]))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (rate(db_queries_total{namespace="lvl02"}[2m]))' | jq -r '.data.result[] | "\(.metric.op) \(.value[1])"'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="lvl02",pod=~"postgres.*",image!="",image!~".*pause.*"}[2m])) * 100' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl02",route="/{code}"}[2m])) by (le))' | jq -r '.data.result[0].value[1]'
```

**Terminalde ne görmelisin:** `get` ve `increment_clicks` birbirine eşit ve yönlendirme sayısına yakın (her yönlendirme
bir SELECT + bir UPDATE); toplam sorgu, yönlendirmenin ~2 katı. Ölçülen: 563 yönlendirme/s → 1114 sorgu/s, Postgres
CPU ~31 (çekirdeğin %31'i), p99 ~0.097 (96.7 ms).

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl02&from=now-15m&to=now&refresh=10s) — yük başlayınca aç; 60 sn sürer
- "Veritabanı sorguları (türe göre)" → `get` ve `increment_clicks` eşit kalınlıkta yükselir; toplam yönlendirmenin ~2 katı.
- "Veritabanı CPU" → `postgres-0` trafikle orantılı tırmanır (~%31): yük tek kaynakta toplanıyor.
- "Sorgu süresi p99 (türe göre)" → `get` p99'u (~50 ms) yönlendirme p99'unun yarısı: sürenin çoğu DB'de.
- "p99 süre (uç noktaya göre)" → `/{code}` yük altında ~97 ms'ye çıkar; 01'de bu bir bellek aramasıydı.

**Nasıl çözülüyor:** Okuma (`SELECT`) 03'te süreç içi, 04'te paylaşılan önbellekle veritabanına gitmez; tıklama yazması (`UPDATE`) 05'te istek yolundan çıkıp kuyrukla toplu yazılır.

---

### P02-02 · Bağlantı havuzu taşması

**Ne oluyor:** Trafik için uygulamayı 10 kopyaya çıkarınca veritabanı yeni bağlantıları "too many clients" diyerek
reddeder ve kullanıcılar 503 alır. Daha fazla kopya, daha fazla kapasite yerine hata getirir.
**Neden oluyor:** Her kopya veritabanına kendi bağlantı havuzunu (hazırda tutulan bağlantılar) açar ve boyutunu tek
başınaymış gibi seçer: 25 bağlantı. 3 × 25 = 75 Postgres'in 100'lük sınırına sığar, 10 × 25 = 250 sığmaz. Havuz
boyutu yerel bir karar gibi görünür ama ortak bir sınırı tüketir.
**Bu deney:** Bağlantı sınırını ve havuz boyutunu gösterir, 10 kopyaya çıkıp 80 kullanıcıyla 60 sn yük verir; açık
bağlantıları, hatalı sorguları ve Postgres'in reddini sayar, sonunda geri alır.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P02-02` (10 replikaya çıkar, 80 kullanıcıyla 60 sn yük
verir; bağlantıları, DB hatalarını ve 5xx'i sayar, geri alır). Elle:

1. Temiz başla; Postgres'in bağlantı sınırına ve pod başına havuz boyutuna bak:
```bash
cd "$LADDER/02-postgres"
make fresh
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -tAc 'SHOW max_connections'
kubectl -n lvl02 get deploy linkly -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DB_MAX_CONNS")].value}'; echo
```
2. 10 replikaya çık (10 × havuz > sınır):
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 scale deploy/linkly --replicas=10
kubectl -n lvl02 rollout status deploy/linkly --timeout=180s
sleep 10
```
3. 80 kullanıcıyla 60 sn yük ver; açık bağlantıları, hatalı sorguları ve logdaki reddi say:
```bash
cd "$LADDER/02-postgres"
make load S=mixed K6_ARGS="--vus 80 --duration 60s"
sleep 12
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(pg_stat_activity_count{namespace="lvl02"})' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(db_queries_total{namespace="lvl02",result="error"}[5m]))' | jq -r '.data.result[0].value[1]'
kubectl -n lvl02 logs -l app.kubernetes.io/name=linkly --tail=300 | grep -c 'too many clients'
```
4. Geri al:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 scale deploy/linkly --replicas=3
kubectl -n lvl02 rollout status deploy/linkly
```

**Terminalde ne görmelisin:** `100` ve `25`. k6 özetinde `5xx` sıfırdan büyük. Açık bağlantı sınıra (100) yakın, hatalı
sorgu ve `grep -c` sıfırdan büyük: Postgres yeni bağlantıyı `FATAL: sorry, too many clients already` ile reddediyor,
uygulama `503 store_error` dönüyor.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl02&from=now-15m&to=now&refresh=10s) — 10 replikaya çıkıp yük başlayınca aç; 60 sn sürer
- "Bağlantılar ve üst sınır" → `üst sınır` 100'de düz; bağlantı çizgilerinin toplamı bu tavana yapışır.
- "İstek / saniye (durum koduna göre)" → `503` çizgisi belirir: Postgres `too many clients` diyor.
- "Uygulama havuzu: boş bağlantı bulunamadı / sn" → sıfırda kalır: hiçbir pod'un kendi havuzu dolmadı. Yerel havuz iyi görünürken sistem hata veriyorsa sebep ortak sınırdır.
- Explore'da: `sum by (op) (rate(db_queries_total{namespace="lvl02",result="error"}[1m]))` → bağlantılar tavana çarptığında hatalı sorgu çizgileri sıfırdan kalkar.

**Nasıl çözülüyor:** 09'da uygulama ile Postgres arasına bir bağlantı havuzlayıcı (PgBouncer) girer: çok sayıda uygulama bağlantısını az sayıda gerçek veritabanı bağlantısına eşler. Havuzu küçültmek çözüm değildir; kuyruğu uygulamaya taşır (P02-06).

---

### P02-03 · Veritabanı tek nokta

**Ne oluyor:** Tek Postgres pod'u ölünce uygulamanın 3 kopyası ayakta ve "hazır" olsa da her istek 503 döner;
veritabanı dönene kadar servis kullanılamaz.
**Neden oluyor:** Uygulama 3 kopya ama veritabanı tek: yedeklilik zincirin en zayıf halkası kadardır. "3 replika"
uygulamanın yedekli olduğunu söyler, sistemin değil.
**Bu deney:** Yük altında tek veritabanı pod'unu siler, 60 sn boyunca 2 sn'de bir link oluşturmayı dener; kesinti
süresini ve 5xx hatalarını ölçer.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P02-03` (yük altında Postgres pod'unu siler, kesinti
penceresini ve 5xx'i ölçer). Elle:

1. Temiz başla; pod'lara bak:
```bash
cd "$LADDER/02-postgres"
make fresh
kubectl -n lvl02 get pods
```
2. İkinci bir terminalde yükü başlat:
```bash
cd "$LADDER/02-postgres"
make load S=redirect K6_ARGS="--vus 5 --duration 120s"
```
3. ~15 sn sonra ilk terminalde tek veritabanı pod'unu sil (yıkıcı; veri diskte kalır, pod yeniden açılır) ve 60 sn
   boyunca 2 sn'de bir link oluşturmayı dene:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 delete pod postgres-0 --wait=false
kubectl -n lvl02 get pods
for i in $(seq 1 30); do printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -XPOST http://lvl02.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p0203"}')"; sleep 2; done; echo
```
4. Veritabanının döndüğünü doğrula (sonraki deney hazır bir DB bulsun):
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 rollout status statefulset/postgres --timeout=180s
```

**Terminalde ne görmelisin:** `postgres-0` `Terminating` ya da `0/2`, üç `linkly-…` pod'u `1/1 Running`. Döngü önce art
arda `503` basar (bunu uygulama veriyor: `store_error`), DB dönünce `201`. k6 özetinde `5xx` > 0: 3 replika hiçbir şeyi
kurtarmadı.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl02&from=now-15m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl02&from=now-15m&to=now&refresh=10s) ve [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now&refresh=10s) — yük başlayınca aç; 2 dk sürer
- "Hazır pod adresi (endpoint) sayısı" → `linkly` 3'te düz kalır (P02-10'da sıfıra iner); `postgres` 0'a iner ve pod hazır olunca 1'e döner.
- "5xx (uç noktaya göre)" → kesinti boyunca `/{code}` kalkar: 503'ü uygulama veriyor, pod'lar hazır ama DB yok.
- "Bağlantılar ve üst sınır" → çizgiler kesilir (exporter DB ile aynı pod'da), DB dönünce yeniden kurulur.
- Explore'da: `pg_up{namespace="lvl02"}` → 1'den düşer, DB dönünce 1.

**Nasıl çözülüyor:** 09'da Postgres bir operatörle (CloudNativePG) yönetilir: bir ana (primary) ve bir yedek (replika) sunucu; ana ölünce yedek onun yerini alır (otomatik failover).

---

### P02-04 · Süreç içi hız sınırı 3 replikada 3 katı

**Ne oluyor:** Uygulamada "istemci başına saniyede 40 istek" sınırı var; ama 02'de uygulama varsayılan olarak 3 kopya
çalıştığı için aynı istemci pratikte saniyede ~120 istek geçirir. Sınırın amacı veritabanını korumaksa, koruma
yazılanın üç katı gevşek.
**Neden oluyor:** Sınır sayacı her kopyanın kendi belleğinde (P01-05'in aynısı): her kopya yalnızca kendisine
gelenleri sayar. Korunan kaynak (veritabanı) tek, koruma kopya başına.
**Bu deney:** Sınırı kopya başına saniyede 40 yapar, aynı yükü önce 1 sonra 3 kopyaya verir ve kabul edilen istekleri
karşılaştırır; sonunda ayarları geri alır.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P02-04` (sınırı pod başına 40/s yapar, aynı yükü önce 1
sonra 3 pod'a verir, kabul edilenleri karşılaştırır, geri alır). Elle:

1. Temiz başla; sınırı pod başına saniyede 40'a çek (pod'lar yeniden başlar):
```bash
cd "$LADDER/02-postgres"
make fresh
make set E="RATE_LIMIT_PER_SEC=40 RATE_LIMIT_BURST=40"
```
2. Tek pod'a in, 20 kullanıcıyla 20 sn yük ver:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 scale deploy/linkly --replicas=1
kubectl -n lvl02 rollout status deploy/linkly
sleep 10
make load S=redirect K6_ARGS="--vus 20 --duration 20s"
```
3. Seviyenin gerçek replika sayısına (3) dön, aynı yükü ver:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 scale deploy/linkly --replicas=3
kubectl -n lvl02 rollout status deploy/linkly
sleep 10
make load S=redirect K6_ARGS="--vus 20 --duration 20s"
```
4. Sınırı geri al:
```bash
cd "$LADDER/02-postgres"
make reset
```

**Terminalde ne görmelisin:** her yükün sonunda `k6 lvl02: reqs=… 429=…`; kabul edilen = `reqs − 429`. Tek pod'da ~800
(40/s × 20 sn), 3 pod'da ~2400: "40" yazdın, sistem ~120 geçirdi.

**Grafana'da gör:** [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl02&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; iki faz 20'şer sn
- "İzin verilen (pod'a göre)" → ilk fazda tek çizgi (~40/s), ikinci fazda üç çizgi, her biri ~40/s: toplam ~3 katı.
- "Kararlar (anahtar türüne göre)" → `ip allow` ikinci fazda ~3 katına çıkar.

**Nasıl çözülüyor:** 08'de sınır sayacı bütün kopyaların ortak kullandığı Redis'te tutulur; sınır kopya sayısından bağımsız olur.

---

### P02-05 · Index yok → seq scan

**Ne oluyor:** Bir kiracının linklerini listelemek (`GET /api/links`) küçük tabloda anında biter; tablo büyüdükçe
aynı istek belirgin yavaşlar. Küçük veride fark edilmeyen sorun, büyük veride olaya dönüşür.
**Neden oluyor:** Listeleme sorgusu kiracı (`tenant`) sütununa göre arar ama bu sütunda indeks (kitabın sonundaki
dizin gibi hızlı arama yapısı) yok — bilerek. Veritabanı her seferinde bütün tabloyu baştan sona okuyup süzer
(seq scan).
**Bu deney:** Tabloya 300 bin satır ekler, sorgunun planına (`EXPLAIN ANALYZE`) ve listeleme süresine bakar; sonra
indeksi kurup aynı ölçümü tekrarlar ve indeksi yeniden kaldırır.

**Reproduce (adım adım):** Otomatik: `make repro P=P02-05` (300 bin satır ekler, sorgu planını (`EXPLAIN ANALYZE`) ve
listeleme süresini basar). Elle:

1. Temiz başla; tabloda kaç satır var bak:
```bash
cd "$LADDER/02-postgres"
make fresh
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -tAc 'SELECT count(*) FROM links'
```
2. 300 bin satır ekle (her 100 satırdan biri `acme` kiracısına) ve istatistikleri güncelle:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c "INSERT INTO links (code, url, tenant, created_at) SELECT substr(md5(random()::text), 1, 7) || i, 'https://example.com/seed/' || i, CASE WHEN i % 100 = 0 THEN 'acme' ELSE 'tenant-' || (i % 50) END, now() - (i || ' seconds')::interval FROM generate_series(1, 300000) i ON CONFLICT DO NOTHING" -c 'ANALYZE links'
```
3. Sorgunun planına bak, sonra aynı listeyi API'den iste ve süresini ölç:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c "EXPLAIN (ANALYZE, BUFFERS) SELECT code FROM links WHERE tenant='acme' ORDER BY created_at DESC LIMIT 100"
curl -s -o /dev/null -w 'GET /api/links: %{time_total} sn\n' -H 'X-Tenant-ID: acme' http://lvl02.localtest.me/api/links
```
4. Grafana'da belirginleştirmek için listeyi 20 kez iste:
```bash
cd "$LADDER/02-postgres"
for i in $(seq 1 20); do curl -s -o /dev/null -H 'X-Tenant-ID: acme' http://lvl02.localtest.me/api/links; done
```
5. Çözümü dene: `migrations/002`'nin indeksini kur, planı ve süreyi yeniden ölç, sonra indeksi kaldır (P02-07 ve bu
   deneyin tekrarı indekssiz tablo ister):
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c 'CREATE INDEX CONCURRENTLY IF NOT EXISTS links_tenant_created_idx ON links (tenant, created_at DESC)'
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c "EXPLAIN (ANALYZE, BUFFERS) SELECT code FROM links WHERE tenant='acme' ORDER BY created_at DESC LIMIT 100"
curl -s -o /dev/null -w 'GET /api/links: %{time_total} sn\n' -H 'X-Tenant-ID: acme' http://lvl02.localtest.me/api/links
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c 'DROP INDEX CONCURRENTLY IF EXISTS links_tenant_created_idx'
```

**Terminalde ne görmelisin:** 2. adımda `INSERT 0 300000`. 3. adımın planında `Seq Scan on links` (ya da
`Parallel Seq Scan`), `Filter: (tenant = 'acme'::text)` ve büyük bir `Rows Removed by Filter`: ~3000 satır için bütün
tablo okundu. 5. adımda plan `Index Scan using links_tenant_created_idx` olur, `Rows Removed by Filter` kaybolur,
`Execution Time` belirgin düşer.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now&refresh=10s) — deneyden hemen sonra aç
- "Tablo tarama: tam tarama / indeksli" → listeleme anlarında `tam tarama: links` tepe yapar; indeks kurulunca aynı çağrı `indeksli: links`'e geçer.
- "Sorgu süresi p99 (türe göre)" → `list` çizgisi diğer sorguların çok üstünde; indeksten sonra iner.

**Nasıl çözülüyor:** Bu seviyede `migrations/002_tenant_index.sql` ile indeks eklenir. `CONCURRENTLY` şarttır: düz `CREATE INDEX` kurulum boyunca tabloya her yazmayı durdurur.

---

### P02-06 · Yavaş DB + sunucu tarafı timeout yok → havuz tıkanır

**Ne oluyor:** Veritabanı ölmez, yalnızca yavaşlar (her sorgu 2 sn gecikir); ama uygulama da tıkanır: istekler
saniyelerce bekler ve 503 alır. Yavaş bir bağımlılık, ölü bir bağımlılık kadar zarar verebilir.
**Neden oluyor:** Uygulama bir sorguyu 3 sn bekleyip vazgeçer (`DB_QUERY_TIMEOUT`), ama veritabanı tarafında süre
sınırı yok (`STATEMENT_TIMEOUT` boş): Postgres sorguyu çalıştırmaya devam eder, bağlantı meşgul kalır ve havuz dolar.
Vazgeçmek işi durdurmaz, yalnızca beklemeyi bırakır.
**Bu deney:** Chaos Mesh ile Postgres'in ağına 2 sn gecikme ekler, 40 kullanıcıyla 60 sn yük verir; havuzdan bağlantı
bekleme süresini ve 5xx'i ölçer, karşılaştırma için veritabanı tarafı zaman aşımını açıp tekrarlar.

**Reproduce (adım adım):** Otomatik: `make repro P=P02-06` (Postgres'e Chaos Mesh ile 2 sn gecikme ekler, 40 kullanıcıyla
60 sn yük altında havuz beklemesini ve 5xx'i ölçer, gecikmeyi kaldırır). Chaos Mesh kurulu değilse bir kez: `cd "$LADDER/platform" && make chaos`. Elle:

1. Temiz başla; timeout ayarlarına bak, Postgres'in ağına 2 sn gecikme ekle:
```bash
cd "$LADDER/02-postgres"
make fresh
make env
make chaos C=pg-delay-2s
```
2. 40 kullanıcıyla 60 sn yük ver; havuz beklemesinin p99'unu (saniye), boş havuza çarpan istek sayısını ve aynı anda
   işlenen isteklerin tepesini sor:
```bash
cd "$LADDER/02-postgres"
make load S=mixed K6_ARGS="--vus 40 --duration 60s"
sleep 12
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace="lvl02"}[2m])) by (le))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(increase(db_pool_empty_acquire_total{namespace="lvl02"}[5m]))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time(sum(http_in_flight_requests{namespace="lvl02"})[5m:15s])' | jq -r '.data.result[0].value[1]'
```
3. Gecikmeyi kaldır:
```bash
cd "$LADDER/02-postgres"
make unchaos C=pg-delay-2s
```
4. Karşılaştırma: sunucu tarafı timeout'u (`STATEMENT_TIMEOUT=2s`) aç, aynı gecikme ve yükü tekrarla, sonra geri al:
```bash
cd "$LADDER/02-postgres"
make set E="STATEMENT_TIMEOUT=2s"
sleep 10
make chaos C=pg-delay-2s
make load S=mixed K6_ARGS="--vus 40 --duration 60s"
make unchaos C=pg-delay-2s
make reset
```

**Terminalde ne görmelisin:** `make env`'de `DB_QUERY_TIMEOUT=3s` ve boş `STATEMENT_TIMEOUT=`. `make chaos`
`networkchaos.chaos-mesh.org/pg-delay-2s created` der. k6 özetinde `5xx` > 0 ve `p99` saniyeler mertebesinde (`503
store_error`). Havuz bekleme p99'u scriptin 0.05 sn eşiğinin çok üstünde (saniyeler), aynı anda işlenen istek tepesi
onlarca. Boş havuz sayısı sıfır da olabilir: yeni bağlantı kurmak da gecikmeli ağda bekler. 4. adımda iki turun
`5xx` ve `p99` değerlerini yan yana koy.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl02&from=now-15m&to=now&refresh=10s) ve [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl02&from=now-15m&to=now&refresh=10s) — yük başlayınca aç; 60 sn sürer
- "Sorgu süresi p99 (türe göre)" → bütün sorgular ~2 sn'nin üstüne sıçrar: eklenen gecikme.
- "Uygulama havuzu: boş bağlantı bulunamadı / sn" → havuz dolduğu anlarda sıfırdan kalkar.
- "Uygulama havuzu: bağlantı bekleme (p99)" → saniyelere çıkar (tavanı 3 sn): istek sorgusuna başlamadan havuzdan bağlantı bekliyor.
- "İstek / saniye (durum koduna göre)" → `503` belirir; "Gecikme (p50 / p95 / p99)" aynı anda saniyelere fırlar.
- "Şu an işlenen istek (pod'a göre)" → her pod'da bekleyen istek birikir (bu dashboard'un diğer panelleri 10'da dolar).

**Nasıl çözülüyor:** Bu seviyede veritabanı tarafı zaman aşımı (`STATEMENT_TIMEOUT`) işi gerçekten durdurur; 10'da devre kesici (circuit breaker) yavaş bağımlılığa iş göndermeyi bir süre bırakır.

---

### P02-07 · TRAP · Migration'ı her pod kendi açılışında koşarsa

**Ne oluyor:** Şema değişikliğini (migration — tabloya indeks eklemek gibi) her pod açılışta kendisi uygularsa,
aynı anda açılan pod'lar aynı işe girişir. Bazıları `deadlock detected` ile çöküp yeniden başlar; kötü turlarda aynı
değişiklik iki kez kaydedilir ya da yarım kalmış (geçersiz) bir indeks "uygulandı" diye kalır.
**Neden oluyor:** Migration tek seferlik bir iştir, ama bu kurulumda onu yapan araç (goose) kilit almaz; her pod işi
kendisinin yapması gerektiğini sanır. Aynı tabloda aynı değişikliği aynı anda yapmaya çalışan pod'lar birbirini
kilitler.
**Bu deney:** Tuzak ayarını (`TRAP_MIGRATE_IN_MAIN`) açar, tabloyu ~2 milyon satıra büyütür (iş uzun sürsün diye),
üç pod'u aynı anda açar; restart'ları, şema kaydını, indeksin geçerliliğini ve pod loglarını okur, sonunda her şeyi
geri alır.

**Reproduce (adım adım):** Otomatik: `make repro P=P02-07` (tabloyu ~2 M satıra büyütür, uygulamayı 0'a indirip
`TRAP_MIGRATE_IN_MAIN=true` + `MIGRATE_TARGET=2` ile üç pod'u aynı anda açar; hükmü DB kaydından ve pod loglarından
verir, sonunda şemayı geri alır; şema zaten 002'deyse ölçmeden çıkar). Elle:

1. Temiz başla; şema hangi sürümde? (`2` çıkarsa önce 7. adımdaki `psql` komutuyla geri al — yapacak iş yoksa yarış
   da olmaz):
```bash
cd "$LADDER/02-postgres"
make fresh
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -tAc 'SELECT max(version_id) FROM goose_db_version WHERE is_applied'
```
2. Tabloyu ~2 M satıra büyüt (migration pod'ların açılış farkından uzun sürsün), indeksi bir kez kurup silerek yarış
   penceresini ölç:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c "INSERT INTO links (code, url, tenant, created_at) SELECT 'p7-' || i, 'https://example.com/p0207/' || i, 'p02-07-bulk', now() - (i || ' seconds')::interval FROM generate_series(1, 2000000) i ON CONFLICT DO NOTHING"
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c '\timing on' -c 'CREATE INDEX CONCURRENTLY IF NOT EXISTS p0207_probe_idx ON links (tenant, created_at DESC)' -c 'DROP INDEX CONCURRENTLY IF EXISTS p0207_probe_idx'
```
3. Uygulamayı 0'a indir (rolling update işi tek pod'a yaptırıp yarışı gizlerdi), pod'lar gidince tuzağı doğrudan
   `kubectl set env` ile aç (`make set` hazır pod bekler):
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 scale deploy/linkly --replicas=0
kubectl -n lvl02 wait --for=delete pod -l app.kubernetes.io/name=linkly --timeout=90s
kubectl -n lvl02 set env deploy/linkly TRAP_MIGRATE_IN_MAIN=true MIGRATE_TARGET=2
```
4. İkinci bir terminalde migration oturumlarını örnekle (her satır `kilit bekleyen|koşan`; ~30 sn):
```bash
cd "$LADDER/02-postgres"
for i in $(seq 1 60); do kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -tAc "SELECT count(*) FILTER (WHERE wait_event_type = 'Lock'), count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' AND query ILIKE '%links_tenant_created_idx%'"; sleep 0.3; done
```
5. Hemen ardından ilk terminalde üç pod'u aynı anda aç:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 scale deploy/linkly --replicas=3
kubectl -n lvl02 rollout status deploy/linkly --timeout=180s
```
6. Kanıtı oku: restart'lar, 002'nin kaç kez kaydedildiği, indeksin geçerliliği, çöken pod'ların logu ve işi "kendisi
   yaptığını" sanan pod'lar:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 get pods -l app.kubernetes.io/name=linkly
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c 'SELECT version_id, count(*) FROM goose_db_version GROUP BY 1 ORDER BY 1'
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c "SELECT c.relname, i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = 'links_tenant_created_idx'"
for p in $(kubectl -n lvl02 get pods -l app.kubernetes.io/name=linkly -o name); do kubectl -n lvl02 logs "$p" --previous 2>/dev/null | grep 'migration başarısız'; done
kubectl -n lvl02 logs -l app.kubernetes.io/name=linkly --prefix --tail=300 | grep 'migration bitti'
```
7. Geri al: tuzağı kapat, sonra şemayı ve eklenen satırları geri al (P02-05 indekssiz tablo ister):
```bash
cd "$LADDER/02-postgres"
make reset
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -c 'DROP INDEX CONCURRENTLY IF EXISTS p0207_probe_idx' -c 'DROP INDEX CONCURRENTLY IF EXISTS links_tenant_created_idx' -c 'DELETE FROM goose_db_version WHERE version_id >= 2' -c "DELETE FROM links WHERE tenant = 'p02-07-bulk'"
```

**Terminalde ne görmelisin:** 1. adımda `1`. 2. adımda `INSERT 0 2000000` ve `CREATE INDEX`'in `Time: … ms`'i: yarış
penceresi. İkinci terminalde çoğu satır `0|0`; pod'lar açılırken ikinci sütun 1'den büyük (aynı anda birden çok
migration), birinci sütun sıfırdan büyük (kilit bekleyen). 6. adımda bazı pod'larda `RESTARTS 1` ve logda `migration
başarısız … deadlock detected`; kötü turlarda `version_id = 2` birden çok kez ya da `indisvalid` `f`; `"from":1,"to":2`
diyen birden çok `migration bitti` — her biri işi kendisinin yaptığını sanıyor. Hiçbiri yoksa pencere çakışmadı: 7.
adımla geri al, 2. adımdaki `2000000`'u büyütüp tekrar dene.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl02&from=now-15m&to=now&refresh=10s) ve [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now&refresh=10s) — tuzağı açınca aç; tablo doldurma 1–2 dk, açılış ~1 dk
- "Yeniden başlatma sayısı" → yalnızca migration'ı çakışan pod'ların çizgisi basamak atlar; pencere çakışmazsa basamak yok.
- "Hazır pod adresi (endpoint) sayısı" → `linkly` 0'a iner, pod'lar migration'ı bitirdikçe tek tek döner; düşüp yeniden başlayan en son.
- "Kilitler (türe göre)" → indeks kurulurken `shareupdateexclusivelock` belirebilir (iş kısa sürerse ölçüme denk gelmez; kanıt terminalde).

**Nasıl çözülüyor:** Bu seviyenin kendi tuzağı: varsayılan kurulumda migration tek seferlik ayrı bir iş (Kubernetes Job, `deploy/migrate-job.yaml`) olarak koşar, uygulama yalnızca şemanın hazır olmasını bekler. Geri almada şemanın geri gelmemesi sorunu 12'de (expand/contract).

---

### P02-08 · Sıcak link → satır kilidi kuyruğu

**Ne oluyor:** Trafiğin büyük kısmı tek bir linke gittiğinde (viral bir link) o link en yavaş link olur.
Popülerlik, performans cezasına dönüşür.
**Neden oluyor:** Her yönlendirme aynı veritabanı satırındaki tıklama sayısını artırır (`clicks = clicks + 1`).
Postgres aynı satıra yapılan güncellemeleri sıraya koyar (satır kilidi): her yönlendirme öncekinin bitmesini
bekler. Her güncelleme ayrıca yeni bir satır sürümü yazar, ölü satırlar birikir.
**Bu deney:** Önce trafiği linklere dağıtarak 60 kullanıcıyla 40 sn yük verir, sonra trafiğin %90'ını tek linke
yöneltip aynı yükü verir; iki fazın yönlendirme süresini, sorgu türlerinin süresini ve ölü satırları karşılaştırır.

**Reproduce (adım adım):** Otomatik: `make repro P=P02-08` (önce dağıtık yük, sonra %90'ı tek linke giden yük;
`increment_clicks` ile `get` p99'unu karşılaştırır, ölü satırları okur). Elle:

1. Temiz başla; referans: trafik linklere dağılmışken 60 kullanıcıyla 40 sn yük, sonra yönlendirme p99'u (saniye):
```bash
cd "$LADDER/02-postgres"
make fresh
make load S=mixed K6_ARGS="--vus 60 --duration 40s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl02",route="/{code}"}[1m])) by (le))' | jq -r '.data.result[0].value[1]'
```
2. Aynı yük, ama trafiğin %90'ı tek linke; sonra yönlendirme p99'u, türe göre sorgu p99'u ve ölü satırlar:
```bash
cd "$LADDER/02-postgres"
HOT_SHARE=0.9 make load S=hot-key K6_ARGS="--vus 60 --duration 40s"
sleep 12
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="lvl02",route="/{code}"}[1m])) by (le))' | jq -r '.data.result[0].value[1]'
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=histogram_quantile(0.99, sum by (le, op) (rate(db_query_duration_seconds_bucket{namespace="lvl02",op=~"get|increment_clicks"}[1m])))' | jq -r '.data.result[] | "\(.metric.op) \(.value[1])"'
kubectl -n lvl02 exec postgres-0 -c postgres -- psql -U linkly -d linkly -tAc "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname = 'links'"
```

**Terminalde ne görmelisin:** 2. adımın yönlendirme p99'u 1. adımdakinden büyük: en popüler link en yavaş link.
`increment_clicks` p99'u `get`'in üstünde: aradaki fark kilit bekleme. Ölü satır sayısı sıfırdan büyük.

**Grafana'da gör:** [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl02&from=now-15m&to=now&refresh=10s) — deney başlayınca aç; iki faz 40'ar sn
- "Sorgu süresi p99 (türe göre)" → dağıtık fazda `increment_clicks` ile `get` yakın; sıcak link fazında `increment_clicks` üste ayrışır: aradaki açıklık kilidin bedeli.
- "Kilitler (türe göre)" → sıcak link fazında kilit çizgileri yükselir.
- "Ölü satırlar (vacuum bekleyen)" → `links` tırmanır, autovacuum geçtikçe testere dişi gibi düşer.
- "p99 süre (uç noktaya göre)" → `/{code}` sıcak link fazında yükselir.

**Nasıl çözülüyor:** 05'te tıklama istek yolundan çıkar: bir kuyruğa atılır ve arka planda toplu yazılır, aynı satıra her tıklamada gidilmez; 06'da dayanıklı bir olay akışına yazılır.

---

### P02-09 · Sır düz metin: git'te, Secret'ta, env'de

**Ne oluyor:** Veritabanı parolası, repoyu klonlayan ya da kümede Secret okuyabilen herkes tarafından tek komutla
okunabilir.
**Neden oluyor:** Parola repodaki manifest'te düz metin. Kubernetes Secret'ı şifrelemez, yalnızca base64 ile kodlar
(herkes çözebilir). Parola ayrıca pod'un ortam değişkenlerinde açıkça durur.
**Bu deney:** Salt okuma: repoda parolayı arar, kümedeki Secret'ı okuyup base64'ü çözer, parolanın uygulamaya nasıl
girdiğine ve varsayılan servis hesabının Secret okuyup okuyamadığına bakar.

**Reproduce (adım adım):** Otomatik: `make repro P=P02-09` (dört yerden okumayı dener: git, Secret, deployment env,
RBAC; ölçülen: `git: evet · kubectl get secret → base64 → 'linkly'`). Elle (salt okuma):

1. Temiz başla; repodaki manifest'te parola ara:
```bash
cd "$LADDER/02-postgres"
make fresh
grep -n 'POSTGRES_PASSWORD\|linkly:linkly@' deploy/postgres.yaml
```
2. Kümedeki Secret'ı oku, base64'ü çöz:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 get secret postgres -o jsonpath='{.data.POSTGRES_PASSWORD}'; echo
kubectl -n lvl02 get secret postgres -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
kubectl -n lvl02 get secret postgres -o jsonpath='{.data.DATABASE_URL}' | base64 -d; echo
```
3. Parola uygulamaya nasıl giriyor ve varsayılan servis hesabı Secret okuyabiliyor mu:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 get deploy linkly -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].secretRef.name}'; echo
kubectl -n lvl02 auth can-i get secrets --as=system:serviceaccount:lvl02:default
```

**Terminalde ne görmelisin:** `grep` üç satır bulur (`POSTGRES_PASSWORD: linkly`, `DATABASE_URL: postgres://linkly:linkly@…`
ve exporter'ın bağlantı dizesi): repoyu klonlayan herkes görür. Secret'ta `bGlua2x5` → `base64 -d` → `linkly`: base64
şifreleme değil. `envFrom` `postgres`: parola sürecin ortamında. `auth can-i` → `no` (iyi), ama Secret okuma yetkisi
olan herkes parolaya tek komutla ulaşır.

**Grafana'da gör:** Grafana'da görünmez — parola bir metrik değil, bir dosya ve bir nesne; sızıntı hiçbir sayaçta iz bırakmaz. Kanıt terminalde:
- `kubectl -n lvl02 get secret postgres -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d` → `linkly`
- `make repro P=P02-09` → dört yeri tek seferde dener ve `parola düz metin olarak erişilebilir` der.

**Nasıl çözülüyor:** 13'te kısmen: ağ kuralları (NetworkPolicy) veritabanına yalnızca izin verilen pod'ların bağlanmasını sağlar ve şifreli sır aracı (sealed-secrets) kurulu olur; sırlar yine de git'te düz metin kalır (P13-04).

---

### P02-10 · TRAP · Readiness'ın bağımlılığı kontrol etmesi

**Ne oluyor:** Veritabanı kısa bir süre gidince uygulamanın bütün kopyaları aynı anda trafikten çıkar ve servis
tamamen kesilir; kullanıcılar ingress'ten 503 alır. Kısmi bir arıza (yalnızca veritabanı) tam kesintiye döner;
veritabanı dönünce bütün kopyalar birlikte geri gelip onu ikinci kez zorlar.
**Neden oluyor:** Kubernetes her pod'a "trafik almaya hazır mısın?" diye sorar (readiness probe). Tuzakta pod bu
soruyu "veritabanına ulaşabiliyor muyum?" diye cevaplar; veritabanı gidince bütün kopyalar aynı anda "hayır" der ve
Kubernetes hepsini trafikten çıkarır.
**Bu deney:** Tuzağı (`TRAP_READYZ_CHECKS_DB`) açar, yük altında veritabanı pod'unu siler ve hazır pod sayısını 2
sn'de bir basar; aynı arızanın tuzak kapalıyken nasıl göründüğünü P02-03 gösterir.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P02-10` (`TRAP_READYZ_CHECKS_DB=true` açar, yük altında
Postgres'i siler, hazır pod sayısını 2 sn'de bir izler, tuzağı kapatır; P02-03 ile karşılaştır). Elle:

1. Temiz başla; tuzağı aç (pod'lar yeniden başlar), hazır pod adreslerine bak:
```bash
cd "$LADDER/02-postgres"
make fresh
make set E="TRAP_READYZ_CHECKS_DB=true"
sleep 10
kubectl -n lvl02 get endpointslice -l kubernetes.io/service-name=linkly
```
2. İkinci bir terminalde yükü başlat:
```bash
cd "$LADDER/02-postgres"
make load S=redirect K6_ARGS="--vus 5 --duration 100s"
```
3. ~10 sn sonra ilk terminalde tek veritabanı pod'unu sil (yıkıcı; veri diskte kalır) ve 80 sn boyunca 2 sn'de bir
   hazır pod sayısını bas:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 delete pod postgres-0 --wait=false
for i in $(seq 1 40); do printf '%s ' "$(kubectl -n lvl02 get endpointslice -l kubernetes.io/service-name=linkly -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' | grep -c true)"; sleep 2; done; echo
```
4. Geri al: DB'nin döndüğünü doğrula, tuzağı kapat:
```bash
cd "$LADDER/02-postgres"
kubectl -n lvl02 rollout status statefulset/postgres --timeout=180s
make reset
```

**Terminalde ne görmelisin:** 1. adımda üç adres. 3. adımdaki dizi `3 3 …` başlar, DB gidince `0`'a iner ve DB yokken
`0 0 0 …` kalır, DB dönünce üçü birlikte `3`'e çıkar. k6 özetinde `5xx` > 0 — bu kez `503`'ü ingress veriyor, gönderecek
hazır pod yok. P02-03'te aynı arızada sayı 3'te kalmıştı.

**Grafana'da gör:** [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl02&from=now-15m&to=now&refresh=10s), [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl02&from=now-15m&to=now&refresh=10s) ve [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl02&from=now-15m&to=now&refresh=10s) — Postgres silinince aç; yük 100 sn sürer
- "Hazır pod adresi (endpoint) sayısı" → `linkly` 3'ten **0'a** iner ve DB yokken 0'da kalır (P02-03'te 3'te düz).
- "İstek / saniye (durum koduna göre)" → kısa bir `503` tepesinden sonra uygulamanın gördüğü istek neredeyse sıfıra iner: 503'leri artık ingress veriyor.
- "Dönen durum kodları" → kesinti boyunca `503` `302`'nin yerini alır: istemci kesintiyi eksiksiz görüyor.

**Nasıl çözülüyor:** Bu seviyenin kendi tuzağı: varsayılan kurulumda hazır olma kontrolü yalnızca pod'un kendisine bakar ("ben hazır mıyım?"). Bağımlılığın durumu bir metriktir; ona tepkiyi devre kesici ya da kısıtlı çalışma (degrade mod) verir (10).

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_MIGRATE_IN_MAIN` | Migration'ı her pod açılışta koşar | `make repro P=P02-07` | Bayrağı kapat; tek seferlik Job |
| `TRAP_READYZ_CHECKS_DB` | `/readyz` DB'ye ping atar | `CONFIRM=1 make repro P=P02-10` | Bayrağı kapat; readiness sadece kendi durumu |
| `TRAP_METRIC_LABEL_CODE` | (01'den devam) kısa kod label olur | `make repro P=P01-06` (01'de) | Tekil kimlik log/trace'e |
| `TRAP_LIVENESS_STRICT` | (01'den devam) sağlık uçları iş zincirinde | `make repro P=P01-07` (01'de) | Zincirin dışında tut |

Elle denemeye değer:
- `make set E="STATEMENT_TIMEOUT=2s"` ile P02-06'yı tekrar koş: sunucu tarafı timeout'un farkı.
- `make set E="DB_MAX_CONNS=5"` + `make load S=mixed`: havuzu küçültmek P02-02'yi çözmez, kuyruğu uygulamaya taşır.
- `make load S=read-your-writes`: burada temiz geçer (tek DB); 09'daki farkı görmek için sonucu not et.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`05 · Postgres`](http://grafana.localtest.me/d/ladder-postgres?var-level=lvl02&from=now-15m&to=now) | **Dolu** | postgres-exporter (DB'nin gördüğü) + uygulamanın `db_*` metrikleri (isteğin gördüğü) |
| [`00 · Overview`](http://grafana.localtest.me/d/ladder-overview?var-level=lvl02&from=now-15m&to=now) · [`01 · Pods & Resources`](http://grafana.localtest.me/d/ladder-pods?var-level=lvl02&from=now-15m&to=now) · [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl02&from=now-15m&to=now) · [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl02&from=now-15m&to=now) · [`15 · k6`](http://grafana.localtest.me/d/ladder-k6?var-level=lvl02&from=now-15m&to=now) | Dolu | 3 uygulama pod'u + 1 DB |
| [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl02&from=now-15m&to=now) | Dolu | Hâlâ süreç içi (P02-04) |
| [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl02&from=now-15m&to=now) | Kısmen | Güvensiz URL reddi dolu; kimlik yok (13) |
| Diğerleri (04, 06–09, 11–13) | Boş | Önbellek, Redis, kuyruk, ölçekleyici, SLO, rollout yok |

Havuz beklemesi (`db_pool_acquire_duration_seconds`) bağlantı almanın süresi; sorgu süresi (`db_query_duration_seconds`)
bekleme + sorgu. İkisi birlikte yükselirse havuz tıkanıyor; aradaki fark sorgunun DB'de geçirdiği süre.

## 9. Bilerek bırakılanlar

- Postgres tek kopya; operatör, yedek, zamana geri dönüş yok (P02-03 → 09).
- `max_connections=100` ve pod başına 25'lik havuz (P02-02 → 09).
- `STATEMENT_TIMEOUT` boş (P02-06).
- Kiracı indeksi (`migrations/002`) var ama varsayılanda uygulanmıyor (P02-05).
- Tıklama sayacı senkron ve istek yolunda (P02-08 → 05).
- Hız sınırı süreç içi (P02-04 → 08); sırlar düz metin (P02-09 → 13); `X-Tenant-ID` kimlik değil (13).
- Önbellek yok: her okuma DB'ye (P02-01 → 03/04).

## 10. `make diff-prev` okuma rehberi

1. `internal/store/`: `memory.go` gitti; `store.go` (arayüz) + `postgres.go` geldi. Arayüz neredeyse değişmedi:
   `CreateUnique` doğrudan SQL `ON CONFLICT DO NOTHING`'e oturdu.
2. `internal/httpapi/handlers.go`: her handler süre sınırlı bir `context` taşıyor; `handleRedirect`'teki SELECT +
   UPDATE bu seviyenin sorunlarının kaynağı.
3. `cmd/migrate/` (yeni): şema değişikliği ayrı bir program ve ayrı bir Job.
4. `deploy/postgres.yaml` (yeni): tek replikalı StatefulSet; `deploy/deployment.yaml`: `replicas: 3`, düğümlere yayma,
   `envFrom: secretRef`, PDB `minAvailable: 2`.
5. `internal/metrics/metrics.go`: `links_total` kalktı (pod başına anlamsızdı), havuz metrikleri eklendi.
