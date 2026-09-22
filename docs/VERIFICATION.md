# Doğrulama günlüğü — merdiven gerçekten ölçüyor mu?

Bu dosya, merdivenin **kendi ölçüm araçlarının** doğrulanmasını kaydeder. Sorulan soru
"seviye ayakta mı?" değil: **"bu script, iddia ettiği şeyi gerçekten ölçüyor mu?"**

Bir reproduce scriptinin iki türlü yanlış olma yolu var ve ikincisi çok daha pahalı:

1. **Gürültülü yanlış** — script çöküyor, `HATA` basıyor. Fark edilir, düzeltilir.
2. **Sessiz yanlış** — script çalışıyor, bir sayı basıyor, bir karar veriyor ve karar
   **yanlış sebepten** doğru çıkıyor. Bu, doğrulanmış görünen bir yalandır.

Aşağıdaki liste ikinci türden bulunan hataları içeriyor. Hepsi "çalışıyor" görünüyordu.

---

## Bulunan sessiz yanlışlar

| # | Nerede | Ne oluyordu | Neden görünmüyordu |
|---|--------|-------------|--------------------|
| 1 | `kubectl set env` (98 çağrı, 12+ seviyeleri) | İstemci tarafı **tipli** komut; Argo Rollout'ta `no kind "Rollout" is registered` ile patlar. 12'den itibaren `redirect` bir Rollout. | Her TRAP anahtarı ve her temizlik 12/13/14'te öldü; `verify-prev` **değişmemiş** bir sistemi ölçüyordu ama yine karar basıyordu. |
| 2 | `promq` (tüm seviyeler) | Uzun sorgular (`histogram_quantile` + çok etiket) ingress'in URI sınırına takılıp 400 dönüyordu; `curl -f` gövdeyi attığı için geriye "curl 22" kalıyordu. | Script 0 okuyup "sorun yok" diyordu (P08-02, P11-01). |
| 3 | `k6run <senaryo> --duration` | `options.scenarios` tanımlı dosyalarda k6 **hiç başlamaz**: "using multiple execution config shortcuts is not supported". | Çağrı `\|\| true` ile sarmalı (başarısız yük koşusu normaldir); script 0 istek/0 ret okuyup "fark yok" diyordu (P08-01/03/06). |
| 4 | `TRAP_TENANT_LABEL` (11+) | Config'de tanımlı, kodda **hiç okunmuyor**. | Karar Prometheus'un TOPLAM seri sayısına bakıyordu; o sayı yoğun kümede kendi başına oynar → her koşuda "REPRODUCED". |
| 5 | `TRAP_FIXED_WINDOW` (08+) | Config'de tanımlı, kodda **hiç okunmuyor**; üstelik P08-04 tuzağı açmıyordu bile. | Script yalnızca kayan pencereyi ölçüp "sabit pencere olsaydı..." diye NOT basıyordu — **düşemezdi**. |
| 6 | `TRAP_NO_SINGLEFLIGHT` (04+) | Redis önbelleğinde **singleflight kodu yoktu**; yorum "aşağıda korunuyor" diyordu. | Tuzak okunmadığı için P03-05 her seviyede "çözülmüş" görünüyordu. |
| 7 | `TRAP_UNBOUNDED_QUEUE` (06+) | Kuyruk Kafka üreticisine taşınınca tuzak yalnızca **bastırılan** bir bayrağa dönüşmüş. | Deney açıyor, hiçbir şey değişmiyordu. |
| 8 | Read-your-writes işareti (09+) | İşaret **süreç içi**; oluşturma `api-svc`'de, okuma `redirect-svc`'de. | `db_sticky_reads_total` sabit 0'dı — hiç çalışmayan bir mekanizma, hiç gerekmeyen bir mekanizmaya benzer. |
| 9 | `ryw_violations_total` | `RecordRYWViolation` hiçbir yerden çağrılmıyordu. | P09-01'in kararı hep `0 > 0` idi. |
| 10 | Exemplar (11+) | Kod her histogram gözlemine trace_id iliştiriyor; `promhttp` `EnableOpenMetrics=false` (varsayılan) olduğu için **hepsi kapıda düşüyordu**. | P11-01 "exemplar bulunamadı" diyordu, köprünün iki ucu da yazılmışken. |
| 11 | pprof (11+) | Script `go tool pprof` komutunu öneriyordu; `net/http/pprof` **hiç kaydedilmemişti**. | Okuyucu tekniğin çalışmadığı sonucuna varırdı. |
| 12 | P11-08 ölçüsü | "Bu maliyet metriklerde görünmez" tezini, **metrik farkına** bakarak sınıyordu. | Tezin doğru olduğu durumda script NOT-REPRODUCED diyordu. |
| 13 | P09-04 ölçüsü | `hot_standby_feedback=on` bilerek açıkken "çakışma oldu mu?" diye soruyordu. | Cevabı kendi yapılandırmasıyla sabitlenmiş soru ölçüm değildir. |
| 14 | P08-05 / P04-03 sınıfı | Sıcak anahtarın arızası yavaşlama değil **tavan**; birkaç yüz rps'te tek Redis anahtarı zorlanmaz. | "Sorun yok" değil, "sorunun göründüğü yüke çıkmadın". |
| 15 | P11-03 ölçüsü | Sampling oranının kontrol ettiği şey span sayısı; script Alloy CPU'suna bakıyordu (Alloy aynı anda log da topluyor). | %100 koşusu %5'ten daha ucuz ölçülebiliyordu. |

| 16 | `setenv` / `setres` yardımcıları | 102 çağrı yerini değiştiren sed, yardımcının **kendi gövdesindeki** `kubectl set env` satırını da `setenv` yaptı → sonsuz özyineleme, `Segmentation fault: 11`. | Rollout hedefleyen çağrılar diğer daldan geçip çalışmaya devam etti, bu yüzden hata bir süre yalnızca Deployment hedefleyen deneylerde göründü. **Toplu değiştirme, değiştirdiği şeyin TANIMINI da kapsar.** |
| 17 | Canary analizi (12/13/14) | `AnalysisTemplate` var olmayan bir Prometheus servis adını sorguluyordu; her sorgu "network is unreachable" ile düşüyor, `consecutiveErrors` sınırı aşıyor ve canary **duruyordu**. | P12-01 bunu "kötü sürüm yakalandı" diye okuyordu. **Koşamayan bir analiz ile eşiği geçemeyen bir analiz aynı rollout durumunu üretir.** |
| 18 | P13-02 (RLS) | Sorgular `postgres` ile koşuyordu; süper kullanıcı RLS'i **tamamen atlar** (FORCE yalnızca tablo sahibini bağlar). | Politika çalışıyordu, biz göremiyorduk. "Veritabanından kontrol ettim" cümlesi, hangi ROLLE bakıldığını söylemiyorsa bilgi taşımaz. |
| 19 | P13-02 (psql) | `psql -tA` komut etiketlerini (`SET`) susturmaz; çok ifadeli sorguda çıktı `tenant=acme → SET` oluyordu. | Sayı sandığın şey bir komut adıydı. `-q` şart. |
| 20 | P13-03 (ağ testi) | Düz `kubectl run busybox`, seviyenin **kendi** Kyverno politikası tarafından reddediliyordu. | Güvenlik testini güvenlik politikası engelledi ve `set -e` scripti hiçbir şey ölçmeden öldürdü. Bir kapı koyduktan sonra her araç o kapının müşterisidir — onu test edenler dahil. |
| 21 | P06-06, P10-05, P10-06, P11-04, P14-01 | Kararlar `>=` / `<=` kullanıyordu: **iki taraf da 0 iken geçer**. | Başarısız bir ölçüm, geçen bir deneye dönüşüyordu — kanıt gibi görünen bir yanlış pozitif. |
| 22 | P12-03 | Drift'i geri almak için `make deploy` çağırıyordu; 12'nin Makefile'ı **kendi** namespace'ini hedefler. | 13'ün `verify-prev`i içinde koşunca kümeye üçüncü bir seviye kuruyordu. Bir önceki seviyenin scripti, bulunduğu namespace'ten başka yere dokunamaz. |
| 23 | `PLAN.md` | İki sorun vaat ediyordu (P09-07, P10-07) ve scriptleri yoktu; sekiz script de planda yoktu. | Plan ile depo arasındaki sessiz sapma. Artık birebir örtüşüyor. |

## Bulunan altyapı/kurulum hataları (13 ve 14 hiç ayağa kalkamıyordu)

| Ne | Ayrıntı |
|----|---------|
| Kyverno `require-probes` deseni | `readinessProbe: {"?*":"?*"}` değer joker'ini `httpGet`e (bir MAP) uyguluyordu → probe'u **olan** pod'ları reddetti. Mesaj sorunun tam tersini söylüyordu. |
| Kyverno operatör pod'ları | CNPG'nin `pg-1-initdb` Job'ı ve pooler'ları reddedildi: seviyenin güvenlik politikası **kendi veritabanını** engelledi. |
| NetworkPolicy | `topics` Job'ı izin listesinde yoktu (topic'ler hiç yaratılmadı); Prometheus kazıması hiçbir yerde açık değildi (kör seviye, sağlıklı görünür); pooler'lara uygulama erişimi eksikti. |
| API anahtarı | 13'ten itibaren `POST /api/links` Bearer istiyor; smoke, k6 ve `repro.sh` bunu bilmiyordu → "link oluşturulamadı". |
| `007_breaking_rename.sql` | P12-02 deneyi için yazılmıştı ama migration **sırasında** duruyordu; 13/14 yolda uygulayıp `links.url` sütununu yeniden adlandırıyordu. |
| RLS | Politika `app.tenant_id` bekliyor, uygulama hiç ayarlamıyor, public yönlendirme yolunun kiracısı yok → her yazma 42501. |
| `make wait` sırası | Uygulamanın readiness'i DB ping'ine bağlıyken `deploy/api`, CNPG'den **önce** bekleniyordu. |
| Job silme yarışı | `delete job --wait=false` + hemen `apply` → yeni Job sessizce kayboluyor, şema hiç uygulanmıyor. |
| `make wait` Job kapsamı | Namespace'teki HER Job bekleniyordu; CNPG kendi bootstrap Job'ını başarıyla bitince **siler** → "tamamlanmadı". Bir kaynağı beklemek, yaşam döngüsünün sahibini bilmeyi gerektirir. |

---

## Kalıcı korumalar

- `tools/lint-skeleton.sh` **9. kural**: config'de `env` ile okunan her `TRAP_*`, kodda
  (config.go dışında, `"TRAP_"` dizgesi içermeyen bir satırda) kullanılmalı. Yalnızca
  main'in tuzak durumu haritasında **bastırılmak** kullanım sayılmaz.
- `platform/lib/repro.sh` → `setenv` / `setres`: iş yükü türünü (Deployment/Rollout) kümeye sorar.
- `platform/lib/apikey.sh`: anahtar **kümeden** okunur, koda gömülmez.
- `promq` POST kullanır ve Prometheus'un gerçek hata mesajını basar.
- `k6run`, `scenarios:` tanımlı dosyalarda CLI bayraklarını env'e çevirir.
