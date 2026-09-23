# Devam notu — 23 Eylül 2026, 13:10

Bu dosya geçicidir: kaldığımız yeri ve sıradaki adımı tutar. İş bitince silinebilir.

## Durum özeti

Tam doğrulama turu (00→14) tamamlandı. 108 "kendi sorunu" scriptinden **86 REPRODUCED**,
17 NOT-REPRODUCED, 4 ATLANDI, 1 HATA. Sonuç tablosu ve 84 bulgunun tamamı
`docs/VERIFICATION.md`'de. Turda bulunan ölçüm hatalarının çoğu aynı tur içinde düzeltilip
yeniden koşuldu; lint kuralları 12-16 bu sınıfların geri gelmesini engelliyor.

Depo durumu: 15/15 lint temiz, gofmt temiz, 08-14 `go test -race` temiz. 12:30 itibarıyla değişiklikler commit'lenmedi.

## 23 Eylül öğleden sonra — ne değişti (ayrıntı: VERIFICATION 79-84)

1. **P14-05'in %4.37'si limiter'lardı, Kyverno değil** (79). 08-14'e yük testi kimliği eklendi:
   jetonlu, limitsiz `linkly-load` girişi; k6 varsayılan olarak onu kullanır, limiter'ı sınayan
   scriptler `limits_enforced` çağırır (lint 17). Uçtan uca doğrulandı.
2. **Game day artık sabit hızlı yük** (`steady.js`, 300 rps) (80); istemci/uygulama sayıları yan
   yana; game day öncesi breaker durumu okunuyor (84); kontrol düzlemi yeniden başlarsa exit 2.
3. **Canary analizi sağlıklı güncellemeleri geri alıyordu, `make wait` bunu "hazır" sayıyordu** (81).
   Sorgular ve `make wait` düzeltildi, doğrulandı.
4. **Ortam: kontrol düzlemi 170+ kez yeniden başlamış** (82). Lider kirası 60/45 sn, Kyverno
   fail-open ve helm'e taşındı (83). Kalan sorun kapasitenin kendisi: Mac 8 çekirdek, host yükü 14;
   Postgres primary'si probe zaman aşımıyla öldürülüp kendiliğinden failover yaptı.

## 13:08 — yerel deneme sonuçları (VERIFICATION 85-87)

- 300 rps'te küme çöktü: API sunucusu liveness'tan öldürüldü; script çıkınca k6 ölmüyordu (85, düzeltildi).
- **100 rps'te P14-05 ilk kez geçerli ölçüldü: %97.72, REPRODUCED** (86). Ama arızalar önbellek
  yüzünden istek yoluna neredeyse dokunmadı; korumaları sınamak için soğuk önbellek ya da
  kapasiteye yakın yük gerekiyor → uzak sunucu.
- Açık: `ensure_healthy` yanlış servisi yeniden başlatıyor (87).

## Sıradaki adım

**P14-05 bu makinede temiz ölçülemiyor** — ortam, game day'in enjekte ettiği arızaları kendisi
üretiyor. Kullanıcı uzak (ücretsiz) bir sunucu kiralamayı önerdi; orada:
- P14-05'i `tools/observe-gameday.sh` ile koş: `GAMEDAY_RATE=300` ve bir kez de SOĞUK önbellekle
  (game day başında Redis FLUSHALL + kısa L1_TTL), korumaların gerçekten devreye girdiği an görülsün.
- `ensure_healthy`'yi düzelt (87): serving() hangi servisi sınıyorsa onu yeniden başlatsın; tam turla doğrula.
- Muafiyetten etkilenen scriptleri yeniden koş: P09-02, P09-03, P10-02, P10-05, P11-04, P12-01,
  P12-02 (+ limiter'ı sınayan P08-01..06 ve P13-06'nın `limits_enforced` ile hâlâ REPRODUCED olduğunu doğrula).
- Tam tur. Not: ARM makinede imajlar ARM için derlenmeli; kurumsal TLS yoksa `trust-ca.sh` gereksiz.

Yerelde devam edilecekse: ölçümden önce `docker stats` ile dört düğümün toplamına bak (kubectl top
değil), ölçüm sırasında host'ta derleme/test koşma, CNPG `Cluster` fazının `Cluster in healthy state`
olduğunu doğrula.

## Diğer açık maddeler

| Ne | Durum |
|---|---|
| **P14-02** | L1_TTL=90s ve 3 replikayla bile "yayın kapalı" fazında bayat cevap 0/40. Tuzak kodda gerçek (kanal adı `linkly:invalidate:disabled` yapılıyor). Sıradaki adım: silme sonrası tek pod'a doğrudan okuyup `cache_ops_total{layer="l1",result="hit"}` artıyor mu bakmak. |
| **P11-08** | pprof profili pod proxy'sinden alınamıyor (`dial tcp <podIP>:8080: i/o timeout`). Script artık bunu "profil ALINAMADI" diye ayrı raporluyor. Ayrıca ölçülen CPU farkı (+%33) scriptin "yalnızca profilde görünür" teziyle çelişiyor; tez bu ölçekte yeniden düşünülmeli. |
| **P08-04** | 1. faz doğru çalışıyor (5706 istek reddedildi, kayan pencere 96/60). 2. faz hâlâ "0 kabul" raporluyor: `settle_rollout` eklendi ama örnekleme yine eski/yeni pod yarışına takılıyor olabilir. |
| **P14-01** | L1 isabet oranı %82 (mekanizma çalışıyor) ama p50 farkı gürültü mertebesinde (0.95 → 1.08 ms) ve hüküm `b <= a` istiyor. Hükümden p50 şartı kaldırılıp isabet oranına bırakılmalı — scriptin kendi yorumunda yazan "ölçüm çözünürlüğünün altındaki farka hüküm bağlama" kuralı burada hâlâ ihlal ediliyor. |

## Faydalı yollar

- Tur aracı: `tools/verify-sweep.sh <seviye> ...` (profil + up + verify-prev + kendi sorunları + down)
- Tek seviye/tek script: `/tmp/rerun-level.sh <seviye> <PNN-XX> ...` (profil adımı dahil)
- Game day gözlemcisi: `tools/observe-gameday.sh` → `/tmp/observe.log`
- Son tur kayıtları: `/tmp/sweep-full.log`, `/tmp/rerun.log`, `/tmp/final.log`, `/tmp/last.log`
- Açık madde listesi: `/tmp/RERUN-QUEUE.md`

> `/tmp` altındakiler yeniden başlatmada silinebilir; kalıcı olan her şey bu dosyada ve
> `docs/VERIFICATION.md`'de.
