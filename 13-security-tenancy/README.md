# 13 — security-tenancy · "Kim, neye, ne kadar"

## 1. Bu seviye ne?

On iki seviye boyunca her README aynı cümleyi büyük harflerle yazdı: **`X-Tenant-ID` kimlik
doğrulama değildir.** Burada nihayet oluyor. Kiracı artık hash'lenmiş bir API anahtarından
türüyor; veritabanı kiracı sınırını **kendisi** de biliyor (RLS); ağ varsayılan olarak kapalı;
merdivende öğrenilen kurallar README'den **admission policy**'ye taşınıyor.

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

Sıra bilinçli: **ucuz kontroller önce** (IP limiti), pahalı olanlar sonra (hash + arama).
Kimliksiz bir sel, hash maliyeti ödemeden reddedilmeli.

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| P12-04 | `:latest` / eksik limit / eksik probe kuralları yalnızca README'deydi | Kyverno `ClusterPolicy`: üç kural da admission'da **zorunlu** (`Enforce`). *README bir temennidir; admission policy bir garantidir.* |

Ayrıca **12 seviyelik borç** kapanıyor: P02-09 (düz metin sır) kısmen, P00-06/P13-05 (URL güvenliği)
DNS çözümüyle derinleşti ve `X-Tenant-ID` sahteciliği tamamen bitti.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG, Argo CD + Argo Rollouts, cert-manager + Kyverno**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl13.localtest.me/api/links -H 'Content-Type: application/json' -H 'Authorization: Bearer acme-key-9f2c' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl13.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl13 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P13-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

**Dikkat:** 13'ten itibaren yönetim uçları (`/api/...`) `Authorization: Bearer <anahtar>` ister — yukarıdaki POST bu yüzden anahtarlı (anahtarlar: `deploy/api-keys.yaml`). `GET /{code}` **public** kalır — kısa linke tıklayanın API anahtarı olmaz.

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Bu seviyenin değişikliği: **`Authorization: Bearer <key>`**.

| Uç | Kimlik |
|---|---|
| `GET /{code}` | **Public** (anahtar varsa kiracı/tier çözülür) |
| `POST/GET/DELETE /api/links*` | **Zorunlu** → yoksa `401` + `WWW-Authenticate` |

`X-Tenant-ID` artık **yok sayılır**. 401 ile 403 ayrımı: *401 = "kim olduğunu bilmiyorum",
403 = "biliyorum ama yetkin yok"*. Geçersiz anahtar birincisidir.

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P13-01 | **TRAP** header ile kiracı taklidi | `make repro P=P13-01` | Security → 401/403 | seviye içi (kimlik) |
| P13-02 | Unutulan tenant filtresi = sessiz sızıntı | `make repro P=P13-02` | Postgres | seviye içi (RLS) |
| P13-03 | Her pod veritabanına ulaşabiliyor | `make repro P=P13-03` | Security | seviye içi (NetworkPolicy) |
| P13-04 | Sırlar git'te düz metin | `make repro P=P13-04` | — | kısmen (sealed-secrets hazır) |
| P13-05 | **TRAP** DNS ile gizlenen iç adres | `make repro P=P13-05` | Security → unsafe reddi | seviye içi + TOCTOU kalır |
| P13-06 | Enumeration maliyeti | `make repro P=P13-06` | Security → 404/s | kısmen (404 limiti yok) |
| P13-07 | README ≠ garanti | `make repro P=P13-07` | Security → Kyverno | seviye içi |
| P13-08 | Konteyner/tedarik zinciri sertleştirme | `make repro P=P13-08` | — | kısmen |

---

### P13-01 · TRAP · Header ile kiracı taklidi

**Belirti:** `TRAP_HEADER_TENANT` açıkken, hiç anahtar göndermeden `X-Tenant-ID: acme` diyerek
acme'nin linki silinebiliyor. Kapalıyken aynı istek `401`/`404`.
**Neden:** Kimlik doğrulama **kodu** tuzakta da duruyordu — değişen tek şey **kararın neye
dayandığıydı**. [Topic · Konu: Güven sınırı, kimlik]

**Reproduce:** `make repro P=P13-01`.
**Ders:** *Bir sınır, karşılaştırdığı değeri ayarlayabilen en zayıf şey kadar güçlüdür.*
Bu yüzden "kiracıyı nereden alıyoruz?" bir uygulama detayı değil, bir **güvenlik sınırıdır**.

---

### P13-02 · Unutulan tenant filtresi = sessiz sızıntı

**Belirti:** RLS etkinken `app.tenant_id` ayarlanmamış bir sorgu **0 satır** döner; ayarlıyken
yalnızca o kiracının satırları.
**Neden:** Uygulama filtreleri, biri `WHERE`'i unutana kadar doğrudur — ve o hata **hiçbir hata
üretmez**. [Topic · Konu: RLS, katmanlı savunma]

**Reproduce:** `make repro P=P13-02`.
**İki kritik detay:**
- **`FORCE ROW LEVEL SECURITY`** olmadan tablo **sahibi** politikayı atlar → politika yazılmış ama
  hiç uygulanmamış olur. RLS'in en sık atlanan detayı.
- Transaction havuzlaması ile ayar **işlem başına** (`SET LOCAL`) yapılmalı; oturum başına
  yapılırsa bir sonraki kiracı öncekinin ayarını devralır — **P09-03'teki aynı fizik**.

---

### P13-03 · Varsayılan-reddet ağ

**Belirti:** Yetkisiz bir pod'dan `nc -z pg-pooler-rw 5432` **engellenir**.
**Neden:** Kubernetes'in varsayılanı "herkes herkesle konuşabilir"dir.
[Topic · Konu: NetworkPolicy, en az yetki]

**Reproduce:** `make repro P=P13-03`.
**Ders:** Varsayılan-reddet, soruyu *"neyi engellemeliyim?"*den (sonsuz) *"ne neyle konuşmalı?"*ya
(sonlu, gözden geçirilebilir, **mimariyi belgeler**) çevirir.
**Uyarı:** NetworkPolicy yalnızca CNI destekliyorsa çalışır (burada Calico). Desteklemeyen bir
cluster'da politika yazmak **güvenlik yanılsamasıdır**. **Eksik:** egress kuralları.

---

### P13-04 · Sırlar hâlâ git'te düz metin

**Belirti:** `deploy/api-keys.yaml` ve `cnpg.yaml` düz metin sır içeriyor; sealed-secrets kurulu
ama kullanılmıyor.
**Neden (dürüst hâli):** SealedSecret üretmek cluster'ın anahtarını gerektirir ve depoyu taze bir
cluster'da kullanılamaz kılardı. *Bir sırrın güvenli olduğunu varsaymak, olmadığını kabul etmekten
kötüdür* — bu yüzden düz Secret duruyor ve script çözümü tek komuta indiriyor.
[Topic · Konu: Sır yönetimi]

**Reproduce:** `make repro P=P13-04` — durumu ölçer ve `kubeseal` komutunu yazar.
**Sealed-secrets'ın çözmediği:** sır pod'un **env**'inde hâlâ düz metin.
*Sır yönetimi bir araç seçimi değil, bir zincir: git → cluster → pod → süreç → log → yedek.*

---

### P13-05 · TRAP · DNS ile gizlenen iç adresler

**Belirti:** `http://localtest.me/` (127.0.0.1'e çözülür) DNS kontrolü açıkken **reddedilir**,
kapalıyken **kabul edilir**.
**Neden:** 01'deki kontrol yalnızca düz IP'lere bakıyordu; saldırgan bir alan adı kaydeder.
[Topic · Konu: SSRF/open redirect, DNS rebinding]

**Reproduce:** `make repro P=P13-05`.
**Kapatılamayan boşluk (TOCTOU):** biz oluşturma anında çözüyoruz, tarayıcı tıklama anında
çözecek. Azaltmalar: çözülen IP'yi sabitle (CDN'i kırar) · redirect anında yeniden kontrol
(her redirect'e bir DNS sorgusu) · egress politikası.
*"Riski azalttık" demek, "yok ettik" demekten dürüsttür. Bir kontrolün sınırını bilmemek, onu hiç
yapmamaktan tehlikelidir — çünkü yanlış bir güven duygusu üretir.*

---

### P13-06 · Enumeration maliyeti

**Belirti:** Rastgele kod taraması 404 üretir; negatif önbellek ve hız sınırı maliyeti düşürür
ama **404 oranına özel bir kural yoktur**.
**Neden:** Kod uzayı 62⁷ = 3.5×10¹² — tahmin pratikte imkânsız. Asıl mesele taramanın **maliyeti
ve görünürlüğü**. [Topic · Konu: Enumeration]

**Reproduce:** `make repro P=P13-06`.
**Üç katman zaten var:** rastgele 7 karakter (01) · negatif önbellek (03) · hız sınırı (08).
**Eksik dördüncü:** 404 **oranına** göre limit — normal client'ın oranı düşüktür, tarayanınki
~%100. `NOT_FOUND_LIMIT` bunun için ayrıldı ama **uygulanmadı**.
*Enumeration'ı tamamen engellemek genelde mümkün değildir; amaç onu pahalı ve görünür kılmaktır.*

---

### P13-07 · README ≠ garanti

**Belirti:** `:latest`, bellek limitsiz ya da probe'suz bir pod **admission'da reddedilir**.
**Neden:** Bu kurallar şimdiye kadar yalnızca README'lerde yazıyordu.
[Topic · Konu: Policy as code]

**Reproduce:** `make repro P=P13-07` — üç ihlali `--dry-run=server` ile dener.
**Politikaların kaynağı bu merdivenin kendi geçmişi:** P12-04 (`:latest`), P00-08 (bellek limiti),
P00-04 + P07-08 (probe). *Her kural, bir kez ölçülmüş bir arızanın kalıcı karşılığı.*
**İki operasyonel not:** yeni politikayı önce `Audit` ile açmak standarttır; politika **admission**
anında çalışır, zaten çalışan ihlalleri **silmez**.

**Kapsam notu — politikanın patlama yarıçapı:** Bu politikalar bilerek yalnızca `lvl13`
namespace'ine kapsandı. `ClusterPolicy` **küme kapsamlıdır** ve `make down` onu silmez (yalnızca
namespace gider). Kapsam `lvl*` + `Enforce` olsaydı, bu seviyeyi bir kez çalıştırdıktan sonra
**00'ı bir daha ayağa kaldıramazdın**: orada bellek limiti bilerek yok (P00-08). Yani politika,
onu kuran şeyden daha uzun yaşar ve geçmişi de kapsar. Üretimde istediğin tam olarak budur;
bir öğrenme merdiveninde ise kendi kendini kilitlemektir. *Bir kuralı yazmadan önce "kimleri
kapsıyor ve ne zaman kaldırılacak?" sorusunun cevabını yaz.*

---

### P13-08 · Konteyner ve tedarik zinciri sertleştirme

**Belirti/Doğrulama:** İmajda shell **yok** (distroless), `readOnlyRootFilesystem: true`,
`capabilities: drop ALL`, non-root.
**Neden:** *Kod güvenliği, çalıştırdığın imajın güvenliğiyle sınırlıdır.*
[Topic · Konu: Saldırı yüzeyi, tedarik zinciri]

**Reproduce:** `make repro P=P13-08`.
**Distroless'ın verdiği:** içeride shell yoksa uzaktan kod çalıştırma bir `curl | sh` zincirine
dönüşemez. **Bedeli 00'da yaşandı:** `HEALTHCHECK`'in çağıracağı araç yok, bu yüzden binary
kendini yokluyor.
**Eksik kalanlar:** imaj tarama (Trivy) · imza (cosign) + `verifyImages` politikası · SBOM ·
base imaj güncelleme otomasyonu.

> **Bu bölüm bir süre YANLIŞTI.** Yukarıdaki `readOnlyRootFilesystem: true` / `drop ALL` /
> non-root satırları README'de yazıyordu ama manifest'lerde `securityContext` **hiç yoktu**.
> Scripti koşan fark etti: P13-08 `NOT-REPRODUCED` dedi ve haklıydı. Belgeyi kodla değil,
> **ölçümle** doğrula — README bir iddiadır, `kubectl get pod -o jsonpath` bir kanıttır.
> ("İmaj nonroot koşuyor" imaj hakkında bir iddiadır; `runAsNonRoot` API sunucusunun
> kontrol ettiği bir iddiadır — ikisi aynı şey değil.)

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `TRAP_HEADER_TENANT` | Kiracıyı yine header'dan alır | `make repro P=P13-01` | Bayrağı kapat |
| *(bayrak yok — script SQL'i doğrudan koşar)* | "Unutulmuş `WHERE tenant = …`" filtresiz bir sorgu olarak koşulur; sonra RLS açılıp aynı sorgu tekrarlanır. `TRAP_DROP_TENANT_FILTER` bayrağı config'de tanımlıydı ve kodda hiç okunmuyordu — açması hiçbir şeyi değiştirmiyordu, kaldırıldı. | `CONFIRM=1 make repro P=P13-02` | RLS yakalar |
| `TRAP_NO_DNS_CHECK` | DNS çözümü yapmaz | `make repro P=P13-05` | Bayrağı kapat |

Elle denemeye değer:
- `AUTH_REQUIRED=true` yapıp `GET /{code}`'u dene: **public bir ucu kimliğe bağlamak** ürünü bozar.
  *Her ucu korumak, korumanın değerini artırmaz — hangi ucun neden açık olduğunu bilmek artırır.*
- Kyverno politikasını `Audit`'e çevir ve ihlalli pod'u dağıt: rapor var, engel yok.
  Hangi modun ne zaman doğru olduğunu ölç.
- `TIER_LIMITS`'i kullanacak şekilde limiti kimliğe bağla (şu an sabit): `free` bir anahtarla
  ve `enterprise` bir anahtarla `make load S=abuser` koş. **08'de eksik bıraktığımız tier
  kotaları için gereken kimlik artık var.**
- RLS'i `NO FORCE` yap ve P13-02'yi tekrar koş: politika duruyor ama sahip atlıyor —
  *var olan ama uygulanmayan bir kontrolün nasıl göründüğünü gör.*

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| `14 · Security` | **Dolu** ✨ | 401/403, unsafe URL reddi (`private_address_resolved` dahil), Kyverno sonuçları, 404 taraması |
| `10 · Rate limit` | Dolu — **artık kimlikli** | `key_type=tenant` değerleri gerçek kiracılar |
| `13 · Rollout` · `12 · SLO` · `11 · Resilience` | Dolu | — |

Yeni metrik: `auth_attempts_total{result}`. **`invalid` oranındaki ani artış bir saldırı
sinyalidir** — ve bu, bir SLO'dan değil bir güvenlik kuralından alarm üretmesi gereken nadir
durumlardan biri.

## 9. Bilerek bırakılanlar

- **OIDC/JWT yok**: API anahtarı seçildi. JWT, imza doğrulama + anahtar rotasyonu + iptal listesi
  getirir; *ders kimlik doğrulamanın kendisiydi, protokol seçimi değil.*
- **Sırlar düz metin** (P13-04): sealed-secrets kurulu, kullanılmıyor — gerekçesi yazılı.
- **Egress NetworkPolicy yok**: pod'lar internete serbest çıkıyor.
- **404 oranına özel limit yok** (P13-06): `NOT_FOUND_LIMIT` ayrıldı, uygulanmadı.
- **Tier kotaları bağlanmadı**: `TIER_LIMITS` tanımlı ama limiter sabit kota kullanıyor.
- **TLS yok**: cert-manager kurulu ama ingress hâlâ HTTP. *localtest.me için sertifika üretmek
  self-signed olurdu ve tarayıcı uyarısı dersi gölgelerdi.*
- **Audit log yok**: kim neyi sildi kaydı tutulmuyor (erişim log'u var, **eylem** log'u yok).
- **İmaj tarama/imza yok** (P13-08).
- **Kyverno fail-OPEN** (`forceFailurePolicyIgnore`, `platform/Makefile`): Kyverno ayakta değilken
  politikalar uygulanmaz. Varsayılan `failurePolicy: Fail` bu kümede her yeniden başlatmada **tüm
  kümenin yazmalarını** reddetti (PVC oluşmadı, `make up` düştü). P08-01'deki limiter seçiminin
  aynısı: korumayı kaybetmek telafi edilebilir, hizmeti kaybetmek edilemez. Üretimde karşılığı
  Kyverno'yu 3 replika + PodDisruptionBudget ile çalıştırıp Fail'de tutmaktır.
- **Yük testi muafiyeti** (`deploy/loadtest.yaml`, 08'den beri): jetonlu, hız sınırı olmayan ikinci
  giriş. Tek IP'li yük üreteci herkese açık girişte sistemi değil limiter'ları ölçüyordu. Üretimde
  bu giriş internetten erişilemez ve jeton mühürlü olur.

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 12 ile farkı gösterir:

1. **`internal/auth/apikey.go`** (yeni): hash'li saklama + **sabit zamanlı** karşılaştırma.
   *Zamanlama yan kanalı küçüktür ama kapatması bedavadır.*
2. **`internal/httpapi/server.go` → `tenantOf`**: gövde neredeyse aynı, **değerin kaynağı** farklı.
   Bu seviyenin bütün güvenlik dersi o üç satırda.
3. **`internal/httpapi/auth_mw.go`**: zincirdeki **yeri** yorumda gerekçelendirilmiş —
   hız sınırından sonra, iş mantığından önce.
4. **`migrations/008_rls.sql`**: `FORCE ROW LEVEL SECURITY` satırı olmadan politika **dekoratif**
   olurdu. Yorumda bu ve transaction-pooling tuzağı yazılı.
5. **`deploy/security.yaml`**: varsayılan-reddet + izin listesi. Liste, **mimarinin kendisinin
   dokümantasyonu**: kim kiminle konuşuyor, tek bakışta.
6. **`deploy/kyverno-policies.yaml`**: merdivenin README'lerinden **kapıya** taşınan üç kural.
7. **`internal/httpapi/api_test.go`**: testler `X-Tenant-ID`'den Bearer token'a taşındı.
   *"Testi değiştirmek zorunda kaldım" bazen bir sinyal, bazen de sözleşmenin gerçekten
   değiştiğinin kanıtıdır.*
