#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-01 · En az bir kez: tüketici yazdıktan sonra commit'ten önce ölürse aynı olaylar TEKRAR gelir
# Dayanıklılığı kazandık (P05-01 çözüldü) ama artık farklı bir sorun var: ÇİFT SAYMA.
# İdempotency (processed_events tablosu) bunu emiyor; TRAP_COMMIT_BEFORE_WRITE ise ters ucu
# (commit önce → veri KAYBI) gösteriyor. "Tam bir kez" yok; seçtiğin şey hangi hatayı yaşayacağın.
ensure_healthy
CONSUMER=analytics
on_cleanup "setenv "$(wl $CONSUMER)" TRAP_COMMIT_BEFORE_WRITE-"
# DENEY KURULUMU ÖNEMLİ: tüketiciyi ÖNCE durdurup birikim yarat, SONRA aç ve işlerken öldür.
# İlk hâlde tıklamalar üretilirken tüketici de çalışıyordu; olayları anında işleyip commit ediyor,
# öldürdüğümüzde ortada commit edilmemiş parti KALMIYORDU. Yani deney, ölçmek istediği durumu
# hiç oluşturmadan "tekrar teslim gözlenmedi" diyordu.
need_confirm "tüketici pod'u öldürülecek"
step "Tüketiciyi durdur ve birikim yarat"
kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=0 >/dev/null
on_cleanup "kubectl -n \"$NS\" scale "$(wl $CONSUMER)" --replicas=1"
code=$(create_link "https://example.com/dedup")
N=${N:-2000}
before=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0') || true
clicks "$code" "$N" 20
note "$N tıklama üretildi, hepsi topic'te bekliyor (tüketici kapalı)"
# PENCEREYİ GÖRÜNÜR YAP — ve DOĞRU pencereyi seç.
# Tekrar teslim, "veritabanına YAZDIM ama offset'i henüz COMMIT ETMEDİM" aralığında öldürülürse
# olur. Bu aralık normalde milisaniyelerdir.
# İlk hâl POSTGRES'i geciktiriyordu (pg-delay-2s). O, pencereyi yazmanın ÖNCESİNDE genişletir:
# orada öldürürsen işlem GERİ ALINIR, hiçbir şey uygulanmamıştır, tekrar teslim onu İLK KEZ
# uygular ve gözlenecek bir duplicate olmaz — ölçüm tam olarak bu yüzden hep 0 çıkıyordu.
# Önemli olan pencere offset commit'idir, yani yavaşlatılacak şey BROKER'dır.
# P03-05 ile aynı ders bir adım ileri: bir yarışın penceresi onu besleyen işlemin süresidir ve
# hangi işlemin beslediğini yanlış bilirsen, kusursuz koşan ama etkiyi GÖSTEREMEYEN bir deney
# elde edersin.
chaos_apply redpanda-delay
# ÖLÇÜM PENCERESİ DENEYİN KENDİSİ KADAR OLMALI.
# EN: the first version queried `increase(...[10m])`. verify-prev had just replayed level 05's
#     scripts into this very namespace, so the 10-minute window contained ~50k records that had
#     nothing to do with this experiment — `ok=50460` looked like a healthy consumer while the
#     consumer had in fact processed ZERO records of our backlog. A window wider than the
#     experiment measures the neighbours, not the experiment.
# TR: ilk hâli `increase(...[10m])` soruyordu. verify-prev hemen öncesinde 05'in scriptlerini
#     AYNI namespace'e koşmuştu; yani 10 dakikalık pencerede bu deneyle ilgisi olmayan ~50 bin
#     kayıt vardı — `ok=50460` sağlıklı bir tüketici gibi görünüyordu, oysa tüketici bizim
#     birikimimizden SIFIR kayıt işlemişti. Deneyden geniş bir pencere, deneyi değil
#     KOMŞULARINI ölçer.
T0=$(date +%s)
step "Tüketiciyi aç ve birikimi işlerken ÖLDÜR — commit edilmemiş partiler yeniden teslim edilecek"
kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=1 >/dev/null
# Öldürmeden ÖNCE işlemeye zaman ver: sert öldürülen tüketicinin grubu yeniden dengelemesi
# saniyeler sürüyor; hemen öldürürsen ortada commit edilmemiş parti değil, hiç başlamamış bir
# tüketici olur ve tekrar teslim GÖZLENMEZ. Ölçmek istediğin durumu deneyin kendisi üretmeli.
for i in 1 2 3; do
  sleep 10
  kubectl -n "$NS" delete pod -l app.kubernetes.io/name=$CONSUMER --force --grace-period=0 >/dev/null 2>&1 || true
done
kubectl -n "$NS" rollout status "$(wl $CONSUMER)" --timeout=120s >/dev/null 2>&1 || true
# Sayım DURULANA kadar bekle (rebalance + birikimin işlenmesi sabit bir süre değildir).
prev=-1; stable=0
for _ in $(seq 1 60); do
  cur=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0') || true
  if [[ "$cur" == "$prev" ]]; then stable=$(( stable + 1 )); else stable=0; fi
  (( stable >= 4 )) && break
  prev=$cur; sleep 3
done
after=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0') || true
counted=$(( after - before ))
WIN=$(( $(date +%s) - T0 + 30 ))   # deney süresi + scrape payı
dup=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"duplicate\"}[${WIN}s]))")
ok=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"ok\"}[${WIN}s]))")
grafana_hint "08 · Stream → 'consumer records by result' (duplicate) · 07 · Analytics → tıklama farkı"
note "üretilen: $N · sayılan: $counted · tüketici ok=${ok%%.*} duplicate=${dup%%.*}"
note "duplicate>0 demek: aynı olay birden fazla teslim edildi ve İDEMPOTENCY onu yuttu."
note "Sayım $N'e yakınsa 'tam bir kez ETKİ' çalışıyor: en-az-bir-kez teslimat + idempotent yazma."
note "Ters uç için: setenv "$(wl $CONSUMER)" TRAP_COMMIT_BEFORE_WRITE=true"
note "  → commit yazmadan önce yapılır; tüketici ölürse o kayıtlar bir daha GELMEZ (veri kaybı)."
note "Dağıtık sistemlerde 'tam bir kez teslimat' yoktur; olan şey en-az-bir-kez + idempotency'dir."
# DENEY HİÇ ÇALIŞMADIYSA HÜKÜM VERME.
# EN: if the consumer processed nothing in the window, the redelivery we are looking for could
#     not have happened — reporting NOT-REPRODUCED would read as "the system is fine" when the
#     truth is "we never ran the experiment". Fail loudly instead; a missing measurement is not
#     a green result. (This is exactly how the 2s delay hid itself: it stopped the consumer dead
#     and the script called that a clean run.)
# TR: tüketici pencere boyunca hiçbir kayıt işlemediyse aradığımız tekrar teslim OLAMAZDI —
#     NOT-REPRODUCED demek "sistem sağlam" diye okunur, oysa gerçek "deneyi hiç koşmadık".
#     Yüksek sesle hata ver; EKSİK ÖLÇÜM yeşil bir sonuç değildir. (2 sn'lik gecikme tam olarak
#     böyle saklanmıştı: tüketiciyi tamamen durdurmuştu, script de buna temiz koşu demişti.)
if awk -v o="${ok%%.*}" 'BEGIN{exit !(o+0==0)}'; then
  warn "ölçüm yapılamadı: tüketici ${WIN}s'lik pencerede TEK KAYIT işlemedi (sayılan=$counted)."
  warn "Broker gecikmesi tüketiciyi yavaşlatmak yerine DURDURMUŞ olabilir; platform/chaos/redpanda-delay.yaml"
  warn "içindeki latency'yi düşür ve tekrar dene. Bu bir "sorun yok" sonucu değil, EKSİK ÖLÇÜMdür."
  exit 2
fi
awk -v d="${dup%%.*}" 'BEGIN{exit !(d>0)}' \
  && reproduced "${dup%%.*} olay tekrar teslim edildi ve çift sayılmadı (sayım $counted/$N) — en az bir kez + idempotency"
not_reproduced "tekrar teslim gözlenmedi (tüketici partiyi tamamlamış olabilir; N'i artırıp tekrar dene)"
