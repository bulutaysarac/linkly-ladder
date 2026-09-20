#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-01 · En az bir kez: tüketici yazdıktan sonra commit'ten önce ölürse aynı olaylar TEKRAR gelir
# Dayanıklılığı kazandık (P05-01 çözüldü) ama artık farklı bir sorun var: ÇİFT SAYMA.
# İdempotency (processed_events tablosu) bunu emiyor; TRAP_COMMIT_BEFORE_WRITE ise ters ucu
# (commit önce → veri KAYBI) gösteriyor. "Tam bir kez" yok; seçtiğin şey hangi hatayı yaşayacağın.
ensure_healthy
CONSUMER=analytics
on_cleanup "kubectl -n \"$NS\" set env deploy/$CONSUMER TRAP_COMMIT_BEFORE_WRITE-"
step "Bilinen sayıda tıklama üret"
code=$(create_link "https://example.com/dedup")
N=${N:-600}
before=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
for i in $(seq 1 "$N"); do status_of "$code" >/dev/null; done
step "Tüketiciyi işlerken öldür (birkaç kez) — commit edilmemiş partiler yeniden teslim edilecek"
need_confirm "tüketici pod'u öldürülecek"
for i in 1 2 3; do
  kubectl -n "$NS" delete pod -l app.kubernetes.io/name=$CONSUMER --force --grace-period=0 >/dev/null 2>&1 || true
  sleep 6
done
kubectl -n "$NS" rollout status deploy/$CONSUMER --timeout=120s >/dev/null 2>&1 || true
sleep 20
after=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
counted=$(( after - before ))
dup=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"duplicate\"}[10m]))")
ok=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"ok\"}[10m]))")
grafana_hint "08 · Stream → 'consumer records by result' (duplicate) · 07 · Analytics → tıklama farkı"
note "üretilen: $N · sayılan: $counted · tüketici ok=${ok%%.*} duplicate=${dup%%.*}"
note "duplicate>0 demek: aynı olay birden fazla teslim edildi ve İDEMPOTENCY onu yuttu."
note "Sayım $N'e yakınsa 'tam bir kez ETKİ' çalışıyor: en-az-bir-kez teslimat + idempotent yazma."
note "Ters uç için: kubectl -n $NS set env deploy/$CONSUMER TRAP_COMMIT_BEFORE_WRITE=true"
note "  → commit yazmadan önce yapılır; tüketici ölürse o kayıtlar bir daha GELMEZ (veri kaybı)."
note "Dağıtık sistemlerde 'tam bir kez teslimat' yoktur; olan şey en-az-bir-kez + idempotency'dir."
awk -v d="${dup%%.*}" 'BEGIN{exit !(d>0)}' \
  && reproduced "${dup%%.*} olay tekrar teslim edildi ve çift sayılmadı (sayım $counted/$N) — en az bir kez + idempotency"
not_reproduced "tekrar teslim gözlenmedi (tüketici partiyi tamamlamış olabilir; N'i artırıp tekrar dene)"
