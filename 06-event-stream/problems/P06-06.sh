#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-06 · "Tam bir kez" diye bir teslimat yoktur — TRAP_COMMIT_BEFORE_WRITE ile ters ucu gör
# İki seçenek var ve ikisi de bir şey kaybettirir:
#   yaz→commit (varsayılan): tekrar teslim olur → ÇİFT SAYMA riski → idempotency ile emilir
#   commit→yaz (TRAP):       tekrar teslim OLMAZ → yazma başarısız olursa VERİ KAYBI
# Üçüncü bir seçenek yok. Mühendislik, hangi hatayı yaşayacağını seçmektir.
ensure_healthy
CONSUMER=analytics
on_cleanup "kubectl -n \"$NS\" set env deploy/$CONSUMER TRAP_COMMIT_BEFORE_WRITE-"
run_kill_test() {
  local label=$1 code b a
  code=$(create_link "https://example.com/eo/$label")
  b=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  for i in $(seq 1 ${N:-500}); do status_of "$code" >/dev/null; done
  # İşleme sırasında öldür
  for i in 1 2; do
    sleep 2
    kubectl -n "$NS" delete pod -l app.kubernetes.io/name=$CONSUMER --force --grace-period=0 >/dev/null 2>&1 || true
  done
  kubectl -n "$NS" rollout status deploy/$CONSUMER --timeout=120s >/dev/null 2>&1 || true
  sleep 25
  a=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  echo $(( a - b ))
}
step "VARSAYILAN (yaz → commit) + idempotency: tekrar teslim çift saymaya dönüşmemeli"
need_confirm "tüketici pod'u tekrar tekrar öldürülecek"
def=$(run_kill_test default)
note "üretilen ${N:-500} · sayılan $def  → fark $(( def - ${N:-500} ))"
step "TRAP (commit → yaz): tekrar teslim yok, ama yazma başarısız olursa kayıp var"
kubectl -n "$NS" set env deploy/$CONSUMER TRAP_COMMIT_BEFORE_WRITE=true >/dev/null
kubectl -n "$NS" rollout status deploy/$CONSUMER --timeout=120s >/dev/null 2>&1 || true
trap_res=$(run_kill_test trap)
note "üretilen ${N:-500} · sayılan $trap_res  → fark $(( trap_res - ${N:-500} ))"
dup=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"duplicate\"}[15m]))")
grafana_hint "08 · Stream → 'consumer records by result' · 07 · Analytics → tıklama farkı"
note "duplicate sayacı: ${dup%%.*} — idempotency'nin emdiği tekrar sayısı"
note "Tabloyu oku: varsayılan mod sayıyı KORUR (tekrarları yutar); TRAP modu KAYBEDER."
note "Ne pahasına: processed_events tablosunda tıklama başına bir satır (saklama penceresi kadar)."
note "'Tam bir kez' pazarlama terimidir; gerçekte en-az-bir-kez + idempotent yazma vardır."
awk -v d="$def" -v t="$trap_res" -v n="${N:-500}" 'BEGIN{exit !(d >= t)}' \
  && reproduced "yaz→commit $d, commit→yaz $t (üretilen $n) — commit noktası teslimat garantisini belirliyor"
not_reproduced "iki mod arasında fark ölçülemedi (N'i artırıp tekrar dene)"
