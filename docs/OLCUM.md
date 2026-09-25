# Ölçüm ve ortam kuralları

Bir deneyin sonucu hem ölçümün kendisine hem de altındaki kümeye bağlıdır. Bu sayfa iki listeyi tutar:
platformun hangi kurallarla kurulduğu (bir sonuç "açıklanamaz" göründüğünde ilk bakılacak yer) ve her
reproduce scriptinin uyduğu ölçüm kuralları (yeni bir deney yazarken: [PROBLEM-TEMPLATE.md](PROBLEM-TEMPLATE.md)).

## Ortamın kendisi de ölçülür

Bir deneyin sonucu, altındaki kümenin durumundan bağımsız değildir: doygun bir VM'de ölçülen gecikme
uygulamanın değil kümenin gecikmesidir. Platform bu yüzden aşağıdaki kurallarla kurulur; bir sonuç
"açıklanamaz" göründüğünde ilk bakılacak yer burası.

| Kural | Neden | Nerede |
|---|---|---|
| Seviye yalnızca kendi bileşenlerini açık tutar | Bütün operatörler ve tam gözlem yığını boşta 6 çekirdeğin ~5.6'sını yer; VM swap'e girer, kubelet NotReady olur ve ölçüm uygulamayı değil ölmekte olan kümeyi ölçer | `platform/lib/profile.sh` (`make up`'ın ilk adımı) |
| Prometheus ölçülü kazır, sınırlı saklar (uygulama 10 sn · küme 30 sn · 48 saat, en çok 6 GB) | Sık kazıma gözlenen sistemle aynı CPU bütçesinden yer; bellek aktif seri sayısına bağlıdır, saklama süresi diske yansır. 48 saat, 8-12 saatlik tam turun (`tools/full-run.sh`) sonradan incelenebilmesi için | `platform/helm/kube-prometheus-stack.values.yaml` |
| Bellek limiti kararlı duruma değil kurtarma yoluna göre seçilir | Sert bir yeniden başlamadan sonra Prometheus WAL'ı oynatır ve kararlı durumdan çok daha fazla bellek ister; limit dar olursa oynatma ortasında OOM olur ve döngüye girer | aynı dosya (`limits.memory: 3Gi`) |
| Grafana'nın bellek limiti çalışma kümesinin rahat üstünde | Chart, Go çöp toplayıcısının hedefini (GOMEMLIMIT) limitin %90'ına koyar; hedef çalışma kümesine yakınsa GC durmadan çalışır, paneller saniyelerce bekler ve probe'lar düşer | aynı dosya (`grafana.resources`) |
| Lider kiraları uzun (60 / 45 / 5 sn) | Doygun bir VM'de kira yazması onlarca saniye sürebilir; kısa kira controller'ları durmadan yeniden başlatır | `platform/kind/cluster.yaml`, `platform/Makefile` |
| Kyverno'nun kaynak webhook'ları hata durumunda geçirir (fail-open) | Kyverno yeniden başlarken kümedeki her `kubectl apply` durmasın; politika kuralları yine zorunlu | `platform/Makefile` (`security`) |
| KEDA her seviyede açık | Kapalı bir KEDA `external.metrics.k8s.io` APIService'ini endpoint'siz bırakır; API keşfi bozulur ve namespace denetleyicisi hiçbir namespace'i silemez | `platform/lib/profile.sh` |
| Redpanda topic'leri görünür bir Job ile oluşur | Broker ayarları `--set redpanda.*` bayraklarıyla verilemez (v24.2.7 bunları reddeder); Job'ın sonucu `kubectl get jobs`'ta okunur | seviyelerin `deploy/redpanda.yaml`'ı |
| Yük testleri hız sınırından muaf ayrı bir girişten gider | Uygulama ve ingress hız sınırları, kapasite ölçen bir yükü de reddeder; muafiyet başlık + Secret ile, limiter'ı sınayan deneyler ise genel girişi kullanır | `lvlNN-load.localtest.me`, `platform/lib/loadtest.sh` |
| Düğüm dondurma deneyi düğümün Ready'ye döndüğünü doğrulayarak biter | `docker pause`/`unpause` sonrası containerd'nin PLEG'i ölü kalabilir; düğüm fark edilmeden NotReady kalır | P07-07 |
| Her altyapı bileşeninin ServiceMonitor'ü var; scriptler metriğin varlığını önce sorar | Var olmayan bir metrik 0 gibi okunur; "0" ile "ölçülmedi" ayrılmazsa script "sorun yok" der | seviyelerin `servicemonitor.yaml`'ı, `need_metric` |
| `make deploy`, önceki namespace'in silinmesini bekler | `make down` silmeyi arka planda bırakır; hemen ardından gelen kurulum "namespace is being terminated" ile düşer | `ladder.mk` |
| `make stop`, `docker stop`'tan önce düğümün içinde kubelet ve containerd'yi durdurur | `docker stop` bir systemd konteynerine SIGKILL gönderirse containerd'nin meta veri deposu yazma ortasında kalabilir | `platform/Makefile` (`stop`) |

## Ölçüm kuralları

Bu merdivenin ikinci öğretisi sistemler hakkında değil, **ölçüm** hakkında. Her kural, uyulmadığında
scriptin "sorun yok" deyip sorunun yine de orada olduğu bir durumu önler. Yeni bir reproduce yazarken
listeye bak ([PROBLEM-TEMPLATE.md](PROBLEM-TEMPLATE.md)).

| Kural | Uyulmazsa |
|---|---|
| Ölçüm **penceresi**, ölçtüğün olaydan kısa olmamalı | `rate(...[1m])` 45 sn'lik bir yükün yarısını kaçırır, oranı boşta geçen zamanla seyreltir |
| Ölçüm **çözünürlüğü**, olaydan ince olmalı | 1-2 sn'lik bir TTL darbesi 10-30 sn'lik kazımada düzleşir → P03-07 pod'un `/metrics` ucunu saniyede bir örnekler |
| İki fazı **ayrı** ölç | `increase(...[3m])` iki fazı karıştırır; doğrusu yük öncesi/sonrası sayaç farkı (P03-04) |
| Deneyin **hazırlığı** da arızaya tabidir | Chaos yükten önce uygulanırsa k6'nın hazırlık adımı zaman aşımına uğrar ve yük hiç koşmaz → `seedLinks` zaman bütçelidir (P05-02) |
| **Hangi** iki olayın yarıştığını yaz | Yanlış pencereyi büyütmek yarışı üretmez; `defer` ile büyütülen pencere hiç büyümez (P04-05) |
| Sorunlar birbirini **maskeler** | Eşzamanlılık çökmesi çakışma ve OOM kanıtını saklar → izole ederken 1 VU |
| Anlık metrik, **ölüp dirilen** süreci kaçırır | Tepe bellek + `OOMKilled`/exit 137 kanıtı şart |
| Korumayı **kim** veriyor? | 413'ü uygulama değil ingress verebilir → pod'a port-forward ile doğrudan test et |
| Yük, probe'un **failureThreshold**'undan uzun sürmeli | Aksi hâlde probe hiç düşmez ve "probe iyi" sonucu çıkar |
| Bağımlılığın hazır olması **önkoşuldur**, ölçüm değil | Önceki deneyin öldürdüğü Redis, sonraki deneyi ilgisiz bir hatayla düşürür → `dep_pod` |
| Deney kümeyi **temiz** bırakır | Takılı kalan bir cordon, ilgisiz bir seviyeyi "rollout timeout" ile düşürür → `on_cleanup` + `trap` |
| Kanıtı okunabilirlik uğruna **kırpma** | `EXPLAIN` çıktısını `head -3` ile kırpmak, aranan "Parallel Seq Scan" satırını keser |
| Çıkış koduna değil, **çıktı işaretine** bak | Çöken bir script (exit 1), `verify-prev`'de NOT-REPRODUCED sayılırsa yeşil yanar |
| **Var olmayan metrik** sıfırla aynı görünür | ServiceMonitor'ü olmayan bir bileşende `promq` 0 döner ve script "sorun yok" der → `need_metric` |
| Eşik, iddian olmadan **oluşmayacak** bir şeyi ölçmeli | `busy_p99 >= base_p99` gürültüyle geçilir; ayırt edici işaret paylaşılan havuzda bekleme |
| Deney **kendisi müdahale ederse** iki seviye aynı çıkar | Tüketiciyi kendisi açan bir P06-02, "07 bunu çözdü" iddiasını sınayamaz |
| Arızanın işareti her zaman **hata kodu değildir** | Donmuş bir düğümde 5xx yoktur, yalnızca iş bitmez (120 sn'de 13 istek) |
| Bir korumanın değerini ölçerken **diğer korumayı kaldır** | 5 sn'lik preStop, readiness'ın "HAYIR" demesinin etkisini gizler |
| **Düşemeyen** bir deney, deney değildir | Tuzağı hiç açmayan bir script her koşulda aynı hükmü verir. Karar yazınca sor: *iddiam yanlış olsaydı bu ölçü ne gösterirdi?* |
| Tuzağın **koda bağlı** olduğunu doğrula | Config'de tanımlı ama kodda okunmayan bir `TRAP_*` açılır, sistem değişmez, script yine karar basar → lint kuralı 9 |
| `>=` / `<=` kararları **0 vs 0'da geçer** | Başarısız bir ölçüm, geçen bir deneye dönüşür |
| **Boş** ölçüm, olumsuz ölçüm değildir | Pod çıktı üretmeden okunan log "yetkisiz pod DB'ye ulaştı" gibi görünür; oysa engellenmiştir (P13-03) |
| Koruma devreye girdiğinde **neyi değerlendirdiğini** sor | Analiz Prometheus'a ulaşamadığı için duran bir canary, "kötü sürüm yakalandı" diye okunabilir (P12-01) |
| Cevabı **kendi yapılandırmanla sabitlenmiş** soruyu sorma | `hot_standby_feedback=on` iken "çakışma oldu mu?" sorusunun cevabı zaten hayırdır (P09-04) |
| **Hangi rolle** baktığını söyle | RLS açıkken `postgres` süper kullanıcısı tüm satırları görür: politika çalışır, sen göremezsin (P13-02) |
| Yavaşlatacağın **süreci doğru seç** | Yarışın penceresi offset commit'indeyse veritabanını geciktirmek yarışı üretmez (P06-01) |
| Aracın **kendi hatasını susturma** | `curl -f` gövdeyi atar; geriye "curl 22" kalır ve Prometheus'un gerçek hata mesajı kaybolur |
| Yük üretecinin **gerçekten koştuğunu** doğrula | Senaryo tanımlı k6 dosyalarında `--duration` koşuyu hiç başlatmaz; `\|\| true` bunu yutarsa 0 istek "fark yok" diye okunur → `k6run.sh` bayrakları çevirir |
| **Belgelediğin aracı bağla** | README'nin önerdiği pprof komutu, `net/http/pprof` kayıtlı değilse okuyucuya "teknik çalışmıyor" dedirtir |
| Hata mesajı **neyin** başarısız olduğunu göstermeli | Kırpılmış bir sorgu metni iki farklı bozuk sorguyu aynı gösterir; Prometheus'un verdiği sütun numarası işe yaramaz → `promq` sorgunun tamamını basar |
| İç içe tırnaklı **komut ikamesi** argümanı bozar | `num "$(promq "…{a=\\"x\\",b=\\"y\\"}…")"` içinde iç tırnak erken biter, `{a,b}` bash'in süslü parantez genişletmesine girer ve sorgu `parse error` alıp 0 döner |
| **Nil bir bağımlılığın** arkasındaki bayrak kapalı değil, görünmezdir | Bağımlılığı hiç verilmemiş bir kod yolu bayrağı okur, nil görür ve hiçbir şey yapmaz; hiçbir şey patlamaz, yalnızca deney anlamsızlaşır |
| **Bayat** bir çıktı dosyası, bu koşunun çıktısı sanılır | Diskte kalan bir `$K6_SUMMARY`, k6 hiç başlamadığında önceki koşunun sayılarını verir → her koşu dosyayı önce siler |
| Sayaç deltası **kazıma aralığından hızlı** okunamaz | Kazıma aralığı dolmadan okunan fark, önceki trafiğin artığını ölçer → `settle_scrape` |
| **Tabansız** bir tepe, tepe değildir | "KEYS * gecikmeyi fırlattı" demek için KEYS olmadan gecikmenin ne olduğu da ölçülmelidir (P04-07) |
| **Reddedilen** çağrı, bağımlılığa giden çağrı değildir | Devre kesici açıkken "bağımlılık çağrısı"nın çoğu hiç gitmez; iki fazın istek sayısı farklıysa mutlak sayı değil **oran** karşılaştırılır (P10-04) |
| Bekleme bütçesi, beklediğin şeyin **toparlanma süresinden** kısa olmamalı | CNPG replikası dönmeden biten bir bekleme, sonraki scripte "ortam bozuk" dedirtir — ortamı değil önceki deneyi tarif eden bir hata |
| Arızayı **kaldırmak**, etkisinin geçmesi demek değil | Chaos nesnesi silindiğinde CNPG replikayı hâlâ yeniden başlatıyor olabilir; bekleyecek yer, bozan scriptin kendisi |
| **ATLANDI** ile **HATA** aynı kovaya girmemeli | Ölçemediğini fark edip 2 ile çıkan script dürüst davranır; ikisini karıştıran rapor ölçüm disiplinini cezalandırır |
| `grep -c` sıfırda **"0" basar ve 1 ile çıkar** | Alışkanlıkla eklenen `\|\| echo 0` değişkeni `0\n0` yapar; sonraki `(( ))` sözdizimi hatası verir ve bekleme döngüsü hiç sağlanmayacak bir koşulu bekler |
| **Bulamamak hata değildir** | `grep` eşleşme bulamazsa 1 döner; `pipefail` + atama + `set -e` scripti hüküm basmadan öldürür — üstelik genelde sağlıklı yolda |
| `${var:-varsayılan}` içindeki **kesme işareti** tırnak açar | "Endpoint'e" gibi bir varsayılan kapanış `}`'ını yutar ve script `bad substitution` ile ölür — yalnızca değişken boşken |
| Ölçü, **desteklediği iddiaya** göre daraltılmalı | "Uygulama yedekliliği" toplam 5xx ile ölçülürse, `drain`'in tek Postgres'i tahliye etmesinden gelen 5xx'ler de sayılır (P01-03) |
| Pod'un **"Running" olması**, servisin cevap vermesi değildir | WAL oynatan bir Prometheus Running görünürken her sorguya 503 döner |
| **Agrege bir APIService'i endpoint'siz bırakma** | Park edilen tek bir bileşen (KEDA), API keşfini bozup küme çapında namespace silmeyi durdurur |
| **Her zaman boş** bir panel, olmayan panelden kötüdür | Kazınmayan bir metrik "ihlal yok" gibi okunur, "veri yok" değil |
