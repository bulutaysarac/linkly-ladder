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

İki-üç kısa cümle: ne var, ne yok, neden. Uzun bağlam yok; ayrıntı sorunların içinde.

## 2. Mimari

```mermaid
flowchart LR
  C([client]) --> I[ingress-nginx] --> A[linkly pod]
```

## 3. Önceki seviyeden çözülenler

| ID | Sorun (sade dille) | Nasıl çözüldü (sade dille; teknik ad parantez içinde) |
|---|---|---|
| Pxx-yy | … | … |

`problems/SOLVES` dosyası aynı listeyi makine-okunur tutar; `make verify-prev` bunu kullanır.

## 4. Ayağa kaldırma

<!-- SABİT METİN — değiştirme (yalnızca "istediği" listesini seviyeye göre doldur) -->
İlk kez mi? Önce kök README'deki [Sıfırdan başlangıç](../README.md#sıfırdan-başlangıç): platform bir kez kurulur ve
`LADDER` (repo kökü) tanımlanır. Her komut bloğu `cd "$LADDER/…"` ile başlar; olduğu gibi yapıştır.
Bu seviyenin platformdan istediği: **<profile.sh'taki bileşenler>**; `make up` açar.

Hızlı başvuru (komutları tek tek kullan; satır sonu açıklamaları için zsh'da `setopt interactivecomments` gerekir):

```bash
cd "$LADDER/NN-<ad>"
make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke
make link          # example.com'a kısa link oluştur, yönlendirmeyi dene → 302 · başka adres: make link URL=https://…
make grafana       # Ladder klasörü, level=lvlNN — giriş: admin / ladder
make load S=mixed  # aynı senaryolar her seviyede: create redirect mixed hot-key burst abuser read-your-writes stairs scan
make repro P=PNN-01   # §6'daki bir sorunu otomatik üret → REPRODUCED / NOT-REPRODUCED
make env           # açık ayar/tuzaklar · değiştir: make set E="KEY=değer" · hepsini geri al: make reset (§7)
make down          # seviyeyi kaldır · kümeyi durdurmak için: cd "$LADDER/platform" && make stop
```

**Rehber — bu seviyeyi baştan sona, sırayla.**

1. Önceki seviyeyi kapat (aynı anda tek seviye), bu seviyeyi kur. `make up` Grafana'yı da temizler; sonunda
   `✔ lvlNN ayakta` yazar:
```bash
cd "$LADDER/<önceki-seviye-klasörü>"
make down
cd "$LADDER/NN-<ad>"
make up
```

**Verileri temizleyip sıfırdan koşmak istersen** 1. adımın yerine bunu kullan: bütün seviyelerin verisi
(linkler, veritabanı, önbellek, kuyruk) ve Grafana'nın gösterdiği metrik, trace, log silinir; küme ve kurulum
kalır (~2-3 dk). Ardından bu seviye temiz kurulur. Yalnızca Grafana çizgilerini temizlemek için (veri kalır)
seviye klasöründe `make fresh` yeter; her deneyin ilk komutu zaten bu.
```bash
cd "$LADDER"
make wipe CONFIRM=1
cd "$LADDER/NN-<ad>"
make up
```
2. Önceki seviyenin sorunlarını burada koş (koşarken başka komut çalıştırma). `BEKLENEN` sütunu
   `NOT-REPRODUCED` olan satırlar bu seviyenin çözdüğünü iddia ettikleri; sonuç uymazsa satır `✘` alır:
```bash
cd "$LADDER/NN-<ad>"
make verify-prev
```
3. §6'daki sorunları sırayla yaşa (PNN-01 → …): adımları yapıştır → **Terminalde ne görmelisin** ile
   karşılaştır → **Grafana'da gör** linklerini aç.
4. Bitince ayarları geri al ve seviyeyi kapat:
```bash
cd "$LADDER/NN-<ad>"
make reset
make down
```

## 5. API

<!-- SABİT METİN — değiştirme -->
Her seviyede aynı: [docs/API.md](../docs/API.md).

## 6. Reproduce edilebilir sorunlar

Bu seviyede yaşayacağın N sorun. Her birini iki yoldan görebilirsin: **Otomatik** — `make repro P=<ID>` deneyi
kendisi yapar, ölçer ve hükmünü basar (`REPRODUCED` = sorun var · `NOT-REPRODUCED` = yok · `SKIPPED` =
ölçülemedi); **Elle** — adımları sırayla yapıştırıp sonucu kendi gözünle görürsün. Her sorunun bölümü aynı
düzende: **Ne oluyor** → **Neden oluyor** → **Bu deney** → adımlar → **Terminalde ne görmelisin** →
**Grafana'da gör** (giriş: admin / ladder) → **Nasıl çözülüyor**.

<!-- Tablo, konuyu hiç bilmeyen birinin okuyup anlayacağı özet: terim kullanırsan parantez içinde açıkla. -->
**Kısa komut** deneyi otomatik başlatır; seviyenin klasöründe çalıştır (önce `cd "$LADDER/NN-<ad>"`). Başında
`CONFIRM=1` olanlar yıkıcı bir adım içerir (pod silmek, yeniden başlatmak, arıza enjekte etmek gibi); bu onay
olmadan script o adımı yapmaz ve `SKIPPED` basar.

<!-- Kısa komut, sorunun "Otomatik:" satırındaki komutun AYNISI. Seviyede CONFIRM=1'li sorun yoksa son cümleyi sil. -->
| ID | Kısa komut | Ne olur? | Neden olur? | Nasıl çözülür? |
|---|---|---|---|---|
| PNN-01 | `make repro P=PNN-01` | <kullanıcının/operatörün gördüğü, sade dille> | <kök neden, sade dille> | **NN+k:** <ne ile, sade dille> |

Her sorun için alt bölüm: [docs/PROBLEM-TEMPLATE.md](PROBLEM-TEMPLATE.md) kalıbı.

## 7. Seviye içi alıştırmalar (TRAP_ bayrakları)

> **Nasıl uygulanır:** aç `make set E="TRAP_X=true"` · ne açık? `make env` · hepsini geri al `make reset` (`make unset E=TRAP_X` yalnızca siler). Diğer ayarlar da aynı yolla (`make set E="CACHE_TTL=1h"`). Pod'lar yeni değerle yeniden başlar, komut hazır olunca döner; tek servis için `W=redirect`. `make repro` tuzakları kendisi açıp kapatır. Bitirince `make reset`: açık kalan bir tuzak sonraki deneyi sessizce bozar.

| Bayrak | Ne yapar | Reproduce | Düzeltme |
|---|---|---|---|

## 8. Gözlemlenebilirlik: hangi paneller dolu, hangileri boş

| Dashboard | Durum | Neden |
|---|---|---|

## 9. Bilerek bırakılanlar

- …

## 10. `make diff-prev` okuma rehberi

Diff'te neye bak: …
