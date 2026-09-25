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

redirect-svc artık bir **Argo Rollout**: yeni sürüm önce tek bir **canary** pod'una (4 pod'dan biri, trafiğin ~1/4'ü)
gider ve adımlar arasında Prometheus'a bakan **otomatik analiz** kötü sürümü geri alır. Yanında şemanın dağıtımla uyumlu
kalması (**expand/contract**) ve kümenin manifest'ten sapması (**drift**) soruları var.

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

Kararı bir makine verir: analiz 30–60 sn'de karar verir. Trafik yönlendirici olmadığı için `setWeight: 10` pod sayısıyla
yaklaşık tutulur (3 stable + 1 canary, Service trafiği 4 pod'a eşit böler); sayılar bu yüzden "%10" değil "~%25".

## 3. Önceki seviyeden çözülenler

**Hiçbiri** — `problems/SOLVES` gerekçesini yazar: 12 canary ve GitOps getirir, 11'in sorunlarından birini kaldırmaz.
P11-07'nin (dashboard drift'i) disiplini uygulamaya genişler: manifest'ler kaynakta, elle yapılan değişiklik kalıcı olamaz (P12-03).

## 4. Ayağa kaldırma

İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **temel yığın (kind, ingress, Prometheus, Grafana) + Chaos Mesh, KEDA, CloudNativePG, Argo CD + Argo Rollouts**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/12-delivery"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvl12.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvl12.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvl12 — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=P12-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

Rollout'u izlemek için (komutları tek tek kullan; sonuncusu yalnızca `kubectl argo rollouts` eklentisi kuruluysa
çalışır, scriptler eklentiye dayanmaz):
```bash
cd "$LADDER/12-delivery"
kubectl -n lvl12 get rollout redirect -w
kubectl -n lvl12 get analysisrun
kubectl argo rollouts get rollout redirect -n lvl12 --watch
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler ve redirect
   Rollout'u `Healthy` olana kadar bekler; sonunda `✔ lvl12 ayakta` yazar:
```bash
cd "$LADDER/11-observability-deep"
make down
cd "$LADDER/12-delivery"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/12-delivery"
make up
```
2. 11'in sorunlarını burada koş (koşarken başka komut çalıştırma). 12 bunların hiçbirini çözmez: `BEKLENEN` sütunu her
   satırda `(açık kalabilir)` der:
```bash
cd "$LADDER/12-delivery"
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (P12-01 → P12-06): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç. Redirect bir Argo Rollout: ortamını `make set … W=redirect` /
   `make reset` değiştirir (`kubectl set env` Rollout'ta çalışmaz), ölçeğini
   `kubectl -n lvl12 scale rollout/redirect --replicas=N`, fazını
   `kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'` söyler.
4. Bitince ayarları geri al, Rollout'un `Healthy` olduğunu gör, seviyeyi kapat:
```bash
cd "$LADDER/12-delivery"
make reset
kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'; echo
make down
```

## 5. API

Her seviyede aynı: [docs/API.md](../docs/API.md).

Yeni bir operasyonel ayar: `BAD_VERSION_ERROR_PCT` kasıtlı bozuk bir sürüm üretir (varsayılan 0) — dağıtım güvenliğini
sınamak için gerçekten bozuk bir sürüm gerekir.

## 6. Reproduce edilebilir sorunlar

Her sorun aynı düzende: **Ne deniyoruz** (deneyin sorusu) → **Neden** → adımlar (her adım ne yaptığını söyler)
→ **Terminalde ne görmelisin** → **Grafana'da gör** (giriş: admin / ladder) → **Nerede çözülüyor**.
`make repro` hükmü: `REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` = ölçülemedi.

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

**Ne deniyoruz:** Redirect'lerin %25'inde hata veren bir sürüm dağıtılınca analiz onu canary'deyken yakalayıp geri alıyor mu?
**Neden:** Analiz 30 sn sonra ölçer, eşiği aşarsa dağıtımı durdurur (**abort**). Canary payı pod sayısıdır (1 canary +
3 stable ≈ 1/4) ve analiz namespace'in bütün `/{code}` trafiğinin 5xx oranını %2 eşiğiyle karşılaştırır — canary'nin
kendi %25'ini değil, toplamdaki ~%6'yı (%25 × 1/4) görür. Rolling update'te aynı oran %25'e kadar çıkardı.

**Reproduce (adım adım):** Otomatik: `make repro P=P12-01` (yük altında `BAD_VERSION_ERROR_PCT=25` ile dağıtır; fazı,
canary payını, canary'nin ve toplamın hata oranını basar; analizin metrikle mi altyapı hatasıyla mı durduğunu ayırır,
sonunda kötü sürümü geri alır). Elle:

1. Temiz başla; mevcut sürüm sağlıklı mı, stable pod şablonu hash'i ne:
```bash
cd "$LADDER/12-delivery"
make fresh
kubectl -n lvl12 get rollout redirect -o custom-columns=AŞAMA:.status.phase,HAZIR:.status.readyReplicas,GÜNCEL:.status.updatedReplicas
kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.stableRS}'; echo
```
2. İkinci bir terminalde 3 dk yük başlat (analiz ancak trafik varken bir şey ölçer):
```bash
cd "$LADDER/12-delivery"
make load S=redirect K6_ARGS="--vus 15 --duration 180s"
```
3. Yük başladıktan ~15 sn sonra ilk terminalde kötü sürümü dağıt (3 stable pod'un yanına 1 canary eklenir) ve fazı 4 sn'de
   bir bas; `Degraded` görünce döngü durur:
```bash
cd "$LADDER/12-delivery"
make set E="BAD_VERSION_ERROR_PCT=25" W=redirect
for i in $(seq 1 45); do p=$(kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'); echo "$((i*4)) sn: $p"; if [ "$p" = Degraded ]; then break; fi; sleep 4; done
```
4. Analizin kararını ve gerekçesini oku, canary süresince toplam 5xx oranının tepesine bak:
```bash
cd "$LADDER/12-delivery"
kubectl -n lvl12 get analysisrun
kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.message}'; echo
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=max_over_time((sum(rate(http_requests_total{namespace="lvl12",route="/{code}",code=~"5.."}[30s])) / sum(rate(http_requests_total{namespace="lvl12",route="/{code}"}[30s])))[5m:10s])' | jq -r '"toplam 5xx oranı (tepe): " + .data.result[0].value[1]'
```
5. Yük bitince (özet satırı `k6 lvl12: …`) kötü sürümü geri al ve fazın `Healthy`'ye döndüğünü gör:
```bash
cd "$LADDER/12-delivery"
make reset
sleep 10
kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.phase}'; echo
```

**Terminalde ne görmelisin:** 1. adımda `Healthy 3 3` ve kısa bir hex hash. 3. adımda
`✔ rollout/redirect: BAD_VERSION_ERROR_PCT=25`, döngü önce `… sn: Progressing`, 30–60 sn sonra `… sn: Degraded`: kötü
sürüm canary'deyken durduruldu. `get analysisrun`'da en yeni koşu `Failed`, rollout mesajı `error-rate` metriğinin
başarısız olduğunu söyler (mesajda `unreachable` / `dial tcp` varsa analiz metrik okuyamadan düşmüştür — kötü sürümün
yakalandığı anlamına gelmez). Toplam 5xx tepesi ~`0.06`; özet satırındaki oran daha da düşük (kötü sürüm yalnızca abort'a
kadar trafikteydi). 5. adımdan sonra `Healthy`.

**Grafana'da gör:** [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl12&from=now-30m&to=now&refresh=10s) ve [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl12&from=now-30m&to=now&refresh=10s) — deney başlayınca aç; kötü sürüm ~15 sn sonra, karar 30–60 sn içinde
- "İstek / sn (sürüme göre)" → her çizgi bir pod şablonu hash'i: canary başlayınca yeni bir hash belirir ve toplamın ~1/4'ünü alır, abort'tan sonra kaybolur (stable hash: `kubectl -n lvl12 get rollout redirect -o jsonpath='{.status.stableRS}'`).
- "Hata oranı (sürüme göre)" → canary hash'i ~%25'e çıkar, stable 0'da kalır; analizin karar verdiği sayı bu değil, toplam.
- "Sunucu hatası oranı (5xx)" → canary süresince ~%6, abort'la sıfır: analizin %2 eşiğiyle karşılaştırdığı namespace geneli oran.
- "p99 süre (sürüme göre)" → iki hash yakın: kötü sürüm hızlı hata veriyor, gecikme analizi geçer; abort'u hata oranı tetikler.
- "Hazır pod (sürüme göre)" → yeni hash 1 pod'la belirir, stable 3'te kalır; abort'tan sonra yeni hash kaybolur.
- "İstek / saniye (durum koduna göre)" → `302`'nin yanında kısa ömürlü bir `500` çizgisi: kötü sürümün hatası.

**Nerede çözülüyor:** seviye içi (canary + analiz) — bedeli dağıtımın birkaç dakika sürmesi. Analizde `initialDelay: 30s`
olmadan henüz veri yokken karar verilir; `failureLimit` olmadan tek gürültülü ölçüm sağlıklı sürümü geri aldırır.

---

### P12-02 · Kırıcı migration

**Ne deniyoruz:** Yük altında bir sütunun adı değiştirilince (`RENAME COLUMN`) çalışan kod ne yapar?
**Neden:** Dağıtım sırasında iki sürüm bir arada yaşar; her şema değişikliği hem eski hem yeni kodla uyumlu olmak zorundadır.

**Reproduce (adım adım):** Otomatik: `CONFIRM=1 make repro P=P12-02` (yük altında primary'de `psql` ile
`ALTER TABLE links RENAME COLUMN url TO url_old` koşar, hata penceresini ölçer, sütunu eski adına döndürür; `CONFIRM=1`
şemaya dokunan yıkıcı deney onayı). Elle — **dikkat:** 3. adım canlı şemayı bozar, 4. adımı atlama (atlanırsa her link
oluşturma `503` dönmeye devam eder):

1. Temiz başla; Postgres primary pod'unu bul, `links` tablosunun sütunlarına bak:
```bash
cd "$LADDER/12-delivery"
make fresh
prim=$(kubectl -n lvl12 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty'); echo "primary: $prim"
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='links'"
```
2. İkinci bir terminalde 90 sn karışık yük (okuma + oluşturma) başlat:
```bash
cd "$LADDER/12-delivery"
make load S=mixed K6_ARGS="--vus 15 --duration 90s"
```
3. Yük başladıktan ~15 sn sonra ilk terminalde kırıcı migration'ı uygula, bir link oluşturmayı dene, ~20 sn sonra DB hatalarını oku:
```bash
cd "$LADDER/12-delivery"
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'ALTER TABLE links RENAME COLUMN url TO url_old'
curl -s -XPOST http://lvl12.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p1202"}' -w ' → %{http_code}\n'
sleep 20
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum by (op) (increase(db_queries_total{namespace="lvl12",result="error"}[3m]))' | jq -r '.data.result[] | "\(.metric.op): \(.value[1])"'
```
4. Geri al: sütunu eski adına döndür, şemaya ve oluşturmaya tekrar bak:
```bash
cd "$LADDER/12-delivery"
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'ALTER TABLE links RENAME COLUMN url_old TO url'
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='links'"
curl -s -XPOST http://lvl12.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/p1202"}' -w ' → %{http_code}\n'
```

**Terminalde ne görmelisin:** 1. adımda hem `url` hem `target_url` var (expand uygulanmış). 3. adımda `ALTER TABLE`,
ardından oluşturma `{"error":"store_error",…} → 503`: çalışan pod'lar hâlâ `url` sütununa yazıyor. DB hataları `create`
ve `get` için sıfırdan büyük; yük özetinde `5xx` > 0. 4. adımdan sonra yine `url`, oluşturma `{"code":"…",…} → 201`.

**Grafana'da gör:** [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl12&from=now-15m&to=now&refresh=10s) ve [`03 · App Business`](http://grafana.localtest.me/d/ladder-app-business?var-level=lvl12&from=now-15m&to=now&refresh=10s) — sütun yeniden adlandırılınca aç; kırık pencere ~25 sn
- "İstek / saniye (durum koduna göre)" → pencere boyunca bir `503` çizgisi; sütun geri dönünce kaybolur.
- "5xx (uç noktaya göre)" → hata çoğunlukla `/api/links`'te; önbellekte olmayan `/{code}` okumaları da düşer.
- "Oluşturma sonuçları" → pencere boyunca `ok`'un yerini `error` alır.
- Explore'da: `sum by (op) (rate(db_queries_total{namespace="lvl12",result="error"}[1m]))` → `create` ve `get` için aynı pencerede tepe.

**Nerede çözülüyor:** seviye içi (expand/contract, `migrations/006_expand.sql`) — güvenli biçim üç dağıtım:
**EXPAND** (yeni sütunu ekle, ikisine de yaz) → **MIGRATE** (geriye doldur, okumayı yeniye çevir) → **CONTRACT** (eskiye
yazmayı bırak, sonra düşür); her adım ayrı geri alınabilir.

---

### P12-03 · Drift: elle yapılan değişiklik

**Ne deniyoruz:** Kümede elle yapılan bir değişikliği (`kubectl scale`) biri fark ediyor mu?
**Neden:** Manifest kaynakta, küme canlı durumda; ikisini sürekli karşılaştıran bir şey yoksa sapma (drift) görünmez ve
bir sonraki uygulama onu sessizce geri alır.

**Reproduce (adım adım):** Otomatik: `make repro P=P12-03` (Argo CD bu namespace'i yönetiyor mu bakar, Rollout'u elle 5
replikaya çıkarıp ~65 sn tutar, sonra manifest'teki replika sayısını yamalayıp drift'in sessizce kaybolduğunu gösterir). Elle:

1. Temiz başla; Argo CD'nin bir Application'ı var mı, manifest ve küme kaç replika diyor:
```bash
cd "$LADDER/12-delivery"
make fresh
kubectl -n argocd get applications
kubectl kustomize deploy | awk '/^kind: Rollout$/{r=1} r&&/^  replicas:/{print $2; exit}'
kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
```
2. İkinci bir terminalde Rollout'u izle, açık bırak:
```bash
cd "$LADDER/12-delivery"
kubectl -n lvl12 get rollout redirect -w
```
3. İlk terminalde drift üret: elle 5 replikaya çık, ~65 sn tut:
```bash
cd "$LADDER/12-delivery"
kubectl -n lvl12 scale rollout/redirect --replicas=5
sleep 65
kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
```
4. Manifest'teki değeri yeniden uygula — drift sessizce kaybolur (sonra izlemeyi Ctrl+C ile durdur):
```bash
cd "$LADDER/12-delivery"
kubectl -n lvl12 patch rollout/redirect --type=merge -p '{"spec":{"replicas":3}}'
sleep 8
kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.replicas}'; echo
```

**Terminalde ne görmelisin:** 1. adımda `No resources found in argocd namespace.` (kümeyi manifest'le karşılaştıran kimse
yok), sonra `3` ve `3`. 3. adımdan sonra küme `5`, manifest hâlâ `3`; izlemede `DESIRED` 3 → 5. 4. adımdan sonra yine
`3`, izlemede 5 → 3: değişiklik de geri alınması da hiçbir yerde kayıt bırakmadı.

**Grafana'da gör:** Grafana'da görünmez — drift bir metrik değil, manifest ile kümenin farkı; bu seviyede o farkı ölçen yok (Argo CD kurulu ama lvl12 için Application tanımlı değil). `13 · Rollout` → "Hazır pod (sürüme göre)" 3 → 5 → 3 basamağını çizer ama bunun bir sapma olduğunu, kimin yaptığını göstermez. Kanıt terminalde:
- `kubectl -n lvl12 get rollout redirect -w` (ikinci terminalde) → `DESIRED` 3 → 5 → 3; kaydı kalmaz.
- `kubectl -n argocd get applications` → `No resources found`: sürekli karşılaştıran bir şey yok.

**Nerede çözülüyor:** Argo CD (kurulu, Application bilerek tanımsız) — eklediği üç şey: sürekli karşılaştırma, otomatik
düzeltme (self-heal) ve hangi kaynağın neden farklı olduğunun görünürlüğü.

---

### P12-04 · `:latest` = belirsiz ve geri alınamaz sürüm

**Ne deniyoruz:** Çalışan imajların etiketi değişmez mi, önceki sürüme dönülebiliyor mu?
**Neden:** `:latest` gibi değişebilen bir etiket "dağıttım ama değişmedi" ve "önceki sürüme dön" sorunlarını üretir; bu
merdivende her etiket `<git-sha>-<kaynak-hash>`.

**Reproduce (adım adım):** Otomatik: `make repro P=P12-04` (çalışan etiketleri listeler, ReplicaSet geçmişinden geri
dönülebilirliği gösterir; hüküm `:latest` kullanan imaj sayısına bakar — bu merdivende `NOT-REPRODUCED` beklenir). Elle
(yük yok; durum incelemesi):

1. Temiz başla; redirect pod'larının imaj etiketleri ve kaçının `:latest` olduğu:
```bash
cd "$LADDER/12-delivery"
make fresh
kubectl -n lvl12 get pods -l app.kubernetes.io/name=redirect -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u
kubectl -n lvl12 get pods -l app.kubernetes.io/name=redirect -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep -c ':latest'
```
2. Etiketin nasıl üretildiği:
```bash
cd "$LADDER/12-delivery"
grep -nE '^(SHA|SRCHASH|TAG) ' ../ladder.mk
```
3. Geri dönülebilirlik: ReplicaSet geçmişi (eskiden yeniye) ve imajları:
```bash
cd "$LADDER/12-delivery"
kubectl -n lvl12 get replicaset -l app.kubernetes.io/name=redirect --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

**Terminalde ne görmelisin:** 1. adımda tek satır `localhost:5001/linkly-ladder/12-redirect-svc:<git-sha>-<kaynak-hash>`
(git deposu yoksa `dev-<kaynak-hash>`), sonra `0`. 2. adımda `TAG` `$(SHA)-$(SRCHASH)`: kaynak değişmezse etiket de
değişmez. 3. adımda en fazla 4 `redirect-<hash> → …:<etiket>` satırı (güncel + `revisionHistoryLimit: 3`). P12-01'i
koştuysan aynı imajlı ikinci bir ReplicaSet görürsün (fark yalnızca ortam değişkeni). `:latest` olsaydı bütün satırlar
aynı etiketi gösterir, geri alma hiçbir şey değiştirmezdi.

**Grafana'da gör:** [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl12&from=now-15m&to=now&refresh=10s) — istediğin an aç; bu bir yük değil, bir durum
- "İstek / sn (sürüme göre)" → tek hash çizgisi: tek ReplicaSet çalışıyor. `:latest` ile yeni imaj itilseydi pod şablonu değişmez, yeni hash ve rollout olmazdı.
- Explore'da: `count by (image) (kube_pod_container_info{namespace="lvl12",container="redirect"})` → tek satır, etiket `…/12-redirect-svc:<git-sha>-<kaynak-hash>`; `:latest` yok.

**Nerede çözülüyor:** 13 (Kyverno bunu kural yapar). Zaman damgalı etiket de yanlış olurdu: `make push` ile `make deploy`
ayrı çağrılınca farklı etiket üretir ve pod `ImagePullBackOff`'a düşer.

---

### P12-05 · Canary + paylaşılan durum uyumsuzluğu

**Ne deniyoruz:** Yeni sürüm önbellek anahtar formatını değiştirseydi canary ile stable aynı Redis'i paylaşabilir miydi?
**Neden:** Canary, iki sürümün yan yana çalışabileceğini varsayar; paylaşılan durum (önbellek, kuyruk, şema) bu varsayımı
kırar — iki taraf birbirinin yazdığını okuyamaz ve sistem önbelleksiz kalır.

**Reproduce (adım adım):** Otomatik: `make repro P=P12-05` (mevcut anahtar formatını ve isabet oranını gösterir, format
değişiminin etkisini hesaplar; format değişimi gerçekten dağıtılmaz, bu bir senaryo hesabı). Elle:

1. Temiz başla; Redis pod'unu bul, örnek anahtarlara ve anahtar öneklerine bak:
```bash
cd "$LADDER/12-delivery"
make fresh
rpod=$(kubectl -n lvl12 get pod -l app.kubernetes.io/name=redis -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty'); echo "redis: $rpod"
kubectl -n lvl12 exec "$rpod" -c redis -- redis-cli --scan --pattern 'linkly:link:*' | head -3
kubectl -n lvl12 exec "$rpod" -c redis -- redis-cli --scan --pattern 'linkly:*' | sed 's/:[^:]*$//' | sort -u | head -5
```
2. 30 sn redirect yükü ver, Redis katmanının (L2) isabet oranını oku:
```bash
cd "$LADDER/12-delivery"
make load S=redirect K6_ARGS="--vus 20 --duration 30s"
sleep 10
curl -s 'http://prometheus.localtest.me/api/v1/query' --data-urlencode 'query=sum(rate(cache_ops_total{namespace="lvl12",layer="l2",result="hit"}[2m])) / clamp_min(sum(rate(cache_ops_total{namespace="lvl12",layer="l2"}[2m])),0.001)' | jq -r '"L2 isabet oranı: " + .data.result[0].value[1]'
```

**Terminalde ne görmelisin:** 1. adımda `linkly:link:<kod>` anahtarları (boşsa 2. adımdan sonra tekrar bak) ve öneklerde
`linkly:link` (varsa `linkly:ryw`): tek format, her pod diğerlerinin yazdığını okuyabiliyor. 2. adımda isabet oranı
yüksek (0–1 arası). Canary öneki `linkly:link:v2:` yapsaydı bu oran canary payıyla (~1/4) orantılı düşer, DB yükü aynı
oranda artardı.

**Grafana'da gör:** [`04 · Cache`](http://grafana.localtest.me/d/ladder-cache?var-level=lvl12&from=now-15m&to=now&refresh=10s) — 30 sn'lik yük başlayınca aç
- "İsabet oranı (pod'a göre)" → her pod'da yüksek ve birbirine yakın: tek anahtar formatı. Format değişimi dağıtılmadığı için düşüş görmezsin; gerçek bir değişiklikte canary payıyla orantılı düşerdi.
- "Önbellek ıskası ve veritabanı sorguları" → iki çizgi alçak ve birlikte hareket eder; format değişiminde ikisi birlikte yükselirdi.

**Nerede çözülüyor:** tartışma — üç seçenek: geriye uyumlu format, geçişte iki formatı da okumak, canary'ye ayrı (soğuk)
önbellek. Canary, paylaşılan her durum için bir uyumluluk sözleşmesi ister (kuyruk formatı P06-07, şema P12-02).

---

### P12-06 · Uygulama geri alındı, şema alınmadı

**Ne deniyoruz:** Uygulamayı geri almak şemayı da geri alıyor mu?
**Neden:** "Geri alma" iki ayrı iştir ve yalnızca uygulamanınki otomatiktir; şemayı geri almak ileri yönde yeni bir
migration'dır ve veri kaybettirebilir.

**Reproduce (adım adım):** Otomatik: `make repro P=P12-06` (şema sürümü ile uygulama etiketini yan yana gösterir, her
migration'ın geri alma (`Down`) bloğunu kontrol eder, veri kaybettiren geri almaları sayar). Elle (yük yok; şemaya yalnızca okuma):

1. Temiz başla; primary'den şema sürümünü, Rollout'tan uygulama imajını oku:
```bash
cd "$LADDER/12-delivery"
make fresh
prim=$(kubectl -n lvl12 get pod -l cnpg.io/cluster=pg,cnpg.io/instanceRole=primary -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty'); echo "primary: $prim"
kubectl -n lvl12 exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc 'SELECT max(version_id) FROM goose_db_version'
kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```
2. Her migration'ın `Down` bloğuna bak, geri almanın veri silip silmediğini say (`DROP TABLE` / `DROP COLUMN` / `TRUNCATE` → 1):
```bash
cd "$LADDER/12-delivery"
grep -A2 '+goose Down' internal/store/migrations/*.sql
for f in internal/store/migrations/*.sql; do printf '%-28s ' "$(basename "$f")"; sed -n '/+goose Down/,$p' "$f" | grep -icE 'drop +(column|table)|truncate'; done
```

**Terminalde ne görmelisin:** 1. adımda şema sürümü `6` ve uygulama imajı `…/12-redirect-svc:<etiket>`: iki sayı
birbirinden bağımsız, hiçbir yerde bağlı değil. 2. adımda her Down bloğu dolu; sayım `001_links.sql`,
`003_clicks.sql`, `004_event_dedup.sql`, `005_clicks_partition.sql` ve `006_expand.sql` için `1` (geri alma, sonradan
yazılan veriyi siler), yalnızca `002_tenant_index.sql` için `0` (indeks yeniden kurulur). Script:
`6 migration · geri alma bloğu olmayan: 0 · geri alması veri kaybettiren: 5`.

**Grafana'da gör:** Grafana'da görünmez — şema sürümü ile uygulama sürümü hiçbir metrikte yan yana durmuyor; sorun da bu: ikisini bağlayan kayıt yok. Kanıt terminalde:
- `kubectl -n lvl12 get rollout redirect -o jsonpath='{.spec.template.spec.containers[0].image}'` → uygulama etiketi; şema sürümüyle bağı yok.
- `grep -A2 '+goose Down' internal/store/migrations/*.sql` → Down bloklarında `DROP TABLE` / `DROP COLUMN`: geri alma veri siler.

**Nerede çözülüyor:** disiplin — bir sürümde yalnızca geriye uyumlu şema değişikliği yap; böylece uygulamayı geri almak
şemayı geri almayı gerektirmez ("N−1 sürümü N şemasıyla çalışır").

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|
| `BAD_VERSION_ERROR_PCT` | Kasıtlı bozuk sürüm üretir | `make repro P=P12-01` | 0'a döndür |
| *(bayrak yok — deneyin kendisi)* | Kırıcı `RENAME COLUMN` doğrudan `psql` ile uygulanır ve geri alınır: rename kodun değil şemanın işi; migration dosyası olsaydı 13/14 onu da uygulardı | `CONFIRM=1 make repro P=P12-02` | expand/contract |
| `TRAP_TENANT_LABEL` · `TRAP_REGEX_PER_REQUEST` | (11'den devam) | 11'de | — |

Elle denemeye değer:
- `AnalysisTemplate`'teki `successCondition`'ı `<= 0.5` yap, P12-01'i tekrar koş: analiz kötü sürümü geçirir — eşiği yanlış bir güvenlik mekanizması yok hükmündedir.
- `initialDelay`'i kaldır: analiz veri yokken çalışır ve ya hep geçer ya hep düşer.
- `steps` listesine `pause: {}` ekle: manuel onay kapısı; otomatik analizle hız ve güvenliği karşılaştır.
- Rename'i `007_…sql` migration'ı olarak yaz, `MIGRATE_TARGET=7` ile uygula ve P12-02'yi tekrar koş; bitince dosyayı sil (13/14 onu da uygular).

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|
| [`13 · Rollout`](http://grafana.localtest.me/d/ladder-rollout?var-level=lvl12&from=now-15m&to=now) | **Dolu** ✨ | Sürüme (pod şablonu hash'ine) göre istek, hata oranı, p99 ve hazır pod; stable ve canary ayrı çizgi. api-svc sürümsüz, bu panellerde yok |
| [`12 · SLO`](http://grafana.localtest.me/d/ladder-slo?var-level=lvl12&from=now-15m&to=now) | Dolu | Canary hatası burn-rate'e de yansır |
| [`02 · App RED`](http://grafana.localtest.me/d/ladder-app-red?var-level=lvl12&from=now-15m&to=now) | Dolu | Sürüme göre ayrılmaz; sürüm ayrımı `13 · Rollout`'ta |
| [`06 · Redis`](http://grafana.localtest.me/d/ladder-redis?var-level=lvl12&from=now-15m&to=now) · [`11 · Resilience`](http://grafana.localtest.me/d/ladder-resilience?var-level=lvl12&from=now-15m&to=now) | Dolu | Redis ve Postgres guard'ları ayrı çizilir |
| [`14 · Security`](http://grafana.localtest.me/d/ladder-security?var-level=lvl12&from=now-15m&to=now) | Kısmen | 13'te dolar |

Okuma kuralı: canary kararında tek metriğe bakma — hata oranı düşük ama p99 iki katıysa sürüm yine kötüdür; bu yüzden
analiz iki metrik içerir.

## 9. Bilerek bırakılanlar

- Argo CD Application tanımlı değil (P12-03): kurulum hazır, bağlamak bir adım.
- Küme içi git deposu (Gitea) yok; GitOps kaynağı yerel manifest'ler.
- api-svc hâlâ Deployment; yalnızca trafiğin çoğunu taşıyan redirect canary'li.
- Blue/green yok; canary kademeli ölçüm sağladığı için seçildi.
- Trafik yönlendirici yok: canary payı pod sayısıyla (~%25); kesin yüzde için nginx canary ingress ya da service mesh gerekir.
- `/metrics` ingress'in gittiği 8080'de; pprof ayrı iç portta (`:6060`, yalnızca port-forward ile).
- CI imaj yayınlamıyor; derleme/test `make` ile elle.
- CONTRACT adımı uygulanmadı: `url` sütunu duruyor (sonraki sürümde düşer).

## 10. `make diff-prev` okuma rehberi

`make diff-prev` 11 ile farkı gösterir:

1. `deploy/rollout.yaml` (yeni): `Deployment` → `Rollout`; asıl içerik `AnalysisTemplate` (iki metrik, `initialDelay`, `failureLimit`).
2. `deploy/redirect-svc.yaml`: yalnızca Service + ServiceMonitor + PDB; Service değişmedi, trafik controller'ın işi.
3. `internal/store/migrations/006_expand.sql`: 2 satır kod, 20 satır gerekçe — expand/contract bir dağıtım disiplini.
4. Kırıcı rename bir migration değil, deneyin kendisi (`problems/P12-02.sh`): sırada dursaydı 13/14 da uygular ve seviye açılmazdı.
5. `internal/httpapi/handlers.go`: `BAD_VERSION_ERROR_PCT`.
