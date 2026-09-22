#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-01 · En az bir kez: tüketici yazdıktan sonra commit'ten önce ölürse aynı olaylar TEKRAR gelir
# Dayanıklılığı kazandık (P05-01 çözüldü) ama artık farklı bir sorun var: ÇİFT SAYMA.
# İdempotency (processed_events tablosu) bunu emiyor; TRAP_COMMIT_BEFORE_WRITE ise ters ucu
# (commit önce → veri KAYBI) gösteriyor. "Tam bir kez" yok; seçtiğin şey hangi hatayı yaşayacağın.
ensure_healthy
CONSUMER=analytics
on_cleanup "setenv deploy/$CONSUMER TRAP_COMMIT_BEFORE_WRITE-"
# DENEY KURULUMU ÖNEMLİ: tüketiciyi ÖNCE durdurup birikim yarat, SONRA aç ve işlerken öldür.
# İlk hâlde tıklamalar üretilirken tüketici de çalışıyordu; olayları anında işleyip commit ediyor,
# öldürdüğümüzde ortada commit edilmemiş parti KALMIYORDU. Yani deney, ölçmek istediği durumu
# hiç oluşturmadan "tekrar teslim gözlenmedi" diyordu.
need_confirm "tüketici pod'u öldürülecek"
step "Tüketiciyi durdur ve birikim yarat"
kubectl -n "$NS" scale deploy/$CONSUMER --replicas=0 >/dev/null
on_cleanup "kubectl -n \"$NS\" scale deploy/$CONSUMER --replicas=1"
code=$(create_link "https://example.com/dedup")
N=${N:-2000}
before=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
clicks "$code" "$N" 20
note "$N tıklama üretildi, hepsi topic'te bekliyor (tüketici kapalı)"
# PENCEREYİ GÖRÜNÜR YAP: tekrar teslim, "yazdım ama henüz commit etmedim" aralığında öldürülürse
# olur. Bu aralık normalde milisaniyelerdir — tüketici partiyi yazıp hemen commit eder ve ne kadar
# öldürürsen öldür o aralığa denk gelmezsin (ilk ölçümde duplicate=0 çıktı). Postgres'e gecikme
# enjekte edince yazma saniyeler sürüyor ve aralık ölçülebilir genişliğe geliyor.
# P03-05 ile aynı ders: bir yarışın penceresi, onu besleyen işlemin süresidir.
chaos_apply pg-delay-2s
step "Tüketiciyi aç ve birikimi işlerken ÖLDÜR — commit edilmemiş partiler yeniden teslim edilecek"
kubectl -n "$NS" scale deploy/$CONSUMER --replicas=1 >/dev/null
# Öldürmeden ÖNCE işlemeye zaman ver: sert öldürülen tüketicinin grubu yeniden dengelemesi
# saniyeler sürüyor; hemen öldürürsen ortada commit edilmemiş parti değil, hiç başlamamış bir
# tüketici olur ve tekrar teslim GÖZLENMEZ. Ölçmek istediğin durumu deneyin kendisi üretmeli.
for i in 1 2 3; do
  sleep 10
  kubectl -n "$NS" delete pod -l app.kubernetes.io/name=$CONSUMER --force --grace-period=0 >/dev/null 2>&1 || true
done
kubectl -n "$NS" rollout status deploy/$CONSUMER --timeout=120s >/dev/null 2>&1 || true
# Sayım DURULANA kadar bekle (rebalance + birikimin işlenmesi sabit bir süre değildir).
prev=-1; stable=0
for _ in $(seq 1 60); do
  cur=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  if [[ "$cur" == "$prev" ]]; then stable=$(( stable + 1 )); else stable=0; fi
  (( stable >= 4 )) && break
  prev=$cur; sleep 3
done
after=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
counted=$(( after - before ))
dup=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"duplicate\"}[10m]))")
ok=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"ok\"}[10m]))")
grafana_hint "08 · Stream → 'consumer records by result' (duplicate) · 07 · Analytics → tıklama farkı"
note "üretilen: $N · sayılan: $counted · tüketici ok=${ok%%.*} duplicate=${dup%%.*}"
note "duplicate>0 demek: aynı olay birden fazla teslim edildi ve İDEMPOTENCY onu yuttu."
note "Sayım $N'e yakınsa 'tam bir kez ETKİ' çalışıyor: en-az-bir-kez teslimat + idempotent yazma."
note "Ters uç için: setenv deploy/$CONSUMER TRAP_COMMIT_BEFORE_WRITE=true"
note "  → commit yazmadan önce yapılır; tüketici ölürse o kayıtlar bir daha GELMEZ (veri kaybı)."
note "Dağıtık sistemlerde 'tam bir kez teslimat' yoktur; olan şey en-az-bir-kez + idempotency'dir."
awk -v d="${dup%%.*}" 'BEGIN{exit !(d>0)}' \
  && reproduced "${dup%%.*} olay tekrar teslim edildi ve çift sayılmadı (sayım $counted/$N) — en az bir kez + idempotency"
not_reproduced "tekrar teslim gözlenmedi (tüketici partiyi tamamlamış olabilir; N'i artırıp tekrar dene)"
