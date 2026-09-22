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
| 24 | P06-01 | Ölçüm penceresi `increase(...[10m])` idi; hemen öncesinde `verify-prev` 05'in scriptlerini **aynı namespace'e** koşmuştu. | Pencerede deneyle ilgisiz ~50 bin kayıt vardı: `ok=50460` sağlıklı bir tüketici gibi görünürken tüketici bizim birikimimizden **sıfır** kayıt işlemişti. Deneyden geniş bir pencere, deneyi değil komşularını ölçer. |
| 25 | P06-01 | Tüketici hiç kayıt işlemediğinde script yine de `NOT-REPRODUCED` basıyordu. | "Sistem sağlam" diye okunuyordu; gerçek ise "deneyi hiç koşmadık". 2 sn'lik broker gecikmesi tam olarak böyle saklandı: tüketiciyi durdurdu, script buna temiz koşu dedi. Eksik ölçüm artık `HATA`. |
| 26 | P06-06 | Karar `def >= trap` idi; `def == trap`, yani **iki mod arasında fark yokken** geçiyordu. | Hüküm "commit noktası teslimat garantisini belirliyor" diyor ama eşitlikte gösterilen bir fark yok. Farkı iddia ediyorsan farkı ölç. |
| 27 | P10-05, P11-04, P14-01 | Kararlar `b >= a` / `b <= a` idi: **eşitlikte**, yani hiç fark yokken de geçiyordu. | Hükümler "goroutine'leri büyüttü", "daha gürültülü", "p50'yi indirdi" diyor. Farkı iddia eden hüküm farkı ölçmeli. P14-01'de ek olarak p50 histogram **kovalarından** gelir; aynı kovaya düşen iki ölçüm eşit çıkar — hüküm artık mekanizmaya bağlı: L1 isabeti > 0 **ve** Redis komut hızının düşmesi. |
| 28 | `promq` (190 çağrı yeri) | Boş pencerede `histogram_quantile` **"NaN"**, açık üst kovalı histogram **"+Inf"** döndürür; sonuç doğrudan `awk`'a gidiyordu. | Bunlar sayı değil: BSD awk 0 okur (her karşılaştırma sessizce yanlış olur), gawk METİN tutar ve `"NaN" > "0"` sözlük sırasına göre **doğrudur** — aynı script macOS'ta ve Linux'ta ZIT hükme varır. Tek yerde, kaynağında normalleştirildi. |
| 29 | P07-03 | Karar `p > w` idi ve `w` (ısınmış p99) bir Prometheus sorgusundan geliyordu; sorgu patlayınca `promq` **0** döndürüyordu. | Sıfır bir taban, HER tepeyi "artış" gibi gösterir: bozuk ölçüm `REPRODUCED` basıp soğuk-başlangıç kanıtı gibi göründü. Hüküm artık `w > 0` istiyor. |
| 30 | P07-04 | Dar kota denemesi `--requests=cpu=100m --limits=cpu=50m` uyguluyordu. | API `must be less than or equal to cpu limit` ile reddediyor, script hiçbir şey ölçmeden ölüyordu. Ayrıca temizlik requests ve limits'i AYRI çağrılarda geri alıyordu; ara durum da geçersiz olduğu için temizlik yarım kalıp seviyeyi dar kotada asılı bırakabilirdi. |
| 31 | P07-02 | Yük `stairs` idi: 200 tohumlanmış kod + 04'ten beri PAYLAŞIMLI önbellek → isabet ~%100. | "Darboğaz DB'ye taşındı" iddiası ölçülüyordu ama yük DB'ye hiç ulaşmıyordu (0 ms havuz beklemesi, 0 hata, 38/100 bağlantı). Deney, ölçmek istediği durumu kendisi yaratmalı: eşzamanlı `scan` yükü her istekte bir DB okuması üretiyor. |
| 32 | `promq` hata mesajı | Başarısız sorguyu `%.70s` ile basıyordu. | İki FARKLI bozuk sorgu ekranda birebir aynı görünüyordu; Prometheus sütun numarasını verdiği hâlde hatanın yeri okunamıyordu. |
| 33 | P07-06 | Sayaç deltası kazıma aralığından (15 sn) HIZLI okunuyordu: `q0` oluşturma isteklerinden ÖNCEKİ kazımaydı, tuzak fazında ise ölen pod'un serisi toplamdan düşüp fark negatife inince 0'a kırpılıyordu. | Tek bir list isteği "≈ 61 sorgu", N+1 açık hâli "≈ 0 sorgu" yazdı — yani çıktı kendi iddiasını çürütürken hüküm (yalnızca süreye baktığı için) yine `REPRODUCED` dedi. Artık iki uçta da en az iki kazıma aralığı bekleniyor ve karar sorgu sayısına bakıyor. |
| 34 | P03-04, P03-05 | Aynı kazıma-gecikmesi hatası: sayacın ilk ucu bir `rollout restart`ın hemen ardından okunuyordu. | Ölen pod'un serisi `sum()`dan düşene kadar ilk okuma ŞİŞKİN, delta olduğundan KÜÇÜK çıkar; şişkinlik kaç pod'un öldüğüne bağlı olduğu için 1-pod ve çok-pod fazlarını farklı oranda bozar — yani karşılaştırmanın anlamını yok eden yerden. Kural `settle_scrape` olarak paylaşılan kütüphaneye çıkarıldı. |
| 35 | P07-04 | Baştaki kontrol metrik **adının** Prometheus'ta olup olmadığına bakıyordu; kubelet onu başka namespace'ler için yayınlayınca "evet" diyordu, oysa bizim pod'larımız için seri yoktu. | `promq` 0 döndü, karar `NOT-REPRODUCED` bastı ve bu dersin TAM TERSİ olarak okunuyordu: "CPU limiti zararsızmış". Bir metriğin VARLIĞI ile o metriğin SENİN nesnen için var olması aynı şey değil. Artık eksik ölçüm `SKIPPED`. |
| 36 | P08-04 | Tek sayı raporluyordu: "tepe 216 < limit 300". | Bu cümle iki ZIT şeyi anlatabilir — limiter gerçekten o kadarına izin verdi, ya da yük sınıra hiç gelmedi. Ayırt edemeyen bir karar hüküm veremez; artık reddedilen istek sayısı da ölçülüyor ve deny ≈ 0 iken script `NOT-REPRODUCED` yerine eksik ölçüm diyor. |
| 37 | `chaos_apply` temizliği (tüm seviyeler) | Arıza nesnesi siliniyordu, ama durumlu bileşenin TOPARLANMASI beklenmiyordu. | 09'da replikaya gecikme enjekte edildi, chaos temizlendi, CNPG `pg-2`'yi yeniden başlattı ve **bir sonraki script** "ortam bozuk" deyip çıktı — ortamı değil ÖNCEKİ DENEYİ tarif eden bir hata. Bekleyecek yer, bozan scriptin kendisidir. |
| 38 | `ensure_deps_ready` | Bekleme bütçesi sabit 2 dakikaydı. | Stateless bir rollout için bol, bir CNPG replikası için az. Bütçe, beklediğin şeyin doğal toparlanma süresinden kısa olmamalı; yoksa komşu scriptleri zincirleme düşürürsün. |
| 39 | `run_cleanup` | Her temizlik kancasını `>/dev/null 2>&1` ile koşuyordu. | Gürültüyü bastırırken temizlik sırasında ORTAYA ÇIKAN gerçek sorunu da yutuyordu; bedelini sonraki script ödüyordu. `warn_hard` gerçek stderr'e (fd 9) yazıyor. |
| 40 | P12-06 | Hüküm `[[ -n "$dbver" ]] && [[ -n "$appimg" ]]` idi: iki metin okunabildiğinde geçiyordu, yani sağlıklı her kümede. | Düşemeyen bir deney, deney değildir — hüküm kılığına girmiş bir totoloji. Falsifiye edilebilir ölçü: Down bloğu **ne yapıyor**? `DROP TABLE`/`DROP COLUMN` içeren bir geri alma, Up'tan bu yana yazılan her şeyi siler (6 migration'ın 5'i). Hepsi zararsız olsaydı script haklı olarak NOT-REPRODUCED derdi. |
| 41 | P04-07 | Hüküm `maxp99 > 0` idi: tamamlanan herhangi bir istek için doğru. | "KEYS * gecikmeyi tepe yaptırdı" diyordu ama gecikmenin KEYS çağrısı OLMADAN ne olduğunu hiç ölçmüyordu — tabansız bir tepe, tepe değildir. Artık aynı yük iki kez koşuyor (temiz / KEYS'li) ve her faz kendi penceresini okuyor. |
| 42 | `wait_endpoints`, P07-08, P06-04 | `grep -c … \|\| echo 0` deyimi: `grep -c` eşleşme bulamayınca **"0" basar ve yine de 1 ile çıkar**, yani `\|\| echo 0` de çalışır ve değişken `0\\n0` olur. | Sonraki `(( got >= want ))` aritmetik SÖZDİZİM HATASI verir, koşul sessizce yanlış sayılır ve bekleme döngüsü asla sağlanmayacak bir koşulu bekler — tam da "0 endpoint" durumunda, beklemenin en gerekli olduğu anda. stderr bastırıldığı için ekranda da görünmez. `count_lines` tek yerde çözüyor. |
| 43 | P14-02 | `(( on_ok >= 0 ))` bir koruma değildi: sayaç zaten negatif olamaz, koşul her zaman doğruydu. | Geriye tek gerçek koşul `off_bad >= on_ok` kalıyordu ve o da eşitlikte — ikisi de 0 iken, hiçbir şey ölçülmemişken — geçiyordu. L1 kapalıyken script "borç ödendi" diyebilirdi. |
| 44 | P14-04 | Hüküm `peak_rps > 0` idi: tek bir tamamlanmış istekte bile doğru. | İddia "tek pod kapasitesi ÖLÇÜLDÜ". Bir kapasite sayısı ancak yük gerçekten koştuysa, pod gerçekten CPU harcadıysa ve gecikme okunabildiyse anlamlıdır; üçü yoksa bu bir ölçüm değil temennidir. |
| 45 | `k6run` / `_k6q` (tüm seviyeler) | `$K6_SUMMARY` problem başına **sabit** bir dosya ve koşular arasında diskte kalıyordu; `_k6q` yalnızca "dosya var mı?" diye bakıyordu. | k6 bu kez hiç başlamadıysa ya da özet yazmadan düştüyse, ÖNCEKİ TURDAN kalma sayılar bu turun sonucu sanılıyordu: P10-02 bir fazda **897 istekte 73710 adet 5xx** raporladı — fiziksel olarak imkânsız. Artık koşudan önce siliniyor (yokluk = "ölçemedik") ve her fazın özeti ayrı bir dosyaya kopyalanıyor. |
| 46 | P10-04 | Üç hata birden: (a) `dependency_requests_total` devre açıkken **hızlıca reddedilen** çağrıları da sayıyordu, (b) iki faz da `[3m]` penceresi okuyordu ama ~1 dk arayla koşuyordu, (c) mutlak sayılar karşılaştırılıyordu. | "Bağımlılığa giden çağrı" diye raporlanan 1663 sayısının 1498'i bağımlılığa GİTMEMİŞTİ (gerçekte 165). Breaker açıkken istekler hızlı reddedildiği için k6 çok daha fazla istek basıyor; mutlak sayı değil **oran** karşılaştırılmalı: her 100 istekten kaçı bozuk bağımlılığa ulaştı? |
| 47 | 07-14 · `cmd/*/main.go` (16 dosya) | Redis istemcisi kuruluyor ama `api.SetRedis(rdb)` hiç çağrılmıyordu (04-06 çağırıyordu). | `a.rdb` nil kaldığı için `TRAP_READY_CHECKS_REDIS` bayrağını OKUYUP hiçbir şey yapmıyordu: P10-02 koşuyor, fark bulamıyor ve "readiness sorunsuz" diyordu — dersin tam tersi. 9. kural yakalayamazdı çünkü bayrak okunuyordu. **Nil bir bağımlılığın arkasındaki bayrak kapalı değil GÖRÜNMEZdir**: hiçbir şey patlamaz, hiçbir şey loglanmaz. 12. lint kuralı eklendi. |
| 48 | **26 dosyada 45 çağrı** | `num "$(promq "…{namespace=\\"$NS\\",code!=\\"503\\"}…")"` göründüğü şeyi geçirmiyordu: `"$( … )"` içinde iç `\\"` kaçışları iç tırnaklamayı bitiriyor, `{a,b}` tırnaksız kalıyor ve bash onu **süslü parantez genişletmesine** sokuyor — parantezler kayboluyor, seçici ikiye bölünüyor. | Prometheus `parse error: unexpected "=" in aggregation` diyor, `promq` 0 döndürüyor ve deney SIFIRLARI karşılaştırıyor: P10-06 iki fazda da "p99=0 ms" bastı, P07-03 hükmünü sıfır bir tabanın üstüne kurdu. Hata ancak `promq` sorguyu kırpmadan basmaya başlayınca (32. bulgu) görünür oldu. 13. lint kuralı eklendi. |
| 49 | `chaos_cleanup` | Chaos Mesh nesnelerinde **finalizer** var: `kubectl delete` dönse bile nesne — ve enjekte edilen arıza — ayakta kalabiliyor. | P10-01'in temizliği koştu, `pg-loss-30` kümede kaldı ve ardından gelen ÜÇ script sırayla hata verdi; hiçbiri kendi ölçümüyle ilgili olmayan bir sebepten (CNPG failover'a girdi). Temizlik artık silmeyi DOĞRULUYOR ve olmazsa yüksek sesle söylüyor; toparlanma beklemesi de ölçüm bütçesini yemesin diye 120 sn'ye indirildi. |
| 50 | P00-04 | `${probes:-YOK — … Endpoint'e ekleniyor}` — bash, `${var:-kelime}` içindeki kelimede tırnakları **çift tırnak içinde bile** işler; kesme işareti tek tırnak açıp kapanış `}`ını yutuyordu. | `bad substitution: no closing '}'` ile ölüyordu — ama YALNIZCA değişken boşken, yani tam olarak 00'ın readinessProbe'u olmadığı durumda: notun var olma sebebi olan durumda. Yalnızca hata yolunda çalışan bir varsayılan, kimsenin denemediği bir varsayılandır. 14. lint kuralı eklendi. |
| 51 | `last_reason` (P00-01, P00-08, P01-04) | Hiçbir pod sonlanmadığında `grep -v '^$'` hiçbir şey bulmuyor → 1 dönüyor → `pipefail` boru hattını düşürüyor → `reason=$(last_reason)` başarısız bir atama oluyor → `set -e` scripti **hüküm basmadan** öldürüyordu. | Yalnızca hiçbir şey çökmediğinde, yani tam olarak SAĞLIKLI yolda ısırıyordu: P00-01 seviye 00'da (süreç gerçekten çöküyor) geçti, 01'de (map korunuyor) sessizce öldü — oysa oradaki `NOT-REPRODUCED` işin ta kendisiydi. **Bulacak bir şey olmaması hata değildir.** |
| 52 | P01-03 | İkinci koşul `(( e5 > 0 ))` idi: `kubectl drain` node'daki HER pod'u tahliye eder — 02'deki **tek Postgres** dahil. | Uygulama veritabanı gittiği için 5xx dönüyor; bu P02-03'ün sorunu, bunun değil. Hüküm o 5xx'leri "uygulama için güvenli bakım yok" diye okuyup, uygulama yedekliliğini zaten çözmüş bir seviyede REPRODUCED dedi. Ölçü artık iddianın kapsamında: bakım penceresinde hazır **uygulama endpoint'i** hiç sıfıra indi mi? |
| 53 | P02-05, P04-06, P13-04 | Aynı sınıf: korumasız `x=$(… \| grep …)`. `grep` bulamazsa 1 döner, `pipefail` boru hattını düşürür, ATAMADA başarısız komut ikamesi `set -e`'yi tetikler ve script **hüküm basmadan** ölür. | Yalnızca bulunacak bir şey yokken ısırır, ki bu genelde SAĞLIKLI yoldur: P02-05 indeks yerindeyken ("Seq Scan" yok), P13-04 düz metin sır bulunamayınca. **İyi haber scripti öldürüyordu.** 15. lint kuralı eklendi. |
| 54 | Platform · Prometheus | Kind control-plane sert yeniden başlayınca Prometheus 73 segmentlik WAL'i oynatmak zorunda kaldı ve 1536Mi limitinde **OOMKilled** oldu → yeniden başla → replay baştan → sonsuz döngü. | O sırada koşan tur Prometheus'a ulaşamadığı için her `promq` **0** döndürdü: ölçüm yapılmadan hüküm üretiliyordu. Bir bileşenin limiti kararlı durumuna göre değil EN KÖTÜ ANINA (kurtarma) göre seçilmeli — limit 3Gi. Ayrıca tur ön kontrolü artık pod'un "Running" olmasına değil, **sorgu ucunun cevap vermesine** bakıyor. |

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

---

## Tur sonuçları (22 Eylül 2026 gecesi)

**Seviye 13 — ilk kez uçtan uca çalıştı.** Beş ayrı engel vardı (Kyverno desen hatası, operatör
pod'larının reddi, üç ayrı NetworkPolicy boşluğu, API anahtarı, migration sırasındaki kırıcı
rename); hepsi düzeltildi.

| Aşama | Sonuç |
|---|---|
| `make up` | ✔ (migrate + topics + CNPG 2/2 + rollout 3/3 + smoke) |
| `verify-prev` (12'nin 6 scripti) | ✔ hepsi hatasız koştu, ✘ yok |
| Kendi sorunları | P13-04 ✔ · P13-05 ✔ · P13-06 ✔ · P13-02 NOT-REPRODUCED · P13-01/03/07 HATA |

HATA veren üçü ve P13-02, **script hatasıydı ve düzeltildi**:

- **P13-01** — `setenv` özyinelemesi (segfault). Bu, Deployment hedefleyen HER deneyi etkiliyordu.
- **P13-02** — sorgular `postgres` süper kullanıcısıyla koşuyordu; RLS onu bağlamaz.
- **P13-03** — test pod'unu seviyenin kendi Kyverno politikası reddediyordu.
- **P13-07** — reddedilme beklenen sonuç ama `kubectl` bunu sıfırdan farklı çıkış koduyla söylüyor
  ve `set -e` scripti ilk başarıda öldürüyordu.
- **P13-08** NOT-REPRODUCED **haklıydı**: seviye "konteyner sertleştirme" diyordu ve hiç
  `securityContext` göndermiyordu. Eklendi (runAsNonRoot, readOnlyRootFilesystem, drop ALL,
  seccomp RuntimeDefault).

**Seviye 14 — hiç çalışmamış olduğu ortaya çıktı.** L1 ve L2 önbellek metrikleri aynı adları
`MustRegister` ile iki kez kaydediyor ve `api-svc` açılışta panikliyordu
(`duplicate metrics collector registration attempted`). 12 seviyede birden düzeltildi.
Düzeltmeden sonra 14 ilk kez ayağa kalktı: CNPG 2/2, rollout 3/3, smoke ✔, L1+L2 pub/sub açık,
3 partition, KEDA `Ready=True`.

| 14'ün `verify-prev`i (13'ün 8 scripti) | Sonuç |
|---|---|
| P13-01 kiracı taklidi | REPRODUCED — `setenv` özyineleme düzeltmesi burada doğrulandı |
| P13-02 RLS | REPRODUCED — süper kullanıcı/`psql -q` düzeltmeleri doğrulandı |
| P13-03 varsayılan-reddet ağ | NOT-REPRODUCED → **script hatasıydı**: sabit 12 sn bekleyip boş log okuyordu. NetworkPolicy elle doğrulandı, Postgres'i de Redis'i de gerçekten engelliyor. Düzeltildi. |
| P13-04 sırlar | REPRODUCED |
| P13-05 SSRF/DNS | REPRODUCED |
| P13-06 enumeration | REPRODUCED — 14'ün SOLVES'ından çıkarılması doğruydu |
| P13-07 Kyverno | NOT-REPRODUCED → **script hatasıydı**: `tail -2` tam da kararın aradığı "denied" satırını kesiyordu. Düzeltildi. |
| P13-08 sertleştirme | REPRODUCED — `securityContext` eklendikten sonra |

✘ yok: sekiz scriptin sekizi de hatasız koştu.

### Kümesiz doğrulama durumu

`make verify` → gofmt temiz · `go vet` temiz · 15/15 iskelet lint temiz · `go test -race` tüm
seviyelerde geçiyor.


---

## 14'ün kendi sonuçları ve ortaya çıkardığı iki şey

| ID | Sonuç | Not |
|---|---|---|
| P14-01 | HATA → düzeltildi | Yerel `setenv()` sarmalayıcısı **kendi adını** çağırıyordu → sonsuz özyineleme, script altı dakika "koşuyor" göründü |
| P14-02 | HATA → düzeltildi | 1. faz ölçümünü YAPTI (yayın açık: 40 okumadan 0'ı bayat, 4 gönderildi / 16 alındı); 2. fazda `pipefail` altında geçici bir curl hatası atamayı düşürüp scripti öldürdü |
| P14-03 | REPRODUCED → **ölçüsü düzeltildi** | Geçti ama iddiasını kanıtlamadı: KEDA hiç ölçeklenmedi (lag 14 < eşik 500), tüketici tek pod'da kaldı ve karar yalnızca *partition sayısına* bakıyordu. Artık replika sabitlenip **kaç pod'un gerçekten kayıt işlediği** sayılıyor |
| P14-04 | HATA | Tek pod kapasite ölçümü; tam çıktıyla yeniden koşulacak |
| P14-05 | NOT-REPRODUCED → **iki gerçek bulgu** | (1) `promq`'nun yeni hata raporlaması bozuk bir PromQL'i görünür kıldı; (2) **chaos hiç enjekte edilmiyordu** |

### chaos-daemon saatlerdir ölüydü ve chaos-mesh "sağlıklı" görünüyordu

`chaos-daemon` bir **DaemonSet**'tir; replika sayısı yoktur, park etmenin tek yolu imkânsız bir
`nodeSelector`'dır. `platform/lib/profile.sh`'ın `on()`/`off()` fonksiyonları yalnızca Deployment
ve StatefulSet'leri yönetiyordu — yani bir noktada `kapali=true` ile park edilen chaos-daemon'ı
**geri getirecek hiçbir şey yoktu**. `kubectl -n chaos-mesh get pods` controller-manager ve
dns-server'ı Running gösteriyordu; her şey yolunda görünüyordu.

O pencerede koşan **her chaos deneyi, kimsenin bozmadığı bir sistemi ölçtü.** Tek koruma
`chaos_apply`'ın `AllInjected` kontrolüydü: scriptler sahte yeşil yerine SKIPPED bastı. Ama delik
deneylerde değil, profil scriptindeydi.

> **Bir bileşeni kapatabiliyorsan, AYNI ARAÇLA geri açabilmek zorundasın.**
> `off()` bir şeyi park ediyorsa, `on()` onu tam olarak geri almalı — yoksa "kapalı" sessizce
> "kalıcı olarak bozuk"a dönüşür.
