# Devam notu — 23 Eylül 2026, 11:00

Bu dosya geçicidir: kaldığımız yeri ve sıradaki adımı tutar. İş bitince silinebilir.

## Durum özeti

Tam doğrulama turu (00→14) tamamlandı. 108 "kendi sorunu" scriptinden **86 REPRODUCED**,
17 NOT-REPRODUCED, 4 ATLANDI, 1 HATA. Sonuç tablosu ve 78 bulgunun tamamı
`docs/VERIFICATION.md`'de. Turda bulunan ölçüm hatalarının çoğu aynı tur içinde düzeltilip
yeniden koşuldu; lint kuralları 12-16 bu sınıfların geri gelmesini engelliyor.

Depo durumu: 15/15 lint temiz, gofmt temiz, çalışma ağacı temiz, tüm düzeltmeler commit'li.

## P14-05 — KÖK SEBEP BULUNDU (düzeltme commit'li, doğrulama YAPILMADI)

Rapor edilen sonuç "üç eşzamanlı arıza altında erişilebilirlik %4.37" idi. Sistem çökmemişti,
**hiç kurulmamıştı**. Zincir:

1. `profile.sh 14` Kyverno'yu park konumundan çıkarıyor ve **beklemeden dönüyor**.
2. Kyverno admission controller'ın varsayılan startup probe'u `timeout=1s period=6s failure=20`.
   Yüklü kümede HTTPS sağlık ucu 1 saniyede cevap veremiyor → kubelet öldürüyor → **crash loop**
   (7 restart gözlendi, `StartError exit=128`).
3. Kyverno webhook'u `failurePolicy: Fail`. Backend ayakta değilken **kümedeki her yazma**
   reddediliyor — Kyverno'yla ilgisi olmayanlar dahil.
4. local-path provisioner PVC'yi oluşturamıyor:
   `failed calling webhook "validate.kyverno.svc-fail": connection refused`.
5. `pg-1` PVC'si Pending → CNPG initdb Pending → **Postgres hiç kalkmıyor**.
6. redirect servisinin **hazır endpoint sayısı 0**; ingress her isteğe anında 503 dönüyor,
   k6 ~4300 rps dövüyor ve "646605 istek / 618336 adet 5xx" tablosu buradan çıkıyor.
   Uygulamanın kendi `http_requests_total`'ı **0** — yani uygulama hiç istek görmedi.

Doğrulama kanıtı: `/tmp/observe.log` (her 3 sn'de hazır endpoint / app rps / breaker / shed).
Tüm satırlarda `hazır=0` ve `app_rps=0`.

**Yapılan düzeltme (commit 3a4edfa):** `platform/Makefile` Kyverno'yu artık gevşek probe
bütçesiyle kuruyor (startup timeout 5s, period 10s, failure 30; readiness/liveness timeout 10s).
Canlı kümede aynı yama elle uygulandı ve Kyverno sağlıklı hâle geldi, PVC bağlandı.

### Sıradaki adım (tek cümle)
Küme yeniden kurulduktan sonra **14. seviyeyi tam olarak ayağa kaldırıp P14-05'i bir kez koş**;
bu kez `/tmp/observe.sh` ile birlikte koş ve şu iki soruyu ayrı ayrı cevapla:
- (a) Ölçü temiz mi? `hazır` endpoint > 0 ve `app_rps` > 0 olmalı. Değilse yine ortam sorunudur.
- (b) Korumalar devreye giriyor mu? `breaker`, `shed`, `degrade` sütunlarına bak.

### (b) için bilinen risk
Yük atma eşiği `SHED_MAX_INFLIGHT=200`. P10-06'da ölçüldü: in-flight ≈ rps × gecikme ve bu kümede
gecikme milisaniyeler mertebesinde, yani in-flight 200'e **hiç ulaşmıyor**. Game day'de de yük
atmanın hiç devreye girmemesinin muhtemel sebebi bu. Aynı zamanda breaker, yönlendirmeler
önbellekten karşılandığı için veritabanı hatası görmüyor olabilir — P14-05 ölçüyü
"uygulamanın kendi gördüğü istekler" üzerinden kurmalı, ingress'in 503 hızından değil.

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
- Game day gözlemcisi: `/tmp/observe.sh` → `/tmp/observe.log`
- Son tur kayıtları: `/tmp/sweep-full.log`, `/tmp/rerun.log`, `/tmp/final.log`, `/tmp/last.log`
- Açık madde listesi: `/tmp/RERUN-QUEUE.md`

> `/tmp` altındakiler yeniden başlatmada silinebilir; kalıcı olan her şey bu dosyada ve
> `docs/VERIFICATION.md`'de.
