#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-06 · "Tam bir kez" diye bir teslimat yoktur — TRAP_COMMIT_BEFORE_WRITE ile ters ucu gör
# İki seçenek var ve ikisi de bir şey kaybettirir:
#   yaz→commit (varsayılan): tekrar teslim olur → ÇİFT SAYMA riski → idempotency ile emilir
#   commit→yaz (TRAP):       tekrar teslim OLMAZ → yazma başarısız olursa VERİ KAYBI
# Üçüncü bir seçenek yok. Mühendislik, hangi hatayı yaşayacağını seçmektir.
ensure_healthy
CONSUMER=analytics
on_cleanup "setenv "$(wl $CONSUMER)" TRAP_COMMIT_BEFORE_WRITE-"
# Her iki modda da AYNI kurulum: önce birikim (tüketici kapalı), sonra aç ve işlerken öldür.
# Tüketici üretimden hızlıysa ortada commit edilmemiş parti kalmaz ve iki mod da aynı sonucu verir
# — fark ölçülemez. Ölçmek istediğin durumu deneyin kendisi ÜRETMELİ.
run_kill_test() {
  local label=$1 code b a
  kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=0 >/dev/null
  kubectl -n "$NS" rollout status "$(wl $CONSUMER)" --timeout=120s >/dev/null 2>&1 || true
  code=$(create_link "https://example.com/eo/$label")
  b=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0') || true
  # BİRİKİM, ÖLDÜRME DİZİSİNDEN UZUN SÜRMELİ. 2000 kayıtla tüketici birikimi öldürmeler
  # başlamadan bitiriyor ve iki mod da 2000 sayıyor: fark yok, çünkü ölmek için geç kalındı.
  # EN: with 2000 records the consumer drains the backlog before the kills start, both modes
  # count 2000 and there is no difference — because the kills arrived too late.
  clicks "$code" "${N:-6000}" 20
  kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=1 >/dev/null
  # İşleme sırasında öldür
  for i in 1 2; do
    sleep 4
    kubectl -n "$NS" delete pod -l app.kubernetes.io/name=$CONSUMER --force --grace-period=0 >/dev/null 2>&1 || true
  done
  kubectl -n "$NS" rollout status "$(wl $CONSUMER)" --timeout=120s >/dev/null 2>&1 || true
  # Sabit bekleme YETMİYOR: sert öldürülen bir tüketicinin grubu yeniden dengelemesi (rebalance)
  # oturum zaman aşımı kadar sürebiliyor ve iki kill = iki rebalance. İlk ölçümde 2000 tıklamanın
  # 0'ı sayılmıştı — tüketici hâlâ dengelenirken okuduk. Sayım DURULANA kadar bekle.
  local prev=-1 stable=0 cur
  for _ in $(seq 1 60); do
    cur=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0') || true
    if [[ "$cur" == "$prev" ]]; then stable=$(( stable + 1 )); else stable=0; fi
    (( stable >= 4 )) && break          # 4 ardışık ölçümde (12 sn) değişmiyorsa durulmuştur
    prev=$cur; sleep 3
  done
  a=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0') || true
  echo $(( a - b ))
}
on_cleanup "kubectl -n \"$NS\" scale "$(wl $CONSUMER)" --replicas=1"
step "VARSAYILAN (yaz → commit) + idempotency: tekrar teslim çift saymaya dönüşmemeli"
need_confirm "tüketici pod'u tekrar tekrar öldürülecek"
def=$(run_kill_test default)
note "üretilen ${N:-6000} · sayılan $def  → fark $(( def - ${N:-6000} ))"
step "TRAP (commit → yaz): tekrar teslim yok, ama yazma başarısız olursa kayıp var"
setenv "$(wl $CONSUMER)" TRAP_COMMIT_BEFORE_WRITE=true >/dev/null
kubectl -n "$NS" rollout status "$(wl $CONSUMER)" --timeout=120s >/dev/null 2>&1 || true
trap_res=$(run_kill_test trap)
note "üretilen ${N:-6000} · sayılan $trap_res  → fark $(( trap_res - ${N:-6000} ))"
dup=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"duplicate\"}[15m]))")
grafana_hint "08 · Stream → 'consumer records by result' · 07 · Analytics → tıklama farkı"
note "duplicate sayacı: ${dup%%.*} — idempotency'nin emdiği tekrar sayısı"
note "Tabloyu oku: varsayılan mod sayıyı KORUR (tekrarları yutar); TRAP modu KAYBEDER."
note "Ne pahasına: processed_events tablosunda tıklama başına bir satır (saklama penceresi kadar)."
note "'Tam bir kez' pazarlama terimidir; gerçekte en-az-bir-kez + idempotent yazma vardır."
# KARAR TUZAĞI: ">=" / "<=" iki taraf da 0 iken GEÇER.
# EN: "b >= a" is true when nothing was measured at all (0 >= 0). That turns a failed measurement
#     into a passing experiment — the loudest possible false positive, because it looks like proof.
#     Guard the comparison with "we actually measured something".
# TR: "b >= a", hiçbir şey ölçülmediğinde de doğrudur (0 >= 0). Yani başarısız bir ölçüm, GEÇEN
#     bir deneye dönüşür — mümkün olan en gürültülü yanlış pozitif, çünkü kanıt gibi görünür.
#     Karşılaştırmayı "gerçekten bir şey ölçtük mü?" koşuluyla koru.
#     Aynı sebeple "d >= t" de yetmez: def==trap iken İKİ MOD ARASINDA FARK YOKTUR, oysa
#     hüküm "commit noktası teslimat garantisini belirliyor" diyor. Farkı iddia ediyorsan farkı ölç.
# EN: for the same reason "d >= t" is not enough either: when def==trap there is NO difference
#     between the modes, yet the verdict claims the commit point decides the guarantee. If you
#     assert a difference, measure a difference — require t < d, not t <= d.
awk -v d="$def" -v t="$trap_res" 'BEGIN{exit !(d > 0 && t < d)}' \
  && reproduced "yaz→commit $def, commit→yaz $trap_res (üretilen ${N:-6000}) — commit noktası teslimat garantisini belirliyor"
not_reproduced "iki mod arasında fark ölçülemedi (N'i artırıp tekrar dene)"
