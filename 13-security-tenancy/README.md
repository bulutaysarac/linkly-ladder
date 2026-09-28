# 13 — security-tenancy · "Kim, neye, ne kadar"

> **Bu seviyede ne yaşayacaksın?**
> - Kiracının başlıktan değil hash'lenmiş bir API anahtarından gelmesi; tuzak: `X-Tenant-ID` başlığıyla başka kiracı olmak (P13-01)
> - Unutulan bir tenant filtresinin sessiz sızıntısı ve Postgres RLS'nin bunu veritabanında durdurması (P13-02)
> - Varsayılan-reddet ağ: yetkisiz pod veritabanına ulaşamaz (P13-03); sırlar hâlâ git'te düz metin (P13-04)
> - Tuzak: iç adrese çözülen bir alan adının kısaltılması (P13-05); link kodlarını taramanın maliyeti (P13-06)
> - README'deki kuralın Kyverno ile kapıya dönüşmesi (P13-07); konteyner ve tedarik zinciri sertleştirme (P13-08)
>
> **Bu seviye olmasa ne olur?** `X-Tenant-ID` yazan herkes başka kiracı olur, unutulan bir filtre bütün kiracıların verisini sızdırır ve kümedeki herhangi bir pod veritabanına bağlanabilir.
>
> **Yeni gelen teknolojiler:** API anahtarı (sha256, sabit zamanlı karşılaştırma), Postgres RLS, NetworkPolicy (Calico), Kyverno, sealed-secrets, cert-manager, `14 · Security` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Kiracı artık hash'lenmiş bir API anahtarından gelir; `X-Tenant-ID` yok sayılır. Veritabanı kiracı sınırını kendisi
de bilir (RLS), ağ varsayılan olarak kapalıdır ve merdivenin README'de yazan kuralları admission politikasına
(Kyverno) taşınır.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) -->|"Authorization: Bearer"| I[ingress]
  I --> RL["hız sınırı (IP)<br/>ucuz kontrol"]
  RL --> AU["kimlik doğrulama<br/>sha256 + sabit zaman"]
  AU --> BIZ["iş mantığı<br/>tenant = kimlikten"]
  BIZ --> PG[("postgres<br/>RLS: app.tenant_id")]
  KY["Kyverno<br/>admission"] -.->|":latest · limit · probe"| BIZ
  NP["NetworkPolicy<br/>varsayılan reddet"] -.-> PG
```

Sıra bilinçli: ucuz kontrol (IP limiti) önce, pahalı olan (hash + arama) sonra; kimliksiz bir sel hash maliyeti
ödetmeden reddedilir.

## 3. Önceki seviyeden çözülenler

**Hiçbiri** — `problems/SOLVES` gerekçesini yazar. 12'nin sorunlarından P12-04 (`:latest` etiketi) bir
doğrulamadır ve 12'de de "sorun yok" (`NOT-REPRODUCED`) döner; hiç yaşanmamış bir sorunu "çözüldü" diye listelemek
bir şey kanıtlamaz.

Bu seviyede kapanan borçlar: `:latest`, eksik bellek sınırı ve eksik sağlık kontrolü (probe) kuralları kümeye giriş
kapısında zorunlu (Kyverno, P13-07) — README'de yazan bir kural temennidir, giriş kapısındaki kural garantidir. Kiracıyı
başlıkla taklit etmek biter (kiracı API anahtarından gelir), zararlı URL kontrolü alan adının çözüldüğü adrese de bakar
(P13-05), düz metin sırlar kısmen ele alınır (P13-04).

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG, Argo CD + Argo Rollouts, cert-manager + Kyverno**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/13-security-tenancy"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
make link          # example.com'a kısa link oluştur, yönlendirmeyi dene → 302 · API anahtarını kümeden kendisi okur · başka adres: make link URL=https://…
make grafana       # Ladder klasörü, level=lvl13 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P13-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

**API anahtarı:** 13'ten itibaren yönetim uçları (`/api/...`) `Authorization: Bearer <anahtar>` ister: acme
`acme-key-9f2c`, globex `globex-key-3a71` (hepsi `deploy/api-keys.yaml`'da). `GET /{code}` anahtarsızdır — kısa
linke tıklayanın anahtarı olmaz.

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvl13 ayakta` yazar:
```bash
cd "$LADDER/12-delivery"
make down
cd "$LADDER/13-security-tenancy"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/13-security-tenancy"
make up
```
2. 12'nin sorunlarını burada koş (~15 dk; koşarken başka komut çalıştırma). 13, 12'nin hiçbir sorununu çözdüğünü
   iddia etmez: `BEKLENEN` sütununda her satır `(açık kalabilir)`. Bu adım, 12'nin scriptlerinin kimlik doğrulamalı
   ortamda da koştuğunu gösterir (anahtarı kümeden okurlar):
```bash
cd "$LADDER/13-security-tenancy"
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P13-01 → P13-08): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç.
4. Bitince ayarları geri al ve seviyeyi kapat. `make down` Kyverno `ClusterPolicy`'sini silmez; kapsamı yalnızca
   `lvl13` olduğu için başka seviyeye dokunmaz (P13-07):
```bash
cd "$LADDER/13-security-tenancy"
make reset
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyenin değişikliği: **`Authorization: Bearer <anahtar>`**.

| Uç | Kimlik |
|---|---|
| `GET /{code}` | **Public** (anahtar varsa kiracı/tier çözülür) |
| `POST/GET/DELETE /api/links*` | **Zorunlu** → yoksa `401` + `WWW-Authenticate` |

`X-Tenant-ID` yok sayılır. `401` = "kim olduğunu bilmiyorum", `403` = "biliyorum ama yetkin yok". Bu seviyede `403`
üreten yol yok: rol kavramı yok ve başka kiracının linki, varlığını sızdırmamak için `404` döner.

## 6. Reproduce edilebilir sorunlar

Bu seviyede yaşayacağın 8 sorun. Her birini iki yoldan görebilirsin: **Otomatik** — `make repro P=<ID>` deneyi
kendisi yapar, ölçer ve hükmünü basar (`REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` =
ölçülemedi); **Elle** — adımları sırayla yapıştırıp sonucu kendi gözünle görürsün. Her sorunun bölümü aynı
düzende: **Ne oluyor** → **Neden oluyor** → **Bu deney** → adımlar → **Terminalde ne görmelisin** →
**Grafana'da gör** (giriş: admin / ladder) → **Nasıl çözülüyor**.

**Kısa komut** deneyi otomatik başlatır; seviyenin klasöründe çalıştır (önce `cd "$LADDER/13-security-tenancy"`).

| ID | Kısa komut | Ne olur? | Neden olur? | Nasıl çözülür? |
|---|---|---|---|---|
| P13-01 | `make repro P=P13-01` | Anahtarı olmayan biri, isteğine `X-Tenant-ID: acme` başlığını yazarak başka bir kiracının (acme) linkini silebilir | Kiracı kimliği herkesin yazabileceği bir başlıktan okunuyor (bu seviyede yalnızca `TRAP_HEADER_TENANT` tuzağı açıkken) | **13:** kiracı yalnızca gizli API anahtarından çıkarılır, başlık yok sayılır |
| P13-02 | `make repro P=P13-02` | Bir sorguda "yalnızca bu kiracı" filtresi unutulursa sorgu bütün kiracıların verisini döndürür; hata ya da uyarı çıkmaz | Filtreyi her sorguya uygulamanın kendisi eklemek zorunda; unutmak sessizdir | **13 (deneyde):** filtreyi veritabanı kendisi uygular (satır düzeyi güvenlik — RLS) |
| P13-03 | `make repro P=P13-03` | Ele geçirilen ya da yanlışlıkla kurulan herhangi bir pod veritabanına ve Redis'e doğrudan bağlanabilir | Kubernetes'te varsayılan olarak her pod her pod'la konuşabilir | **13:** varsayılan olarak her bağlantıyı reddeden ağ kuralı + izin listesi (NetworkPolicy) |
| P13-04 | `make repro P=P13-04` | API anahtarları ve veritabanı şifresi git'te düz metin; repoyu okuyan herkes görür | Kubernetes Secret'ı yalnızca base64 ile kodlar (şifreleme değil); sırları şifreleyen araç kurulu ama kullanılmıyor | **Kısmen:** sealed-secrets (sırrı şifreleyip git'e koyma) hazır; kullanımı 14 §9'da |
| P13-05 | `make repro P=P13-05` | İç ağ adresine çözülen bir alan adı (ör. `localtest.me` → 127.0.0.1) kısaltılabilir; tıklayan iç ağa yönlendirilir | Kontrol yalnızca yazılan IP'ye bakar, alan adının hangi IP'ye çözüldüğüne bakmaz (bu seviyede yalnızca `TRAP_NO_DNS_CHECK` açıkken) | **13:** alan adı DNS'ten çözülür, iç adrese çıkıyorsa reddedilir |
| P13-06 | `make repro P=P13-06` | Var olmayan kodları arka arkaya deneyen biri (tarama) sisteme yük bindirir ve normal trafik içinde zor fark edilir | Her deneme bir 404 ve çoğu zaman bir veritabanı okuması; 404 oranına bakan bir kural yok | **Kısmen:** uzun rastgele kod (01), "bu kod yok" önbelleği (03), hız sınırı (08) |
| P13-07 | `make repro P=P13-07` | `:latest` etiketli, bellek sınırı ya da sağlık kontrolü (probe) olmayan bir pod kümeye kurulabilir | Bu kurallar yalnızca README'de yazıyor; Kubernetes böyle pod'ları kendiliğinden reddetmez | **13:** Kyverno kuralları kümeye giriş kapısında zorunlu kılar |
| P13-08 | `make repro P=P13-08` | Konteyner ele geçirilirse imajdaki shell, root yetkisi ve yazılabilir dosya sistemi saldırgana alan açar | Kodun güvenliği, çalıştığı imajın güvenliğiyle sınırlı | **Kısmen (13):** shell'siz imaj, root olmayan kullanıcı, yetkiler kapalı; imaj tarama ve imza 14 §9'da |

---

### P13-01 · TRAP · Header ile kiracı taklidi

**Ne oluyor:** Anahtarı olmayan biri, isteğine `X-Tenant-ID: acme` başlığını yazarak kendini acme kiracısı gibi
gösterir ve acme'nin linkini silebilir. Başlığı herkes yazabildiği için bu, kiracılar arasında hiç sınır olmaması demek.
**Neden oluyor:** Bu seviyede kiracı kimliği gizli API anahtarından çıkarılır ve başlık yok sayılır. Tuzak
(`TRAP_HEADER_TENANT`) açıkken kiracı yine başlıktan okunur: kimlik doğrulama kodu yerinde durur, değişen yalnızca
kararın neye dayandığıdır.
**Bu deney:** acme'nin anahtarıyla bir link oluşturur; globex'in anahtarı + acme başlığıyla ve hiç kimlik olmadan
silmeyi dener, sonra tuzağı açıp linki yalnızca başlıkla siler.

**Reproduce (adım adım):** Otomatik: `make repro P=P13-01` (acme'nin anahtarıyla link oluşturur; globex anahtarı +
başlıkla ve kimliksiz silmeyi dener; sonra tuzağı yalnızca api'de açıp yalnızca başlıkla siler ve tuzağı kapatır). Elle:

1. Temiz başla; acme kendi anahtarıyla bir link oluştursun:
```bash
cd "$LADDER/13-security-tenancy"
make fresh
code=$(curl -s -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/acme-gizli"}' | jq -r .code); echo "acme'nin kodu: $code"
```
2. globex kendi anahtarıyla ama `X-Tenant-ID: acme` diyerek silmeyi denesin; sonra hiç kimlik göndermeden:
```bash
cd "$LADDER/13-security-tenancy"
curl -s -w ' → %{http_code}\n' -XDELETE http://lvl13.localtest.me/api/links/$code -H 'Authorization: Bearer globex-key-3a71' -H 'X-Tenant-ID: acme'
curl -s -w ' → %{http_code}\n' -XDELETE http://lvl13.localtest.me/api/links/$code
```
3. Tuzağı yalnızca api'de aç (api pod'ları yeniden başlar), yalnızca başlıkla sil, sonra acme kendi linkine baksın:
```bash
cd "$LADDER/13-security-tenancy"
make set E="TRAP_HEADER_TENANT=true" W=api
kubectl -n lvl13 rollout status deploy/api
sleep 10
curl -s -w ' → %{http_code}\n' -XDELETE http://lvl13.localtest.me/api/links/$code -H 'X-Tenant-ID: acme'
curl -s -o /dev/null -w 'acme kendi linkine bakıyor: %{http_code}\n' http://lvl13.localtest.me/api/links/$code -H 'Authorization: Bearer acme-key-9f2c'
```
4. Tuzağı kapat (api pod'ları manifestteki ortamla yeniden başlar):
```bash
cd "$LADDER/13-security-tenancy"
make reset
```

**Terminalde ne görmelisin:** her `curl` önce JSON gövdeyi, altında ` → <HTTP kodu>` basar. 2. adımda
`{"error":"not_found",…}` ve `→ 404` (globex için acme'nin linki yok: başlık yok sayıldı); kimliksiz denemede
`{"error":"missing_credentials",…}` ve `→ 401`. 3. adımda `✔ deploy/api: TRAP_HEADER_TENANT=true`, ardından gövdesiz
` → 204`: anahtarsız biri yalnızca başlıkla acme'nin linkini sildi. Son satır `acme kendi linkine bakıyor: 404` —
link gerçekten gitti.

**Grafana'da gör:** [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl13&from=now-15m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl13&from=now-15m&to=now&refresh=10s) — deneyden sonra aç; tek tek `curl` istekleri olduğu için tepeler küçük
- "Kimlik reddi / sn (401 / 403)" → kimliksiz denemeden kısa, alçak bir `401` tepesi; `403` çizgisi çıkmaz (bu seviyede `403` üreten yol yok, §5).
- "4xx (koda göre)" → globex + başlık denemesi `404` olarak görünür: globex acme'nin linkini bulamaz.
- Tuzak açıkken başarılı taklit (`204`) hiçbir hata panelinde görünmez: sınırın delindiği an, metrikte sıradan bir başarılı silmedir.
- Explore'da: `sum by (result) (increase(auth_attempts_total{namespace="lvl13"}[5m]))` → `ok` (anahtarlı) ve `missing` (anahtarsız, public redirect'ler dahil); tuzaklı istek kimlik doğrulamaya hiç uğramaz.

**Nasıl çözülüyor:** Bu seviyede çözülü: kiracı yalnızca API anahtarından türer, `X-Tenant-ID` yok sayılır. Tuzak (`TRAP_HEADER_TENANT`) açıkken sorun döner — bir sınır, karşılaştırdığı değeri kimin ayarlayabildiği kadar güçlüdür.

---

### P13-02 · Unutulan tenant filtresi = sessiz sızıntı

**Ne oluyor:** Her kiracı yalnızca kendi linklerini görmeli. Bir sorguda "yalnızca bu kiracı" filtresi
(`WHERE tenant = …`) unutulursa sorgu bütün kiracıların satırlarını döndürür — hata, log ya da alarm olmadan. Bir
kiracının verisi sessizce başkasına sızar.
**Neden oluyor:** Filtreyi her sorguya uygulamanın kendisi eklemek zorunda ve eklemeyi unutmak hiçbir hata üretmez.
Satır düzeyi güvenlik (RLS — Row Level Security) filtreyi veritabanına taşır: sorguda kiracı ayarlı değilse veritabanı
hiç satır göstermez.
**Bu deney:** İki kiracıya link yazar, filtresiz sorguyu uygulamanın veritabanı kullanıcısıyla koşar (sızıntı), sonra
RLS'i açıp aynı sorguyu tekrarlar ve RLS altında yazmanın ne olduğuna bakar; sonunda RLS'i kapatır.

**Reproduce (adım adım):** Otomatik: `make repro P=P13-02` (iki kiracıya üçer link yazar, filtresiz sorguyu
uygulamanın rolüyle koşar, RLS'i açıp tekrarlar, RLS altında yazmanın bedelini ölçer ve RLS'i kapatır; RLS'i
migration değil bu deney açıp kapatır). Elle — sorgular primary'de `psql -U postgres` ile koşar; uygulamanın
gördüğünü görmek için başa `SET ROLE linkly` konur (süper kullanıcı RLS'i tamamen atlar):

1. Temiz başla; primary pod'u bul, iki kiracıya üçer link yaz (kiracıyı anahtar belirler), kiracı dağılımına bak:
```bash
cd "$LADDER/13-security-tenancy"
make fresh
kubectl -n lvl13 wait --for=condition=Ready pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary --timeout=180s
prim=$(kubectl -n lvl13 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}'); echo "primary: $prim"
for i in 1 2 3; do curl -s -o /dev/null -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/rls"}'; done
for i in 1 2 3; do curl -s -o /dev/null -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer globex-key-3a71' -d '{"url":"https://example.com/rls"}'; done
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "SELECT tenant, count(*) FROM links GROUP BY tenant ORDER BY tenant"
```
2. Unutulmuş filtre: filtresiz sorguyu uygulamanın rolüyle koş:
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "SET ROLE linkly; SELECT count(*) FROM links"
```
3. RLS'i aç (`007_rls.sql`'in üç komutu) ve `FORCE`'un yerinde olduğunu doğrula. Bu adımdan 5. adıma kadar link
   oluşturma reddedilir (uygulama `app.tenant_id` ayarlamıyor); 5. adımı atlama:
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "ALTER TABLE links ENABLE ROW LEVEL SECURITY"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "CREATE POLICY links_tenant_isolation ON links USING (tenant = current_setting('app.tenant_id', true))"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "ALTER TABLE links FORCE ROW LEVEL SECURITY"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "SELECT relforcerowsecurity FROM pg_class WHERE relname='links'"
```
4. Aynı sorguyu RLS altında koş: ayarsız, acme olarak, globex olarak, süper kullanıcıyla; sonra uygulamadan üç yazma dene:
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "SET ROLE linkly; SELECT count(*) FROM links"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "SET ROLE linkly; SET app.tenant_id = 'acme'; SELECT count(*) FROM links"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "SET ROLE linkly; SET app.tenant_id = 'globex'; SELECT count(*) FROM links"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "SELECT count(*) FROM links"
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} ' -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/cost"}'; done; echo
```
5. RLS'i kapat: sızıntı geri döner, yazma yeniden çalışır:
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "ALTER TABLE links NO FORCE ROW LEVEL SECURITY"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "DROP POLICY IF EXISTS links_tenant_isolation ON links"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "ALTER TABLE links DISABLE ROW LEVEL SECURITY"
kubectl -n lvl13 exec "$prim" -c postgres -- psql -U postgres -d linkly -qtAc "SET ROLE linkly; SELECT count(*) FROM links"
curl -s -o /dev/null -w 'RLS kapalı, yazma: %{http_code}\n' -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/cost"}'
```

**Terminalde ne görmelisin:** 1. adımda `acme|…` ve `globex|…` (acme'ninki büyük: smoke testi ve önceki denemeler de
acme anahtarıyla yazar). 2. adımda tek sayı: ikisinin **toplamı** — filtresiz sorgu bütün kiracıları döndürdü; hata
yok, log yok. 3. adımın son komutu `t` basar (FORCE açık). 4. adımda ayarsız sorgu **`0`**, acme olarak yalnızca
acme'nin, globex olarak yalnızca globex'in sayısı, süper kullanıcıyla yine toplam; üç yazma `503 503 503` (Postgres
`42501`: yeni satır politikayı geçemedi). 5. adımda sayı yine toplam ve `RLS kapalı, yazma: 201`.

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl13&from=now-15m&to=now&refresh=10s) — deneyden sonra aç
- Sızıntının kendisi hiçbir panelde görünmez: hata, log, alarm yok; kanıt terminaldeki satır sayıları.
- "5xx (uç noktaya göre)" → RLS açıkken yapılan 3 yazma `/api/links` rotasında küçük bir tepe (Postgres `42501` → `503`): RLS'in bedeli, sızıntının tersine, gürültülüdür.
- Explore'da: `sum by (op) (increase(db_queries_total{namespace="lvl13",result="error"}[5m]))` → `create` işleminde aynı yazmalar kadar hata.

**Nasıl çözülüyor:** Bu seviyede RLS (`migrations/007_rls.sql`) sızıntıyı veritabanında durdurur; deney onu açıp kapatır, çünkü uygulama her işlemde kiracıyı (`app.tenant_id`) bildirmiyor ve RLS açıkken yazmalar reddedilir. İki kritik detay: `FORCE ROW LEVEL SECURITY` olmadan tablo sahibi politikayı atlar; bağlantı havuzunda ayar işlem başına (`SET LOCAL`) yapılmalıdır, yoksa sonraki kiracı öncekinin ayarını devralır (P09-03).

---

### P13-03 · Varsayılan-reddet ağ

**Ne oluyor:** Kubernetes'te varsayılan olarak her pod her pod'a bağlanabilir. Ele geçirilen tek bir pod — ya da
yanlışlıkla kurulan bir test pod'u — veritabanına ve Redis'e doğrudan ulaşabilir.
**Neden oluyor:** Ağ kuralı yoksa küme içi trafik serbesttir. Bu seviye "varsayılan olarak her bağlantıyı reddet"
kuralı (default-deny NetworkPolicy) ve kimin kime bağlanabileceğini sayan bir izin listesi getirir; kuralları ağ
eklentisi Calico uygular.
**Bu deney:** Tanımlı ağ kurallarını listeler, izin listesinde olmayan bir test pod'undan Postgres havuzuna ve Redis'e
bağlanmayı dener ve izinli uygulama pod'larının çalışmaya devam ettiğini doğrular.

**Reproduce (adım adım):** Otomatik: `make repro P=P13-03` (politikaları listeler, izin listesinde olmayan bir test
pod'undan Postgres havuzuna ve Redis'e bağlanmayı dener, test pod'unu siler). Elle:

1. Temiz başla; tanımlı politikalara bak:
```bash
cd "$LADDER/13-security-tenancy"
make fresh
kubectl -n lvl13 get networkpolicy
```
2. İzin listesindeki hiçbir etiketi taşımayan bir test pod'u çalıştır (bellek limiti ve readinessProbe taşır, yoksa
   Kyverno reddeder — P13-07); pod iki bağlantıyı dener ve biter:
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 delete pod netcheck --ignore-not-found
kubectl -n lvl13 run netcheck --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"netcheck","image":"busybox:1.36","command":["sh","-c","nc -z -w 3 pg-pooler-rw 5432 && echo POSTGRES_ERISILEBILIR || echo POSTGRES_ENGELLENDI; nc -z -w 3 redis 6379 && echo REDIS_ERISILEBILIR || echo REDIS_ENGELLENDI"],"resources":{"limits":{"memory":"64Mi"}},"readinessProbe":{"exec":{"command":["true"]}}}]}}'
kubectl -n lvl13 wait --for=jsonpath='{.status.phase}'=Succeeded pod/netcheck --timeout=90s
kubectl -n lvl13 logs netcheck
```
3. İzinli pod'lar (redirect) aynı veritabanıyla çalışıyor mu bak, test pod'unu sil:
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 get pod -l app.kubernetes.io/name=redirect
kubectl -n lvl13 delete pod netcheck
```

**Terminalde ne görmelisin:** 1. adımda yedi politika: `default-deny-ingress` ve izin listesi (`allow-ingress-to-services`,
`allow-metrics-scrape`, `allow-pooler-from-apps`, `allow-postgres-from-apps`, `allow-redis-from-apps`,
`allow-redpanda-from-apps`). 2. adımda `pod/netcheck condition met` (her `nc` 3 sn bekler) ve log'da
`POSTGRES_ENGELLENDI`, `REDIS_ENGELLENDI`. 3. adımda redirect pod'ları `1/1 Running`: izinli etiketle aynı havuza
bağlanıyorlar.

**Grafana'da gör:** Grafana'da görünmez — paketi Calico ağ katmanında düşürür; uygulama bunu görmez, Calico'nun metrikleri de bu kümede kazınmıyor. Kanıt terminalde:
- `kubectl -n lvl13 get networkpolicy` → `default-deny-ingress` ve izin listesi: kim kiminle konuşuyor, tek bakışta.
- `make repro P=P13-03` → yetkisiz `netcheck` pod'undan `POSTGRES_ENGELLENDI` ve `REDIS_ENGELLENDI`.

**Nasıl çözülüyor:** Bu seviyede NetworkPolicy ile: izin listesinde olmayan pod'un bağlantısı ağda düşürülür. Politika yalnızca ağ eklentisi destekliyorsa çalışır (burada Calico); dışarı giden trafik (egress) kuralları yok — pod'lar internete serbest çıkar.

---

### P13-04 · Sırlar hâlâ git'te düz metin

**Ne oluyor:** API anahtarları ve veritabanı şifresi git'te düz metin duruyor: repoyu okuyabilen herkes onları
görür. Kümedeki Secret da yalnızca base64 ile kodlanmış — bu şifreleme değil, herkes geri çevirebilir.
**Neden oluyor:** `deploy/api-keys.yaml` ve `cnpg.yaml` sırları düz metin taşır. sealed-secrets (sırrı kümenin
anahtarıyla şifreleyip git'e koymayı sağlayan araç) kurulu ama kullanılmıyor: şifreli sır o kümenin anahtarına
bağlıdır ve depo taze bir kümede kullanılamaz hâle gelir.
**Bu deney:** Yalnızca okur: git'teki düz metin sırları bulur, Secret'ın base64 olduğunu gösterir, sealed-secrets'in
kurulu olduğunu doğrular ve istersen bir sırrı şifreleyip `/tmp`'ye yazar.

**Reproduce (adım adım):** Otomatik: `make repro P=P13-04` (git'te düz metin sır arar, sealed-secrets controller'ını,
CRD'sini ve anahtarını kontrol eder, Secret'ı SealedSecret'a çeviren `kubeseal` komutunu yazar). Elle (kümede hiçbir
şeyi değiştirmez, yalnızca okur):

1. Temiz başla; git'teki düz metin sırları bul, kümedeki Secret'ın yalnızca base64 olduğunu gör:
```bash
cd "$LADDER/13-security-tenancy"
make fresh
grep -rn 'API_KEYS:\|POSTGRES_PASSWORD:\|linkly:linkly@' deploy/ | grep -v secretKeyRef
kubectl -n lvl13 get secret linkly-api-keys -o jsonpath='{.data.API_KEYS}' | base64 -d; echo
```
2. sealed-secrets kurulu mu: CRD, controller ve kümenin şifreleme anahtarı:
```bash
cd "$LADDER/13-security-tenancy"
kubectl get crd sealedsecrets.bitnami.com
kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key
```
3. İstersen çözümü dene (makinende `kubeseal` varsa; kümeye yazmaz, şifreli dosyayı `/tmp`'ye bırakır):
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 create secret generic linkly-api-keys --from-literal=API_KEYS='acme:pro:acme-key-9f2c,globex:free:globex-key-3a71,initech:enterprise:initech-key-77bd' --dry-run=client -o yaml | kubeseal --controller-namespace kube-system -o yaml > /tmp/linkly-api-keys-sealed.yaml
grep -A1 encryptedData /tmp/linkly-api-keys-sealed.yaml
```

**Terminalde ne görmelisin:** 1. adımda `API_KEYS: "acme:pro:acme-key-9f2c,…"`, `POSTGRES_PASSWORD: linkly` ve
`postgres://linkly:linkly@…` içeren satırlar: git'e commit edilmiş düz metin. `base64 -d` aynı listeyi düz basar —
base64 kodlamadır, şifreleme değil. 2. adımda CRD, `Running` controller ve `sealed-secrets-key…` adlı Secret: araç
kurulu, kullanılmıyor. 3. adımda `encryptedData:` altında okunamaz bir metin — bu dosya git'e girebilir, yalnızca bu
kümenin anahtarı çözer.

**Grafana'da gör:** Grafana'da görünmez — sır git'teki bir dosyada duruyor; hiçbir metrik bir dosyanın içeriğini ölçmez. Kanıt terminalde:
- `grep -n 'API_KEYS:\|POSTGRES_PASSWORD:' deploy/api-keys.yaml deploy/cnpg.yaml` → `API_KEYS: "acme:pro:acme-key-9f2c,…"` ve `POSTGRES_PASSWORD: linkly`: git'e commit edilmiş düz metin.
- `kubectl get crd sealedsecrets.bitnami.com` → CRD var: araç kurulu, kullanılmıyor.

**Nasıl çözülüyor:** Kısmen: sealed-secrets hazır, ama sırlar SealedSecret'a çevrilmiş değil ve pod'un ortam değişkeninde yine düz metin. Sır yönetimi bir zincirdir (git → küme → pod → süreç → log → yedek); devamı 14 §9'da.

---

### P13-05 · TRAP · DNS ile gizlenen iç adresler

**Ne oluyor:** Kısaltıcıya iç ağ adresine çözülen bir alan adı verilirse (ör. `localtest.me` → 127.0.0.1) link
kabul edilir; linke tıklayan, zararsız görünen bir adla iç ağa yönlendirilir.
**Neden oluyor:** 01'deki kontrol yalnızca düz yazılmış IP'lere bakar; saldırgan iç adrese çözülen bir alan adı
kaydederek bunu atlatır. 13 alan adını DNS'ten çözüp çıkan IP'yi kontrol eder; tuzak (`TRAP_NO_DNS_CHECK`) bu çözümü
kapatır.
**Bu deney:** Kontrol açıkken iç adres, metadata adresi, iç adrese çözülen `localtest.me` ve normal bir adresle link
oluşturmayı dener; sonra tuzağı açıp `localtest.me`'yi tekrar dener ve ret sayaçlarını okur.

**Reproduce (adım adım):** Otomatik: `make repro P=P13-05` (DNS kontrolü açıkken dört adres dener, tuzağı yalnızca
api'de açıp `localtest.me`'yi tekrar dener, ret sayacını Prometheus'tan okur ve tuzağı kapatır). Elle:

1. Temiz başla; DNS kontrolü açıkken dört hedef dene (düz özel IP, `localhost`, özel ağa çözülen ad, normal adres),
   bir kazıma bekleyip ret sayacını sebebe göre Prometheus'tan oku:
```bash
cd "$LADDER/13-security-tenancy"
make fresh
curl -s -w ' → %{http_code}\n' -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"http://169.254.169.254/latest/meta-data/"}'
curl -s -w ' → %{http_code}\n' -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"http://localhost:8080/admin"}'
curl -s -w ' → %{http_code}\n' -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"http://localtest.me/"}'
curl -s -w ' → %{http_code}\n' -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com/ok"}'
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (reason) (create_rejected_unsafe_total{namespace="lvl13"})' | jq -r '.data.result[] | .metric.reason + ": " + .value[1]'
```
2. DNS kontrolünü yalnızca api'de kapat (01'deki hâl), aynı adı tekrar dene:
```bash
cd "$LADDER/13-security-tenancy"
make set E="TRAP_NO_DNS_CHECK=true" W=api
kubectl -n lvl13 rollout status deploy/api
sleep 10
curl -s -w ' → %{http_code}\n' -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"http://localtest.me/"}'
```
3. Tuzağı kapat:
```bash
cd "$LADDER/13-security-tenancy"
make reset
```

**Terminalde ne görmelisin:** her `curl` önce JSON gövdeyi, altında ` → <HTTP kodu>` basar. 1. adımda ilk ikisi
`unsafe_url:private_address` ve `→ 400`, üçüncüsü `unsafe_url:private_address_resolved` ve `→ 400` (ad çözüldü,
127.0.0.1 bulundu), dördüncüsü `→ 201`. Sayaç satırları `private_address: 2` ve `private_address_resolved: 1` (önceden
başka ret sayıldıysa daha büyük). 2. adımda aynı `localtest.me` `→ 201`: kontrol atlatıldı ve hiçbir ret sayacına
girmedi.

**Grafana'da gör:** [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl13&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl13&from=now-15m&to=now&refresh=10s) — deneyden sonra aç; her deneme tek istek, tepeler alçak
- "Tehlikeli URL reddi (sebebe göre)" → `private_address` (düz IP ve `localhost`) ve `private_address_resolved` (yalnızca DNS çözümünün yakalayabildiği `localtest.me`); tuzak açıkken aynı istek yeni bir tepe yapmaz.
- "Oluşturma sonuçları" → ilk fazda `invalid`; tuzaklı fazda aynı adres `ok`: atlatılan kontrol metrikte başarı görünür.

**Nasıl çözülüyor:** Bu seviyede: alan adı oluşturma anında DNS'ten çözülür, iç adrese çıkıyorsa reddedilir; tuzak açıkken sorun döner. Risk azalır ama sıfırlanmaz: biz oluşturma anında çözeriz, tarayıcı tıklama anında çözer ve arada DNS cevabı değişebilir (TOCTOU). Azaltmalar: çözülen IP'yi sabitlemek, yönlendirme anında yeniden kontrol, dışa çıkış politikası.

---

### P13-06 · Enumeration maliyeti

**Ne oluyor:** Biri var olmayan kodları arka arkaya deneyerek (tarama) geçerli link arar. Her deneme bir 404 ve
çoğu zaman bir veritabanı okumasıdır; tarama sisteme yük bindirir ve normal trafik içinde zor fark edilir.
**Neden oluyor:** Kod uzayı çok büyük (62⁷ ≈ 3.5 trilyon), tahminle link bulmak pratikte imkânsız; mesele maliyet ve
görünürlük. Hız sınırı taramayı yavaşlatır; "bu kod yok" cevabını saklayan negatif önbellek yalnızca **tekrar
sorulan** kodlarda veritabanını korur; 404 oranına bakan bir kural yok.
**Bu deney:** Hız sınırı devredeyken iki faz tarama yükü verir — önce her istek yeni bir kod, sonra aynı 60 kod tekrar
tekrar — ve her fazda 404, negatif önbellek isabeti, veritabanı okuması ve limiter reddini karşılaştırır.

**Reproduce (adım adım):** Otomatik: `make repro P=P13-06` (iki faz × 40 sn `scan` yükü, limiter devrede: önce her
istek yeni bir kod, sonra aynı 60 yok-olan kod tekrar tekrar; iki fazın "404 başına DB okuması"nı yan yana basar,
2. fazda negatif isabet yoksa ölçemediğini söyler). Elle — yük `LIMITS_ENFORCED=1` ile herkese açık girişten gider
(yoksa k6 limitsiz yük girişini kullanır ve limiter'ı görmez); her fazdan sonra dört sayı okunur: 404, negatif önbellek
isabeti, DB okuması ve limiter reddi:

1. Temiz başla; 1. faz — her istek yeni, var olmayan bir kod (40 sn), sonra dört sayıyı oku:
```bash
cd "$LADDER/13-security-tenancy"
make fresh
LIMITS_ENFORCED=1 make load S=scan K6_ARGS="--vus 30 --duration 40s"
sleep 12
for q in \
  'sum(increase(redirect_total{namespace="lvl13",result="not_found"}[1m]))' \
  'sum(increase(cache_ops_total{namespace="lvl13",result="negative_hit"}[1m]))' \
  'sum(increase(db_queries_total{namespace="lvl13",op="get"}[1m]))' \
  'sum(increase(ratelimit_decisions_total{namespace="lvl13",decision="reject"}[1m]))'
do printf '%s → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "0"'; done
```
2. 2. faz — aynı 60 yok-olan kod tekrar tekrar (ölü linkler, tekrar eden botlar), aynı dört sayı:
```bash
cd "$LADDER/13-security-tenancy"
KEYS=60 CODE_LEN=7 LIMITS_ENFORCED=1 make load S=scan K6_ARGS="--vus 30 --duration 40s"
sleep 12
for q in \
  'sum(increase(redirect_total{namespace="lvl13",result="not_found"}[1m]))' \
  'sum(increase(cache_ops_total{namespace="lvl13",result="negative_hit"}[1m]))' \
  'sum(increase(db_queries_total{namespace="lvl13",op="get"}[1m]))' \
  'sum(increase(ratelimit_decisions_total{namespace="lvl13",decision="reject"}[1m]))'
do printf '%s → ' "$q"; curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "0"'; done
```

**Terminalde ne görmelisin:** iki yükün başında `k6 girişi: public (http://lvl13.localtest.me)` — limiter yolda. k6
özetinde (`k6 lvl13: reqs=… 5xx=… 404=… 429=…`) `404` küçük bir pay; gerisi limiter'lardan döner: uygulamanın IP
limiti `429` (10 sn'de 300 istek), ingress'in saniyede 400 istek sınırı `5xx` (503). 1. fazda `negative_hit` ~0 ve DB
okuması 404 sayısına yakın (404 başına ~1 okuma). 2. fazda 404 sayısı benzer ama `negative_hit` çoğunu karşılar ve
DB okuması belirgin düşer. İki fazda da `reject` 404'ten büyük.

**Grafana'da gör:** [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl13&from=now-15m&to=now&refresh=10s), [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl13&from=now-15m&to=now&refresh=10s) ve [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl13&from=now-15m&to=now&refresh=10s) — ilk tarama başlayınca aç; iki faz ~2 dk sürer
- "Var olmayan kod istekleri / sn (tarama)" → iki faz boyunca iki plato (yüksekliği limiter'ın izin verdiği hız), sonra sıfır; eksik "404 oranı" kuralının eşiği bu çizgiden okunur.
- "Kararlar (anahtar türüne göre)" → `ip` anahtarlı `reject` çizgisi `allow`'u ezer: taramanın çoğu önbelleğe ulaşmadan `429` ile döner.
- "Önbellek işlemleri (katman ve sonuca göre)" → 1. fazda `l2` `miss` yükselir, `negative_hit` düz kalır; 2. fazda `negative_hit` baskın olur.
- "Önbellek ıskası ve veritabanı sorguları" → 2. fazda ikisi de belirgin düşer: negatif önbelleğin kurtardığı DB okuması aradaki farktır.

**Nasıl çözülüyor:** Kısmen: rastgele 7 karakterli kod (01), negatif önbellek (03) ve hız sınırı (08) taramayı pahalı ve görünür kılar — amaç taramayı engellemek değil, budur. 404 **oranına** göre sınır (`NOT_FOUND_LIMIT`) yapılandırmada var ama kodda kullanılmıyor; yolun devamı 14 §9'da.

---

### P13-07 · README ≠ garanti

**Ne oluyor:** `:latest` etiketli, bellek sınırı olmayan ya da sağlık kontrolü (probe) olmayan bir pod kümeye
kurulabilir. Önceki seviyelerde bu kurallar yalnızca README'de yazıyor; unutan biri kurulumda hiçbir uyarı almaz.
**Neden oluyor:** Kubernetes böyle pod'ları kendiliğinden reddetmez. Kyverno, kümeye giriş kapısında (admission) her
yeni nesneyi kurallara göre denetleyen bir araç; bu seviye üç kuralı onunla zorunlu kılar.
**Bu deney:** Tanımlı politikayı listeler, her biri tek bir kuralı çiğneyen üç pod'u `--dry-run=server` ile (hiçbir şey
oluşturmadan) kurmayı dener ve kaçının reddedildiğini sayar.

**Reproduce (adım adım):** Otomatik: `make repro P=P13-07` (politikaları listeler, üç ihlali `--dry-run=server` ile
dener ve kaçının reddedildiğini sayar). Elle — `--dry-run=server` isteği admission'dan geçirir ama hiçbir şey
yaratmaz; geri alınacak bir şey kalmaz:

1. Temiz başla; tanımlı politikalara bak:
```bash
cd "$LADDER/13-security-tenancy"
make fresh
kubectl get clusterpolicy
```
2. Üç ihlali ayrı ayrı dene; her pod yalnızca bir kuralı çiğner (`:latest`, bellek limiti yok, readinessProbe yok):
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 run policy-test-latest --image=busybox:latest --restart=Never --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:latest","command":["sleep","30"],"resources":{"limits":{"memory":"64Mi"}},"readinessProbe":{"exec":{"command":["true"]}}}]}}' --dry-run=server
kubectl -n lvl13 run policy-test-nolimit --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","30"],"readinessProbe":{"exec":{"command":["true"]}}}]}}' --dry-run=server
kubectl -n lvl13 run policy-test-noprobe --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","30"],"resources":{"limits":{"memory":"64Mi"}}}]}}' --dry-run=server
```

**Terminalde ne görmelisin:** 1. adımda `linkly-ladder-baseline`. 2. adımda üçü de
`Error from server: admission webhook "…" denied the request` ile başlayan bir ret ve çiğnenen kural: sırasıyla
`disallow-latest-tag`, `require-memory-limit`, `require-probes`. Üç kurala uyan pod geçer (P13-03'teki `netcheck` gibi).

**Grafana'da gör:** [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl13&from=now-15m&to=now&refresh=10s) — deneyden sonra aç
- "Politika ihlalleri (Kyverno)" → kural başına bir basamak (`disallow-latest-tag`, `require-memory-limit`, `require-probes`), 1'de durur; Kyverno metrikleri ~1 dk gecikmeyle gelir.
- Explore'da: `up{namespace="kyverno"}` → `1` olmalı; çizgi hiç yoksa Kyverno kazınmıyordur (kanıt yine terminaldeki `denied the request`).

**Nasıl çözülüyor:** Bu seviyede Kyverno ile: kurala uymayan pod hiç oluşmaz. Her kural bir kez ölçülmüş bir arızadan gelir: P12-04 (`:latest`), P00-08 (bellek sınırı), P00-04 + P07-08 (probe). Politikalar yalnızca `lvl13`'ü kapsar; bütün seviyeleri kapsasaydı bilerek sınırsız olan 00 kurulamazdı.

---

### P13-08 · Konteyner ve tedarik zinciri sertleştirme

**Ne oluyor:** Uygulama konteyneri ele geçirilirse saldırganın elinde ne kalır? İmajda shell varsa, süreç root
çalışıyorsa ve dosya sistemine yazılabiliyorsa, uzaktan kod çalıştıran bir hata tam bir ele geçirmeye dönüşür.
**Neden oluyor:** Kodun güvenliği, çalıştığı imajın güvenliğiyle sınırlıdır. Shell'siz (distroless) bir imajda uzaktan
kod çalıştırma bir `curl | sh` zincirine dönüşemez; root olmayan kullanıcı, kapalı yetkiler ve salt okunur dosya
sistemi hasarı daraltır.
**Bu deney:** Yalnızca okur: hazır bir redirect pod'unun imajına ve güvenlik ayarlarına (`securityContext`) bakar,
konteynerde shell çalıştırmayı dener.

**Reproduce (adım adım):** Otomatik: `make repro P=P13-08` (hazır bir redirect pod'unun imajını ve `securityContext`'ini
okur, içinde shell çalıştırmayı dener, eksik tedarik zinciri adımlarını listeler). Elle (yalnızca okur):

1. Temiz başla; hazır bir redirect pod'u seç, imajına ve `securityContext`'ine bak:
```bash
cd "$LADDER/13-security-tenancy"
make fresh
pod=$(kubectl -n lvl13 get pod -l app.kubernetes.io/name=redirect -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty'); echo "pod: $pod"
kubectl -n lvl13 get pod "$pod" -o jsonpath='{.spec.containers[0].image}'; echo
kubectl -n lvl13 get pod "$pod" -o jsonpath='{.spec.containers[0].securityContext}'; echo
```
2. Konteynerde shell çalıştırmayı dene:
```bash
cd "$LADDER/13-security-tenancy"
kubectl -n lvl13 exec "$pod" -- /bin/sh -c 'echo VAR'
```

**Terminalde ne görmelisin:** 1. adımda imaj `localhost:5001/linkly-ladder/13-redirect-svc:<etiket>` (içerik hash'li
etiket, `:latest` değil) ve `"allowPrivilegeEscalation":false`, `"capabilities":{"drop":["ALL"]}`,
`"readOnlyRootFilesystem":true`, `"runAsNonRoot":true`, `"runAsUser":65532` içeren bir JSON. 2. adımda `VAR` yerine
`/bin/sh` için `no such file or directory`: imajda shell yok.

**Grafana'da gör:** Grafana'da görünmez — sertleştirme bir olay değil, pod tanımının ve imajın özelliği; hiçbir panel onu çizmez. Kanıt terminalde:
- `kubectl -n lvl13 get pod -l app.kubernetes.io/name=redirect -o jsonpath='{.items[0].spec.containers[0].securityContext}'` → `"readOnlyRootFilesystem":true`, `"runAsNonRoot":true` ve `"capabilities":{"drop":["ALL"]}` içeren bir JSON.
- `kubectl -n lvl13 exec $(kubectl -n lvl13 get pod -l app.kubernetes.io/name=redirect -o name | head -1) -- /bin/sh -c 'echo VAR'` → `VAR` yerine `/bin/sh` bulunamadı hatası: imajda shell yok.

**Nasıl çözülüyor:** Kısmen (13): shell'siz imaj, root olmayan kullanıcı, bütün ek yetkiler kapalı (`drop ALL`), salt okunur dosya sistemi. Eksik: imaj tarama (Trivy), imza (cosign) + imzayı doğrulayan politika, SBOM, temel imaj güncelleme — yolun devamı 14 §9'da.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_HEADER_TENANT` | Kiracıyı yine başlıktan alır | `make repro P=P13-01` | Bayrağı kapat |
| *(bayrak yok)* | Unutulmuş filtre bir kod yolu değil tek bir sorgudur; script onu uygulamanın rolüyle kendisi koşar, ölçülen RLS'in o sorguya ne yaptığıdır | `CONFIRM=1 make repro P=P13-02` | RLS yakalar |
| `TRAP_NO_DNS_CHECK` | DNS çözümü yapmaz | `make repro P=P13-05` | Bayrağı kapat |

Elle denemeye değer:
- `AUTH_REQUIRED=true` yapıp `GET /{code}`'u dene: public bir ucu kimliğe bağlamak ürünü bozar.
- Kyverno politikasını `Audit`'e çevir ve ihlalli pod'u dağıt: rapor var, engel yok.
- Limiti kimliğe bağla (`TIER_LIMITS`, şu an sabit kota): `free` ve `enterprise` anahtarla `make load S=abuser` — 08'de
  eksik kalan tier kotası için gereken kimlik artık var.
- RLS'i `NO FORCE` yap ve P13-02'yi tekrar koş: politika duruyor ama tablo sahibi onu atlıyor.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl13&from=now-15m&to=now) | **Dolu** | Kimlik reddi (yalnızca `401`, §5), tehlikeli URL reddi (`private_address_resolved` dahil), Kyverno ihlalleri, 404 taraması |
| [`10 · Rate limit`](http://grafana.localtest.me/d/ladder-ratelimit?var-level=lvl13&from=now-15m&to=now) | Dolu | `key_type=tenant` değerleri artık gerçek kiracılar |
| [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl13&from=now-15m&to=now) | Dolu | Sürüme göre paneller pod şablonu hash'iyle ayrılır; "Hazır pod (sürüme göre)" her sürümün hazır pod sayısı |
| [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl13&from=now-15m&to=now) · [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl13&from=now-15m&to=now) | Dolu | "Bağımlılık gecikmesi p99" `postgres` ve `redis`'i ayrı çizer |

Yeni metrik `auth_attempts_total{result}` (panel yok, Explore'da): `invalid` oranındaki ani artış bir saldırı sinyalidir.

## 9. Bilerek bırakılanlar

- **OIDC/JWT yok**: API anahtarı seçildi; ders kimlik doğrulamanın kendisi, protokol seçimi değil.
- **Sırlar düz metin** (P13-04) ve **egress NetworkPolicy yok**: pod'lar internete serbest çıkar.
- **404 oranına özel limit yok** (P13-06); **tier kotaları bağlı değil** (`TIER_LIMITS` tanımlı, limiter sabit kota kullanır).
- **TLS yok**: cert-manager kurulu, ingress HTTP (localtest.me için sertifika self-signed olurdu).
- **Audit log yok**: erişim log'u var, eylem log'u yok. **İmaj tarama/imza yok** (P13-08).
- **`/metrics` dışarıdan okunur** (`http://lvl13.localtest.me/metrics`); profil uçları bu yüzden ayrı iç portta (`:6060`).
- **Kyverno fail-open** (`platform/Makefile`): Kyverno ayakta değilken politikalar uygulanmaz; `Fail` modu Kyverno her
  yeniden başladığında kümenin bütün yazmalarını reddederdi. Üretimde karşılığı 3 replika + PDB ile `Fail`.
- **Yük testi girişi** (`deploy/loadtest.yaml`): jetonlu, hız sınırsız ikinci giriş; üretimde internetten erişilemez.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 12 ile farkı gösterir:

1. `internal/auth/apikey.go` (yeni): hash'li saklama + sabit zamanlı karşılaştırma.
2. `internal/httpapi/server.go` → `tenantOf`: gövde neredeyse aynı, değerin kaynağı farklı — seviyenin bütün güvenlik dersi.
3. `internal/httpapi/auth_mw.go`: zincirdeki yeri — hız sınırından sonra, iş mantığından önce.
4. `migrations/007_rls.sql`: `FORCE ROW LEVEL SECURITY` olmadan politika dekoratif kalır; migration hedefi onu bilerek
   uygulamaz (RLS'i P13-02 açıp kapatır).
5. `deploy/security.yaml`: varsayılan-reddet + izin listesi — mimarinin kendisinin belgesi.
6. `deploy/kyverno-policies.yaml`: README'lerden kapıya taşınan üç kural.
7. `internal/httpapi/api_test.go`: testler `X-Tenant-ID`'den Bearer anahtara taşındı — sözleşme gerçekten değişti.
