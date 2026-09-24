# 12 — delivery · "Güvenli dağıtım"

> **Bu seviyede ne yaşayacaksın?**
> - Kötü bir sürümün canary'de — 4 pod'dan birindeyken, trafiğin ~1/4'ünde — Prometheus analiziyle yakalanıp otomatik geri alınması (P12-01)
> - Tuzak: eski kodu kıran bir migration (P12-02); elle yapılan bir değişikliğin (drift) kimseye görünmemesi (P12-03)
> - `:latest` etiketin belirsiz ve geri alınamaz olması (P12-04); canary ile stable'ın aynı Redis'e farklı formatta yazması (P12-05)
> - Uygulama geri alınınca şemanın geri alınmaması ve expand/contract'ın bunu nasıl önlediği (P12-06)
>
> **Bu seviye olmasa ne olur?** Her dağıtım "pod'ları değiştir ve umut et"tir; kötü bir sürüm trafiğin tamamına ulaşır ve geri alma elle yapılır.
>
> **Yeni gelen teknolojiler:** Argo Rollouts (canary + AnalysisTemplate), Argo CD, expand/contract migration, `13 · Rollout` paneli ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

## 1. Bu seviye ne?

Şimdiye kadar her dağıtım "pod'ları değiştir ve umut et"ti. Bu seviye o umudu **ölçümle**
değiştiriyor: redirect-svc artık bir **Argo Rollout** ve canary adımları arasında Prometheus'a
bakan **otomatik analiz** var — kötü bir sürüm yalnızca canary pod'undayken (4 pod'dan biri,
trafiğin ~1/4'ü) yakalanıp geri alınıyor. Yanında şemanın dağıtımla nasıl uyumlu kalacağı
(**expand/contract**) ve cluster durumunun git'ten nasıl sapmadığı soruları var.

## 2. Mimari

```mermaid
flowchart LR
  I[ingress] --> SVC["Service: redirect"]
  SVC --> ST["stable pods (3)"]
  SVC --> CN["canary pod (1) ≈ trafiğin 1/4'ü"]
  AR["Argo Rollouts<br/>controller"] -->|"adım adım POD SAYISI<br/>(trafik yönlendirici yok)"| CN
  AR -->|AnalysisRun| PR[(Prometheus)]
  PR -->|"namespace geneli 5xx oranı ≤ %2<br/>p99 ≤ 300ms"| AR
  AR -->|"başarısız → ABORT"| ST
```

Kritik nokta: **kararı bir makine veriyor.** İnsanın dashboard'a bakıp fark etmesi dakikalar
sürer; analiz 30–60 saniyede karar verir.

**Ağırlık bir trafik yüzdesi değil:** Rollout'ta trafik yönlendirici (nginx canary ingress, service
mesh) tanımlı olmadığı için Argo `setWeight: 10`u pod sayısıyla yaklaşık tutar — 3 replikada 1 canary
pod eklenir, stable 3'te kalır ve Service trafiği 4 pod'a eşit böler. Sayılar bu yüzden "%10" değil
"~%25" (P12-01, §9).

## 3. Önceki seviyeden çözülenler

**Hiçbiri** — `problems/SOLVES` bunu gerekçesiyle yazar. 12 canary ve GitOps getiriyor; 11'in
sorunlarından birini ortadan kaldırmıyor.

**Kapatılan borçlar** (`SOLVES` kontratına girmedikleri için burada): P11-07'nin (dashboard drift'i)
disiplini uygulamaya genişliyor — manifest'ler kaynakta, `make deploy` yeniden uygular, elle yapılan
değişiklik kalıcı olamaz (P12-03 bunu ölçüyor ve **Argo CD'nin ne eklediğini** söylüyor). P11-07'nin
kendisi 11'de "kod olarak dashboard" ile zaten çözülü; 12 onu çözmüyor, aynı dersi uygulamaya taşıyor.

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG, Argo CD + Argo Rollouts**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl12.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl12.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl12 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P12-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

Rollout'u izlemek için (sonuncusu yalnızca `kubectl argo rollouts` eklentisi kuruluysa çalışır; merdivenin scriptleri
eklentiye dayanmaz):
```bash
kubectl -n lvl12 get rollout redirect -w
kubectl -n lvl12 get analysisrun
kubectl argo rollouts get rollout redirect -n lvl12 --watch
```

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Önceki seviye açıksa kapat (aynı anda tek seviye çalışır), bu seviyeyi kur. `make up` Grafana'yı da temizler ve
   redirect Rollout'u `Healthy` olana kadar bekler:
```bash
make -C ../11-observability-deep down
make up
```
2. 11'in sekiz sorun scriptini bu seviyede koş. Koşarken başka komut çalıştırma: aynı pod'lara dokunurlar.
   12, 11'in sorunlarından hiçbirini çözmüyor (`problems/SOLVES` gerekçesini yazar): `BEKLENEN` sütunu her satırda
   `(açık kalabilir)` der:
```bash
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P12-01 → P12-06). Her sorunda aynı düzen:
   **Elle** bloklarını sırayla yapıştır (ilk komut `make fresh`: Grafana bu deneye boş başlar) →
   **Terminalde ne görmelisin** ile karşılaştır → **Grafana'da gör** linklerini aç, her madde hangi panelde neyi
   göreceğini söyler. İstersen aynı deneyi `make repro P=…` ile otomatik koş: ölçer ve hükmünü basar.
   Redirect bir Argo Rollout: ortamını `make set … W=redirect` / `make reset` değiştirir (`kubectl set env` Rollout'ta
   çalışmaz), ölçeğini `kubectl -n lvl12 scale rollout/redirect --replicas=N`, fazını
   `kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'` söyler.
4. Bitince açık kalan ayarları geri al, Rollout'un `Healthy` olduğunu gör, seviyeyi kapat:
```bash
make reset
kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'; echo
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Yeni bir **operasyonel** davranış var: `BAD_VERSION_ERROR_PCT` ile kasıtlı bozuk bir sürüm
üretilebiliyor (varsayılan 0). *Dağıtım güvenliğini test etmek için gerçekten bozuk bir sürüme
ihtiyacın var; kasıtlı bir bug, yeniden üretilebilir bir bug'dır.*

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| P12-01 | Kötü sürüm %100'e gider | `make repro P=P12-01` | [13 · Rollout](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl12&from=now-30m&to=now&refresh=10s) · [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl12&from=now-30m&to=now&refresh=10s) → "İstek / sn (sürüme göre)" | seviye içi (canary+analiz) |
| P12-02 | Kırıcı migration (yük altında `psql` ile `RENAME COLUMN`) | `CONFIRM=1 make repro P=P12-02` | [02 · App RED](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl12&from=now-15m&to=now&refresh=10s) · [03 · App Business](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl12&from=now-15m&to=now&refresh=10s) → "İstek / saniye (durum koduna göre)" | seviye içi (expand/contract) |
| P12-03 | Drift: elle yapılan değişiklik | `make repro P=P12-03` | görünmez — kanıt terminalde ↓ | Argo CD (kurulu) |
| P12-04 | `:latest` = belirsiz, geri alınamaz sürüm | `make repro P=P12-04` | [13 · Rollout](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl12&from=now-15m&to=now&refresh=10s) → "İstek / sn (sürüme göre)" | 13 (Kyverno) |
| P12-05 | Canary + paylaşılan durum uyumsuzluğu | `make repro P=P12-05` | [04 · Cache](http://grafana.localtest.me/d/ladder-cache?var-level=lvl12&from=now-15m&to=now&refresh=10s) → "İsabet oranı (pod'a göre)" | tartışma |
| P12-06 | Uygulama geri alındı, şema alınmadı | `make repro P=P12-06` | görünmez — kanıt terminalde ↓ | disiplin |

---

### P12-01 · Kötü sürüm canary'de yakalanıyor

**Belirti/Beklenti:** `%25` hata üreten bir sürüm dağıtıldığında canary pod'u trafiğin ~1/4'ünü alır;
o süre boyunca toplam hata oranı ~%6'ya (%25 × 1/4) çıkar, analiz bunu 30–60 sn içinde görür, rollout
**Degraded** olur ve geri alınır. 3 dakikalık yük koşusunun ortalaması daha da düşüktür (kötü sürüm
yalnızca abort'a kadar trafikteydi). Rolling update'te aynı oran %25'e kadar çıkardı.
**Neden:** Analiz 30 sn sonra ölçer, eşiği aşarsa **abort** eder. İki ayrıntı sayıları belirliyor:
(1) trafik yönlendirici olmadığı için canary payı `setWeight: 10` değil **pod sayısıdır** (1 canary + 3
stable); (2) analiz canary'yi ayrı ölçmez, **namespace'in bütün `/{code}` trafiğinin** 5xx oranını
%2 eşiğiyle karşılaştırır (`deploy/rollout.yaml`) — canary'nin kendi %25'i değil, toplamdaki ~%6 görülür.
[Topic · Konu: Canary, progressive delivery, otomatik geri alma]

**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=P12-01` (yük altında `BAD_VERSION_ERROR_PCT=25` ile dağıtır; rollout
fazını, sürüm etiketinden ölçülen canary payını, canary'nin kendi hata oranını ve toplam oranı basar; analizin metrikle
mi yoksa altyapı hatasıyla mı durduğunu rollout mesajından ayırır, sonunda kötü sürümü geri alır).

Elle — `12-delivery` klasöründe, sırayla yapıştır:

1. Grafana'yı temizle, mevcut sürümün sağlıklı olduğuna ve stable pod şablonu hash'ine bak:
```bash
make fresh
kubectl -n lvl12 get rollout redirect -o custom-columns=AŞAMA:.status.phase,HAZIR:.status.readyReplicas,GÜNCEL:.status.updatedReplicas
kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.stableRS}'; echo
```
2. İKİNCİ bir terminalde `12-delivery` klasöründe 3 dk yük başlat (analiz ancak trafik varken bir şey ölçer):
```bash
make load S=redirect K6_ARGS="--vus 15 --duration 180s"
```
3. Yük başladıktan ~15 sn sonra İLK terminalde kötü sürümü dağıt (redirect'lerin %25'i 500 döner): Rollout 3 stable
   pod'un yanına 1 canary pod ekler. Ardından fazı 4 sn'de bir bas; `Degraded` görünce döngü durur:
```bash
make set E="BAD_VERSION_ERROR_PCT=25" W=redirect
for i in $(seq 1 45); do p=$(kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'); echo "$((i*4)) sn: $p"; if [ "$p" = Degraded ]; then break; fi; sleep 4; done
```
4. Analizin kararını ve gerekçesini oku, canary süresince toplam 5xx oranının tepesine bak:
```bash
kubectl -n lvl12 get analysisrun
kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.message}'; echo
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time((sum(rate(http_requests_total{namespace="lvl12",route="/{code}",code=~"5.."}[30s])) / sum(rate(http_requests_total{namespace="lvl12",route="/{code}"}[30s])))[5m:10s])' | jq -r '"toplam 5xx oranı (tepe): " + .data.result[0].value[1]'
```
5. İkinci terminaldeki yük bitince (k6 çıktısının sonundaki özet satırı `k6 lvl12: …`) kötü sürümü geri al — ortam
   manifest'teki hâline döner, pod şablonu stable'la aynı olur — ve fazın `Healthy`'ye döndüğünü gör:
```bash
make reset
sleep 10
kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'; echo
```

**Terminalde ne görmelisin:** 1. adımda `Healthy 3 3` ve stable pod şablonu hash'i (kısa bir hex dizgisi; Grafana'daki
`rollouts_pod_template_hash`). 3. adımda `make set` `✔ rollout/redirect: BAD_VERSION_ERROR_PCT=25` basar, döngü
önce `… sn: Progressing`, analiz başladıktan 30–60 sn sonra `… sn: Degraded`: kötü sürüm canary payındayken durduruldu.
`get analysisrun`'da en yeni koşu `Failed`; rollout mesajı `error-rate` metriğinin başarısız olduğunu söyler — mesajda
`unreachable` / `dial tcp` gibi bir ağ hatası varsa analiz metrik okuyamadan düşmüştür ve bu kötü sürümün yakalandığı
anlamına gelmez (script bunu ayırır). Toplam 5xx oranının tepesi ~`0.06` (%25 × ~1/4 pay); özet satırındaki `5xx` / `reqs`
oranı bundan da düşük, çünkü kötü sürüm yalnızca abort'a kadar trafikteydi. 5. adımdan sonra faz `Healthy`.

**Grafana'da gör:** [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl12&from=now-30m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl12&from=now-30m&to=now&refresh=10s) — `make repro`'yu başlatınca aç; kötü sürüm ~15 sn sonra dağıtılır, analiz 30–60 sn içinde karar verir (giriş: admin / ladder)
- "İstek / sn (sürüme göre)" → çizgi başına bir **pod şablonu hash'i** (`rollouts_pod_template_hash`): canary başlayınca yeni bir hash belirir ve toplamın ~1/4'ünü alır, abort'tan sonra kaybolur. Hangisi stable? `kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.stableRS}'` stable hash'i verir, diğeri canary'dir (canary sürerken `{.status.currentPodHash}` onu verir). Etiketsiz çizgi api-svc'dir: Deployment olduğu için sürüm etiketi yok.
- "Hata oranı (sürüme göre)" → canary hash'inin çizgisi ~%25'e çıkar (kötü sürümün kendi oranı), stable hash'i 0'da kalır. Analizin karar verdiği sayı bu çizgi değil, toplamdır ↓
- "Sunucu hatası oranı (5xx)" → canary süresince ~%6 (%25 × 1/4) ve abort'la sıfıra döner: analizin %2 eşiğiyle karşılaştırdığı namespace geneli oran budur.
- "p99 süre (sürüme göre)" → iki hash birbirine yakın: kötü sürüm hızlı hata veriyor, gecikme analizi (≤ 300 ms) geçer; abort'u hata oranı tetikler.
- "Dağıtım aşaması (Argo Rollouts)" → `redirect: Progressing`, abort'tan sonra `redirect: Degraded`; `istenen replika` 3'te sabit kalır (canary pod'u bunun üstüne eklenir). Panel boşsa Argo Rollouts metrikleri kazınmıyor (`make -C ../platform argo`); faz her durumda terminalde: `kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'` → `Degraded`, `kubectl -n lvl12 get analysisrun` → en yeni koşu `Failed`.
- "İstek / saniye (durum koduna göre)" → `302`'nin yanında kısa ömürlü bir `500` çizgisi: kötü sürümün `BAD_VERSION_ERROR_PCT` ile ürettiği hata.

**Bedeli:** dağıtım 30 saniye yerine birkaç dakika sürer. **Bu, sigorta primidir.**
**Analizin iki ayarı da önemli:** `initialDelay: 30s` olmadan analiz *henüz veri yokken* karar
verir; `failureLimit` olmadan tek bir gürültülü ölçüm sağlıklı bir sürümü geri aldırır.

---

### P12-02 · Kırıcı migration

**Belirti:** Yük altında `ALTER TABLE ... RENAME COLUMN` uygulandığında eski pod'lar 500 döner.
**Neden:** Rolling update, iki sürümün **bir arada** yaşayacağını garanti eder. Dolayısıyla her
migration, dağıtımın **her iki yanındaki** kodla uyumlu olmak zorundadır.
[Topic · Konu: Expand/contract, sıfır kesintili şema değişikliği]

**Reproduce (adım adım):**

Otomatik: `CONFIRM=1 make repro P=P12-02` — bir `TRAP_` bayrağı yok: script yük altında primary'de
`psql` ile `ALTER TABLE links RENAME COLUMN url TO url_old` koşar, hata penceresini ölçer, sonra sütunu
eski adına döndürür (script yarıda kalsa da temizlik adımı geri alır). `CONFIRM=1`, şemaya dokunan yıkıcı bir deney olduğunu işaretler.

Elle — sırayla yapıştır. **Dikkat:** 3. adım canlı şemayı bozar; 4. adımı (sütunu eski adına döndürmek) atlama —
atlanırsa her link oluşturma `503` dönmeye devam eder.

1. Grafana'yı temizle, CNPG primary pod'unu bul (silinmekte olmayan, hazır olan), `links` tablosunun sütunlarına bak:
```bash
make fresh
prim=$(kubectl -n lvl12 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty'); echo "primary: $prim"
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='links'"
```
2. İKİNCİ bir terminalde `12-delivery` klasöründe 90 sn karışık yük (okuma + oluşturma) başlat:
```bash
make load S=mixed K6_ARGS="--vus 15 --duration 90s"
```
3. Yük başladıktan ~15 sn sonra İLK terminalde kırıcı migration'ı uygula, bir link oluşturmayı dene, ~20 sn bekleyip
   DB hatalarını oku:
```bash
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'ALTER TABLE links RENAME COLUMN url TO url_old'
curl -s -XPOST http://lvl12.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p1202"}' -w ' → %{http_code}\n'
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (increase(db_queries_total{namespace="lvl12",result="error"}[3m]))' | jq -r '.data.result[] | "\(.metric.op): \(.value[1])"'
```
4. Geri al: sütunu eski adına döndür, şemaya ve oluşturmaya tekrar bak:
```bash
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'ALTER TABLE links RENAME COLUMN url_old TO url'
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='links'"
curl -s -XPOST http://lvl12.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p1202"}' -w ' → %{http_code}\n'
```

**Terminalde ne görmelisin:** 1. adımda sütun listesinde hem `url` hem `target_url` var (expand uygulanmış). 3. adımda
`ALTER TABLE`, ardından oluşturma denemesi `{"error":"store_error",…} → 503`: çalışan pod'lar hâlâ `url` sütununa yazıyor.
DB hataları `create` ve `get` için sıfırdan büyük (önbellekte olmayan okumalar da düşüyor). İkinci terminalin özet
satırında (`k6 lvl12: …`) `5xx` sıfırdan büyük. 4. adımdan sonra sütun listesinde yine `url`, oluşturma `{"code":"…",…} → 201`.

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl12&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl12&from=now-15m&to=now&refresh=10s) — script "sütun yeniden adlandırıldı" dediği anda aç; kırık pencere ~25 sn sürer (giriş: admin / ladder)
- "İstek / saniye (durum koduna göre)" → pencere boyunca bir `503` çizgisi (uygulamanın `store_error` cevabı); sütun eski adına dönünce kaybolur.
- "5xx (uç noktaya göre)" → hata ağırlıkla `/api/links` rotasında (INSERT var olmayan `url` sütununa yazıyor); önbellekte olmayan kodlara yapılan `/{code}` okumaları da düşer.
- "Oluşturma sonuçları" → pencere boyunca `ok`'un yerini `error` alır; "Yönlendirme sonuçları"nda da `error` serisi belirir.
- Explore'da: `sum by (op) (rate(db_queries_total{namespace="lvl12",result="error"}[1m]))` → `create` ve `get` için aynı pencerede tepe. `05 · Postgres` → "Veritabanı sorguları (türe göre)" başarı ile hatayı toplar (`result`'a göre ayırmaz); hatayı bu sorguyla görürsün.

**Güvenli biçim üç dağıtımdır** (`migrations/006_expand.sql` yorumunda tam olarak yazıyor):
1. **EXPAND** — yeni sütunu ekle, her ikisine de yaz
2. **MIGRATE** — geriye doldur, okumayı yeniye çevir
3. **CONTRACT** — eskiye yazmayı bırak, sonra düşür

*Her adım bağımsız geri alınabilir. "Üç dağıtım fazla" diyorsan, bu deneyin 5xx sayısına bak.*

---

### P12-03 · Drift: elle yapılan değişiklik

**Belirti:** `kubectl scale` ile yapılan değişiklik çalışır, sonra bir sonraki `make deploy` onu
**sessizce** geri alır. Kim yaptı, neden yaptı — kayıt yok.
**Neden:** Manifest kaynaktadır; cluster ise canlı durumdur. İkisi arasında sürekli bir
karşılaştırma yoksa sapma görünmez. [Topic · Konu: GitOps, drift, self-heal]

**Reproduce (adım adım):**

Otomatik: `make repro P=P12-03` — Argo CD'nin bu namespace'i yönetip yönetmediğine bakar, redirect Rollout'unu elle 5
replikaya çıkarıp ~65 sn tutar (drift), sonra manifest'teki replika sayısını yeniden uygular ve drift'in sessizce
kaybolduğunu gösterir. Yeniden uygulamayı `make deploy` ile değil yalnızca replika alanını yamalayarak yapar: script 13'ün
`verify-prev`'inde de koşar ve orada 12'nin Makefile'ı başka bir seviyeyi kurardı.

Elle — sırayla yapıştır:

1. Grafana'yı temizle; Argo CD'nin bir Application'ı var mı, manifest ve küme kaç replika diyor:
```bash
make fresh
kubectl -n argocd get applications
kubectl kustomize deploy | awk '/^kind: Rollout$/{r=1} r&&/^  replicas:/{print $2; exit}'
kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
```
2. İKİNCİ bir terminalde Rollout'u izle (deney boyunca açık kalsın):
```bash
kubectl -n lvl12 get rollout redirect -w
```
3. İLK terminalde drift üret: elle 5 replikaya çık, panelin görebilmesi için ~65 sn tut:
```bash
kubectl -n lvl12 scale rollout/redirect --replicas=5
sleep 65
kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
```
4. Manifest'teki değeri yeniden uygula (scriptin yaptığı gibi yalnızca replika alanı) — drift sessizce kaybolur; ikinci
   terminaldeki izlemeyi sonra Ctrl+C ile durdur:
```bash
kubectl -n lvl12 patch rollout/redirect --type=merge -p '{"spec":{"replicas":3}}'
sleep 8
kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
```

**Terminalde ne görmelisin:** 1. adımda `No resources found in argocd namespace.` (kümeyi manifest'le sürekli
karşılaştıran kimse yok), ardından `3` ve `3`. 3. adımdan sonra küme `5` der, manifest hâlâ `3`; ikinci terminaldeki
izlemede `DESIRED` 3 → 5 olur. 4. adımdan sonra yine `3` ve izlemede `DESIRED` 5 → 3: elle yapılan değişiklik de, geri
alınması da hiçbir yerde kayıt bırakmadı.

**Grafana'da gör:** Grafana'da görünmez — drift bir metrik değil, iki kaynağın (manifest ↔ küme) farkıdır ve bu seviyede o farkı ölçen hiçbir şey yok. `13 · Rollout` → "Git ile uyumsuz uygulamalar (Argo CD)" **boş** kalır: Argo CD'nin metrikleri kazınıyor ama lvl12 için Application tanımlı değil — boş panel burada "her şey Git'teki gibi" değil, "karşılaştıran kimse yok" demektir. "Dağıtım aşaması (Argo Rollouts)" → `istenen replika` çizgisi script drift'i tutarken (~65 sn) 3 → 5 → 3 basamağı çizer: değişikliğin kendisi görünür, ama manifest'ten bir sapma olduğu, kimin yaptığı ve sessizce geri alındığı görünmez. Argo CD arayüzü (http://argocd.localtest.me, kullanıcı `admin`, şifre: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`) da lvl12 için bir uygulama göstermez — ölçülen eksik tam olarak bu görünürlük. Kanıt terminalde:
- `kubectl -n lvl12 get rollout redirect -w` (script koşarken, ikinci terminalde) → `DESIRED` 3 → 5 → 3: elle yapılan değişiklik ve sessizce geri alınması; hiçbir yerde kaydı kalmaz.
- `kubectl -n argocd get applications` → `No resources found`: kümeyi manifest'le sürekli karşılaştıran bir şey yok.

**Argo CD kurulu ama Application tanımlı değil — bilerek.** Elde bir GitOps zaten var
(manifest + `make up`). Argo'nun eklediği **üç şey**: (1) sürekli karşılaştırma (sen uygulamasan
da), (2) otomatik self-heal, (3) **görünürlük** — hangi kaynak neden farklı. Bu seviye üçünün de
yokluğunu ölçüyor; kurmak bir sonraki adım.

---

### P12-04 · `:latest` = belirsiz ve geri alınamaz sürüm

**Belirti/Beklenti:** Bu merdivende hiçbir imaj `:latest` kullanmıyor; her etiket
`<git-sha>-<kaynak-hash>`.
**Neden:** Mutable etiket, "deploy ettim değişmedi" ve "önceki sürüme dön" sorunlarını üretir.
[Topic · Konu: Değişmez artefakt]

**Reproduce (adım adım):**

Otomatik: `make repro P=P12-04` — çalışan etiketleri listeler, ReplicaSet geçmişinden geri
dönülebilirliği gösterir. Hükmü `:latest` kullanan imaj sayısına bakar: bu merdivende `NOT-REPRODUCED` beklenir.

Elle — sırayla yapıştır (yük yok; bu bir durum incelemesi):

1. Grafana'yı temizle, redirect pod'larının çalıştırdığı imaj etiketlerini ve kaçının `:latest` olduğunu gör:
```bash
make fresh
kubectl -n lvl12 get pods -l app.kubernetes.io/name=redirect -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u
kubectl -n lvl12 get pods -l app.kubernetes.io/name=redirect -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep -c ':latest'
```
2. Etiketin nasıl üretildiğine bak:
```bash
grep -nE '^(SHA|SRCHASH|TAG) ' ../ladder.mk
```
3. Geri dönülebilirlik: ReplicaSet geçmişi (eskiden yeniye) ve her birinin imajı:
```bash
kubectl -n lvl12 get replicaset -l app.kubernetes.io/name=redirect --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

**Terminalde ne görmelisin:** 1. adımda tek satır: `localhost:5001/linkly-ladder/12-redirect-svc:<git-sha>-<kaynak-hash>`
(git deposu yoksa `dev-<kaynak-hash>`), ardından `0`. 2. adımda `TAG` satırı `$(SHA)-$(SRCHASH)` der: kaynak değişmezse etiket
değişmez, değişirse yeni etiket üretilir. 3. adımda `redirect-<hash> → …:<etiket>` satırları (en fazla 4: güncel +
`revisionHistoryLimit: 3`). P12-01'i koştuysan aynı imajlı ikinci bir ReplicaSet görürsün: o sürüm imajla değil yalnızca
ortam değişkeniyle (`BAD_VERSION_ERROR_PCT`) ayrılıyordu — pod şablonu hash'i yine farklı, geri dönüş yine anlamlı.
`:latest` olsaydı bütün satırlar aynı etiketi gösterirdi ve bir geri alma hiçbir şeyi değiştirmezdi.

**Grafana'da gör:** [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl12&from=now-15m&to=now&refresh=10s) — istediğin an aç; bu sorun bir yük değil, bir durum (giriş: admin / ladder)
- "İstek / sn (sürüme göre)" → redirect için **tek bir hash çizgisi** (bir de api-svc'nin etiketsiz çizgisi): şu an tek ReplicaSet çalışıyor. Hash pod şablonunun özetidir ve imaj etiketini içerir; yeni bir etiketle dağıtımda geçiş boyunca iki hash görünür. `:latest` ile yeni imaj itilseydi şablon DEĞİŞMEZDİ: yeni hash yok, rollout yok — "deploy ettim değişmedi"nin panel hâli. Hangi imajın çalıştığını ise panel değil imaj etiketi söyler ↓
- Explore'da: `count by (image) (kube_pod_container_info{namespace="lvl12",container="redirect"})` → tek satır, etiket `…/12-redirect-svc:<git-sha>-<kaynak-hash>` biçiminde; `:latest` yok (bu yüzden script NOT-REPRODUCED der). Yeni bir imajla dağıtım sırasında aynı sorgu geçiş boyunca iki satır gösterir.
- Geri dönülebilirlik terminalde: `kubectl -n lvl12 get rs -l app.kubernetes.io/name=redirect -o 'custom-columns=RS:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'` → önceki ReplicaSet'ler ve imajları; `:latest` olsaydı hepsi aynı etiketi gösterirdi ve `undo` hiçbir şey değiştirmezdi.

**Bu bir tercih değil, bir zorunluluk:** **zaman damgalı** bir etiket, `make push` ile
`make deploy` ayrı çağrıldığında farklı etiket üretir ve pod `ImagePullBackOff`'a düşer
(`ladder.mk` yorumunda). **13'te Kyverno bunu policy hâline getirecek.**

---

### P12-05 · Canary + paylaşılan durum uyumsuzluğu

**Belirti (senaryo):** Yeni sürüm önbellek anahtar formatını değiştirirse, canary ve stable aynı
Redis'e farklı formatlarda yazar; iki taraf da ıska alır ve sistem aniden önbelleksiz davranır.
**Neden:** Canary'nin sessiz varsayımı iki sürümün yan yana çalışabilmesidir — paylaşılan durum
bu varsayımı kırar. [Topic · Konu: Uyumluluk sözleşmesi]

**Reproduce (adım adım):**

Otomatik: `make repro P=P12-05` — mevcut anahtar formatını ve hit oranını gösterir, format
değişiminin etkisini hesaplatır. Format değişimi gerçekten dağıtılmıyor: bu bir senaryo hesabı.

Elle — sırayla yapıştır:

1. Grafana'yı temizle, Redis pod'unu bul, önbellekteki örnek anahtarlara ve farklı anahtar öneklerine bak:
```bash
make fresh
rpod=$(kubectl -n lvl12 get pod -l app.kubernetes.io/name=redis -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty'); echo "redis: $rpod"
kubectl -n lvl12 exec "$rpod" -c redis -- redis-cli --scan --pattern 'linkly:link:*' | head -3
kubectl -n lvl12 exec "$rpod" -c redis -- redis-cli --scan --pattern 'linkly:*' | sed 's/:[^:]*$//' | sort -u | head -5
```
2. 30 sn redirect yükü ver, Redis katmanının (L2) isabet oranını oku:
```bash
make load S=redirect K6_ARGS="--vus 20 --duration 30s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(cache_ops_total{namespace="lvl12",layer="l2",result="hit"}[2m])) / clamp_min(sum(rate(cache_ops_total{namespace="lvl12",layer="l2"}[2m])),0.001)' | jq -r '"L2 isabet oranı: " + .data.result[0].value[1]'
```

**Terminalde ne görmelisin:** 1. adımda `linkly:link:<kod>` biçiminde anahtarlar (önbellek boşsa hiç satır yok; 2. adımdan
sonra tekrar bak) ve öneklerde `linkly:link` — yakın zamanda link oluşturulduysa bir de yazma sonrası okuma işareti
`linkly:ryw`. Tek bir anahtar formatı var: her pod diğerlerinin yazdığını okuyabiliyor. 2. adımda isabet oranı yüksek
(0 ile 1 arası bir oran). Canary anahtar önekini `linkly:link:v2:` yapsaydı canary'nin yazdığını stable, stable'ınkini
canary okuyamazdı: bu oran canary payıyla (burada pod sayısı, ~1/4) orantılı düşer ve DB yükü aynı oranda artardı.

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl12&from=now-15m&to=now&refresh=10s) — scriptin 30 sn'lik redirect yükü başlayınca aç (giriş: admin / ladder)
- "İsabet oranı (pod'a göre)" → yük boyunca her pod'da yüksek ve birbirine yakın: tek anahtar formatı (`linkly:link:*`), her pod diğerlerinin yazdığını okuyabiliyor. Format değişimi bu deneyde gerçekten dağıtılmıyor, yani düşüş **görmezsin** — gerçek bir format değişikliğinde bu çizgiler canary payıyla (burada pod sayısı: ~1/4) orantılı düşerdi.
- "Önbellek ıskası ve veritabanı sorguları" → iki çizgi de alçak ve birlikte hareket eder. Format değişiminde ikisi birlikte yükselir: aradaki fark, önbelleksiz kalan sistemin DB'ye bindirdiği yük.

**Üç seçenek:** geriye uyumlu format · geçiş döneminde iki formatı da okuma · canary'ye ayrı
önbellek (izole ama soğuk, P03-02'nin bedeli).
***Canary, paylaşılan her durum için bir uyumluluk sözleşmesi gerektirir*** — aynı akıl yürütme
kuyruk mesaj formatı (P06-07) ve DB şeması (P12-02) için de geçerli.

---

### P12-06 · Uygulama geri alındı, şema alınmadı

**Belirti:** "Rollback" tek bir şeymiş gibi konuşulur; aslında ikidir ve yalnızca biri otomatiktir.
**Neden:** Şemayı geri almak **ileri** bir işlemdir (yeni bir migration) ve veri kaybettirebilir.
[Topic · Konu: Sürüm uyumluluğu, runbook]

**Reproduce (adım adım):**

Otomatik: `make repro P=P12-06` — şema sürümü ile uygulama etiketini yan yana gösterir, her
migration'ın `Down` bloğunu kontrol eder, geri alınamayan değişiklik türlerini sayar.

Elle — sırayla yapıştır (yük yok; şemaya yalnızca okuma):

1. Grafana'yı temizle, CNPG primary'sinden şema sürümünü, Rollout'tan uygulama imajını oku:
```bash
make fresh
prim=$(kubectl -n lvl12 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty'); echo "primary: $prim"
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT max(version_id) FROM goose_db_version'
kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```
2. Her migration'ın `Down` bloğuna bak, geri almanın veri silip silmediğini say (`DROP TABLE` / `DROP COLUMN` /
   `TRUNCATE` → 1):
```bash
grep -A2 '+goose Down' internal/store/migrations/*.sql
for f in internal/store/migrations/*.sql; do printf '%-28s ' "$(basename "$f")"; sed -n '/+goose Down/,$p' "$f" | grep -icE 'drop +(column|table)|truncate'; done
```

**Terminalde ne görmelisin:** 1. adımda şema sürümü `6` (migrate Job'ı `MIGRATE_TARGET=6`'ya, expand adımına kadar
koşuyor) ve uygulama imajı `…/12-redirect-svc:<etiket>`: iki sayı birbirinden bağımsız ve hiçbir yerde birbirine bağlı
değil. 2. adımda her dosyanın Down bloğu dolu; sayım `001_links.sql`, `003_clicks.sql`, `004_event_dedup.sql`,
`005_clicks_partition.sql` ve `006_expand.sql` için `1` (Down, Up'tan bu yana yazılan veriyi siler), yalnızca
`002_tenant_index.sql` için `0` (indeks türetilmiş veridir, yeniden kurulur). Script aynı sayımı
`6 migration · geri alma bloğu olmayan: 0 · geri alması veri kaybettiren: 5` diye basar.

**Grafana'da gör:** Grafana'da görünmez — şema sürümü ile uygulama sürümü hiçbir metrikte yan yana durmuyor; sorunun kendisi de bu: ikisini bağlayan bir kayıt yok. (`13 · Rollout` → "Dağıtım aşaması (Argo Rollouts)" uygulamanın fazını gösterir, şemanınkini değil.) Kanıt terminalde:
- `kubectl -n lvl12 exec $(kubectl -n lvl12 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o name) -c postgres -- psql -U postgres -d linkly -tAc 'SELECT max(version_id) FROM goose_db_version'` → şema sürümü: tek bir sayı.
- `kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.template.spec.containers[0].image}'` → uygulama etiketi `<git-sha>-<kaynak-hash>`: şema sürümüyle hiçbir bağı yok.
- `grep -A2 '+goose Down' internal/store/migrations/*.sql` → Down bloklarında `DROP TABLE` / `DROP COLUMN`: "geri alma", Up'tan bu yana yazılan veriyi siler.

**Pratik kural:** Bir sürümde yalnızca **geriye uyumlu** şema değişikliği yap; böylece uygulamayı
geri almak şemayı geri almayı **gerektirmez**.
**Runbook'a yazılacak cümle:** *"Uygulama geri alındığında şema ileri kalır ve bu sorun değildir,
çünkü N−1 sürümü N şemasıyla çalışabilir."* Bu cümleyi yazamıyorsan, migration'ın güvenli değil.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `BAD_VERSION_ERROR_PCT` | Kasıtlı bozuk sürüm üretir | `make repro P=P12-01` | 0'a döndür |
| *(bayrak yok — deneyin kendisi)* | Kırıcı `RENAME COLUMN` **doğrudan `psql` ile** uygulanır ve geri alınır. Bayrak değil, çünkü onu okuyabilecek bir kod yolu yok: rename uygulamanın değil şemanın işi. Migration dosyası da değil, çünkü sıradaki bir migration'ı 13/14 RLS adımına giderken yolda uygular ve kendi şemalarını bozar. | `CONFIRM=1 make repro P=P12-02` | expand/contract |
| `TRAP_TENANT_LABEL` · `TRAP_REGEX_PER_REQUEST` | (11'den devam) | 11'de | — |

Elle denemeye değer:
- `AnalysisTemplate`'teki `successCondition`'ı `<= 0.5` yap ve P12-01'i tekrar koş: analiz artık
  kötü sürümü **geçirir**. *Bir güvenlik mekanizmasının eşiği yanlışsa, mekanizma yok demektir —
  hatta daha kötü: var olduğunu sanırsın.*
- `initialDelay`'i kaldır: analiz henüz veri yokken çalışır ve `no data` ile ya hep geçer ya hep
  düşer (provider'a göre). **Ölçüm başlamadan karar veren bir kapı, kapı değildir.**
- `steps` listesine `pause: {}` (süresiz) ekle: manuel onay kapısı. Otomatik analiz ile manuel
  onayı karşılaştır — hangisi daha hızlı, hangisi daha güvenli?
- Rename'i `007_…sql` adlı bir migration olarak yaz, `MIGRATE_TARGET=7` ile Job üzerinden uygula
  (P02-07'nin altyapısıyla) ve P12-02'yi tekrar koş: şema değişikliğinin **dağıtım sırasındaki** yeri
  neden önemli, ölç. Bitince dosyayı sil — sırada kalırsa 13/14 onu da uygular.

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl12&from=now-15m&to=now) | **Dolu** ✨ | "İstek / sn", "Hata oranı", "p99 süre" (sürüme göre): redirect'in ServiceMonitor'ü pod'un `rollouts-pod-template-hash` etiketini her seriye taşıyor (`podTargetLabels`), stable ve canary ayrı çizgi. Stable hash: `kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.stableRS}'`, diğeri canary; etiketsiz çizgi api-svc. "Dağıtım aşaması (Argo Rollouts)" Argo'nun kendi metriğinden (`rollout_info`). "Git ile uyumsuz uygulamalar (Argo CD)" **boş**: Application tanımlı değil (P12-03) |
| [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl12&from=now-15m&to=now) | Dolu | Canary hatası burn-rate'e de yansır — *iki mekanizma aynı olayı farklı zaman ölçeğinde görür* |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl12&from=now-15m&to=now) | Dolu | Sürüme göre **kırılmaz** (uygulama metriklerinde `version` etiketi yok); sürüm ayrımı `13 · Rollout`'ta, pod şablonu hash'iyle |
| [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl12&from=now-15m&to=now) · [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl12&from=now-15m&to=now) | Dolu | Önbelleğin Redis çağrıları Redis'in kendi guard'ından geçer (`dep="redis"`): "Uygulama → Redis gecikmesi (p99)" dolu, "Bağımlılık gecikmesi p99" `postgres` ve `redis`'i ayrı çizer; Redis kesintisinde "Azaltılmış mod (degrade)" `no_cache` gösterir, Postgres'inkinde `cache_only` |
| [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl12&from=now-15m&to=now) | Kısmen | 13'te dolacak |

Bu seviyenin okuma kuralı: **canary kararını verirken tek bir metriğe bakma.** Hata oranı düşük
ama p99 iki katına çıkmışsa sürüm yine kötüdür — bu yüzden `AnalysisTemplate` iki metrik içeriyor.

## 9. Bilerek bırakılanlar

- **Argo CD Application tanımlı değil** (P12-03'te gerekçesi): kurulum hazır, bağlamak bir adım.
- **Gitea kurulmadı**: cluster içi git deposu yok; GitOps kaynağı yerel manifest'ler.
- **api-svc hâlâ Deployment**: yalnızca redirect Rollout'a çevrildi. *Her servisi canary yapmak,
  her dağıtımı yavaşlatmaktır; trafiğin %99'unu taşıyan servis önceliklidir.*
- **Blue/green yok**: canary seçildi çünkü kademeli ölçüm sağlıyor.
- **Trafik yönlendirici yok**: canary payı pod sayısıyla belirleniyor (3 replikada 1 canary ≈ %25, `setWeight: 10`
  değil). Kesin yüzde için nginx canary ingress ya da service mesh gerekir: ikinci bir Service
  (`canaryService`/`stableService`), Argo'nun yönettiği canary Ingress, yük girişinin (`linkly-load`) de
  bağlanması ve analizin canary'ye özel sorguya çevrilmesi. Tek satırlık bir iş değil; bu seviye pod
  sayısıyla yetiniyor ve sayıları buna göre söylüyor (P12-01).
- **`/metrics` ingress arkasındaki portta**: redirect'in 8080'inde, ingress'in `/` yolunun gittiği yerde —
  dışarıdan erişilebilir. Profil uçları (`/debug/pprof`) bu yüzden ayrı bir iç portta (`:6060`,
  `PPROF_ADDR`): hiçbir Service/Ingress onu göstermiyor, yalnızca `kubectl port-forward` ya da API
  sunucusunun pod proxy'si ulaşır (`internal/httpapi/server.go` → `PprofHandler`). Üretimde `/metrics`
  de böyle bir yönetim portuna taşınır.
- **CI yok**: imaj derleme/tarama/test hattı `make` ile elle. `.github/workflows/ci.yml` var ama
  imaj yayınlamıyor.
- **CONTRACT adımı uygulanmadı**: `url` sütunu duruyor (expand yapıldı, contract sonraki sürümde).
  *Kullanılmayan bir sütun, bir sonraki okuyucunun tuzağıdır — ama erken düşürmek de kesintidir.*

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 11 ile farkı gösterir:

1. **`deploy/rollout.yaml`** (yeni): `Deployment` → `Rollout`. Asıl içerik `AnalysisTemplate`:
   **iki metrik, `initialDelay`, `failureLimit`** — üçü de yorumlarda gerekçelendirilmiş.
2. **`deploy/redirect-svc.yaml`**: artık yalnızca Service + ServiceMonitor + PDB. Rollout,
   Deployment'ın yerini aldı ama **Service değişmedi** — trafik yönlendirmesi controller'ın işi.
3. **`internal/store/migrations/006_expand.sql`**: kodun kendisi 2 satır, yorumu 20 satır.
   *Expand/contract bir SQL tekniği değil, bir dağıtım disiplinidir* — bu yüzden gerekçe kodda.
4. **Kırıcı rename bir migration DEĞİL, deneyin kendisi** (`problems/P12-02.sh` onu `psql` ile
   uygular ve geri alır). Migration sırasında dursaydı 13/14 — RLS adımına kadar koştukları için —
   yolda onu da uygulayıp `links.url` sütununu yeniden adlandırırdı: uygulama ayakta, her yazma
   `column url does not exist`, seviye hiç açılamaz. **Sıraya konmuş bir deney, deney olmaktan
   çıkıp herkesin ödediği bir bedele dönüşür.** Yanlışı sürüm kontrolünde tutmak doğru; onu
   herkesin koştuğu yola koymak değil.
5. **`internal/httpapi/handlers.go`**: `BAD_VERSION_ERROR_PCT`. Dağıtım güvenliğini test etmek
   için gerçekten bozuk bir sürüme ihtiyacın var.
