# NN — <ad> · "<slogan>"

> **Bu seviyede ne yaşayacaksın?**
> - Okuyucunun bu seviyede kendi gözüyle göreceği 3-5 şey; her biri ilgili sorunun kimliğiyle (PNN-XX)
>
> **Bu seviye olmasa ne olur?** Bu seviyenin kapattığı acı, önceki seviyenin sorun kimlikleriyle.
>
> **Yeni gelen teknolojiler:** Bu seviyede ilk kez sahneye çıkan araçlar ([her biri tek cümleyle](../README.md#kullanılan-teknolojiler)).

<!-- Her seviyenin README'si başlıktan hemen sonra yukarıdaki giriş bloğunu, ardından bu 10 başlığı bu sırada taşır.
     4 ve 5 SABİT METİN: kelimesi kelimesine aynı. Girişte adı geçen her araç kök README'nin
     "Kullanılan teknolojiler" tablosunda bir satıra sahip olmalı. -->

## 1. Bu seviye ne?

Üç cümle: ne var, ne yok, neden.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress-nginx] --> A[linkly pod]
```

## 3. Önceki seviyeden çözülenler

| ID | Sorun | Nasıl çözüldü |
|---|---|---|
| Pxx-yy | … | … |

`problems/SOLVES` dosyası aynı listeyi makine-okunur tutar; `make verify-prev` bunu kullanır.

## 4. Ayağa kaldırma

<!-- SABİT METİN — değiştirme (yalnızca "istediği" listesini seviyeye göre doldur) -->
İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç) — platform bir kez kurulur (`cd platform && make full`).
Bu seviyenin platformdan istediği: **<profile.sh'taki bileşenler>**. `make up` ilk adımda (profil) bunları açar ve kullanılmayanları kapatır; bir bileşen kurulu değilse hangi komutla kurulacağını söyleyip durur.

```bash
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
code=$(curl -s -XPOST http://lvlNN.localtest.me/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .code); echo "$code"
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://lvlNN.localtest.me/$code   # 302 → https://example.com
make grafana       # Ladder klasörü, level=lvlNN — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=PNN-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: make -C ../platform stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.** Komut bloklarında açıklama yok; her bloğu olduğu gibi yapıştırabilirsin.

1. Önceki seviye açıksa kapat (aynı anda tek seviye çalışır), bu seviyeyi kur. `make up` Grafana'yı da temizler:
```bash
make -C ../<önceki-seviye-klasörü> down
make up
```
2. Önceki seviyenin sorunlarını bu seviyede koş. Koşarken başka komut çalıştırma: aynı pod'lara dokunurlar.
   Çıktıdaki `BEKLENEN` sütunu `NOT-REPRODUCED` diyorsa bu seviye o sorunu çözmüş olmalı:
```bash
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (PNN-01 → …). Her sorunda aynı düzen: **Elle** bloklarını sırayla yapıştır
   (ilk komut `make fresh`: Grafana bu deneye boş başlar) → **Terminalde ne görmelisin** ile karşılaştır →
   **Grafana'da gör** linklerini aç. İstersen aynı deneyi `make repro P=…` ile otomatik koş.
4. Bitince açık kalan ayarları geri al ve seviyeyi kapat:
```bash
make reset
make down
```

## 5. API

<!-- SABİT METİN — değiştirme -->
Her seviyede aynı: [docs/API.md](../docs/API.md).

## 6. Reproduce edilebilir sorunlar

| ID | Sorun | Reproduce | Grafana'da | Çözüm |
|---|---|---|---|---|
| PNN-01 | … | `make repro P=PNN-01` | dashboard → panel | seviye |

Her sorun için alt bölüm (docs/PROBLEM-TEMPLATE.md kalıbı):

### PNN-01 · <başlık>
**Belirti:** …
**Neden:** …
**Reproduce (adım adım):**

Otomatik — ölçer ve hüküm basar: `make repro P=PNN-01` (yıkıcı adım varsa `CONFIRM=1` ile; scriptin ne yaptığı, tek cümle).

Elle — sırayla yapıştır (bloklarda yorum YOK: varsayılan zsh `#`'i komutun argümanı yapar; açıklama adım metninde):

1. <adımın açıklaması>:
```bash
make fresh
<komutlar — host açık: http://lvlNN.localtest.me; değişkenler bu sorunun bloklarında tanımlı>
```
2. <açıklama; ayar/tuzak açıldıysa son adım geri alır: make reset · replika geri · make unchaos · kubectl uncordon>:
```bash
<komutlar>
```

**Terminalde ne görmelisin:** <her adımın çıktısında görülecek somut dizeler/sayılar: HTTP kodları, `k6 lvlNN: reqs=… 5xx=… 404=… 429=… p99=…`, kubectl çıktısı>
(tools/lint-guide.py: Otomatik + Elle + ilk komut `make fresh` + "Terminalde ne görmelisin", yorumsuz ve `bash -n`/`zsh -n` temiz bloklar)
**Grafana'da gör:** [`<NN · dashboard>`](http://grafana.localtest.me/d/<uid>?var-level=lvlNN&from=now-15m&to=now&refresh=10s) — <ne zaman aç> (giriş: admin / ladder)
- "<panelin TAM başlığı>" → <okuyucu ne görecek: yön/şekil/değer ve ne anlama geldiği>
- Explore'da: `<promql>` → <ne göreceksin>   (yalnızca hiçbir panel göstermiyorsa)
  Grafana'da görülemiyorsa: `**Grafana'da gör:** Grafana'da görünmez — <neden>. Kanıt terminalde:` + `- \`<komut>\` → <beklenen çıktı>`
  (tools/lint-grafana.py: dashboard ve panel adları GERÇEKTEN var olmalı)
**Nerede çözülüyor:** NN+1 (…). Geçici çare: …

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (ortamı `deploy/`'daki hâline döndürür; `make unset E=TRAP_X` yalnızca siler). Tablodaki diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar; komut hazır olunca döner. Varsayılan olarak seviyenin TÜM uygulama servislerine uygulanır (tek servis: `W=redirect`); 12'den itibaren Argo Rollout'larda da çalışır — `kubectl set env` orada çalışmaz. `make repro` scriptleri tuzağı KENDİLERİ açıp kapatır ve bitince ortamı eski hâline getirir (senin açtıkların dahil): elle alıştırma için `make set` + `make load`, otomatik ölçüm için `make repro`. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|

## 9. Bilerek bırakılanlar

- …

## 10. `make diff-prev` okuma rehberi

Diff'te neye bak: …
