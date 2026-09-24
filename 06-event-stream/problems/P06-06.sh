#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-06 · "Tam bir kez" diye bir teslimat yoktur — TRAP_COMMIT_BEFORE_WRITE ile ters ucu gör
# İki seçenek var ve ikisi de bir şey kaybettirir:
#   yaz→commit (varsayılan): tekrar teslim olur → ÇİFT SAYMA riski → idempotency ile emilir
#   commit→yaz (TRAP):       tekrar teslim OLMAZ → yazma başarısız olursa VERİ KAYBI
# Üçüncü bir seçenek yok. Mühendislik, hangi hatayı yaşayacağını seçmektir.
#
# ÖLDÜRME İKİ ADIMIN ARASINA DENK GELMELİ. İki mod ancak yazma ile commit ARASINDA ölen bir
# tüketicide ayrışır: yaz→commit'te "yazıldı, commit edilmedi", commit→yaz'da "commit edildi,
# yazılmadı". Kendi hâlinde bu aralık tek bir commit'in birkaç milisaniyesidir, birikim tek poll'da
# okunur ve yeni açılan pod partition'ı ancak grup dengelenince alır: sabit aralıklı öldürmeler
# aralığa değil, pod'un partition'ı henüz almadığı ya da işi çoktan bitirdiği anlara düşer ve iki mod
# aynı sayıyı verir. TRAP_COMMIT_DELAY_MS iki adımın SIRASINI korur, yalnızca arayı açık tutar;
# script aralığın AÇILDIĞINI tüketicinin kendi işaretinden görür ve o an öldürür:
#   yaz→commit: tıklama sayısı arttı (parti yazıldı), pod'un commit sayacı hâlâ 0
#   commit→yaz: pod'un commit sayacı > 0, tıklama sayısı artmadı (parti yazılmadı)
# Öldürme anında okunan bu iki sayı hükmün kanıtıdır; tutmuyorsa ölçüm yoktur (exit 2).
# EN: the two modes only differ for a consumer that dies BETWEEN write and commit. Left alone that
#     gap is milliseconds, the backlog arrives in one poll and a fresh pod owns the partition only
#     after the group rebalances, so kills on a fixed timer land before or after the gap and both
#     modes count the same. TRAP_COMMIT_DELAY_MS keeps the order and holds the gap open; the script
#     waits for the consumer's own signal that the gap is open and kills it right then. The two
#     numbers read at the kill are the evidence; without them there is no measurement (exit 2).
ensure_healthy
CONSUMER=analytics
need_confirm "tüketici pod'u iki kez öldürülecek"
N=${N:-2000}
DELAY_MS=${COMMIT_DELAY_MS:-30000}
DELAY_S=$(( DELAY_MS / 1000 ))
rp=$(dep_pod app.kubernetes.io/name=redpanda) || exit 2   # grup gecikmesi broker'dan okunur
on_cleanup "kubectl -n \"$NS\" scale "$(wl $CONSUMER)" --replicas=1"
on_cleanup "setenv "$(wl $CONSUMER)" TRAP_COMMIT_DELAY_MS- TRAP_COMMIT_BEFORE_WRITE-"

# Tüketici pod'unun KENDİ sayacı (Prometheus'a değil pod'a sor: öldürülen pod kazınmayı beklemez).
consumer_metric() {   # consumer_metric <pod> <awk-deseni> → değer (ulaşılamazsa 0; tek satır)
  { kubectl --request-timeout=5s -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$1:8080/proxy/metrics" 2>/dev/null || true; } \
    | awk -v pat="$2" '$0 ~ pat {s += $2} END {print s + 0}'
}
consumer_pods() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=$CONSUMER --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}
stats_clicks() { curl -s --max-time 5 "$BASE_URL/api/links/$1/stats" | jq -r '.clicks // 0' 2>/dev/null || echo 0; }
# Tüketici grubunun gecikmesi — broker'ın kendi cevabı, sütun ADIYLA okunur. Okunamazsa BOŞ döner
# ("-" gibi sayı olmayan bir LAG, sıfır sanılmasın).
group_lag() {
  { kubectl -n "$NS" exec "$rp" -- rpk group describe analytics 2>/dev/null || true; } \
    | awk '$1=="TOPIC" && $2=="PARTITION" {for (i=1;i<=NF;i++) if ($i=="LAG") c=i; next}
           c && $1=="clicks" {if ($c ~ /^[0-9]+$/) {s += $c; n++} else bad=1}
           END {if (n && !bad) print s}'
}

# run_kill_test <etiket> <default|trap> — birikim kur, aralık açılınca öldür, sayım durulunca oku.
# Sonuçlar global: COUNTED (sayılan), IN_WINDOW (1 = öldürme iki adımın arasındaydı),
# SETTLED (1 = grup gecikmesi 0'a indi, sayım tam), DUP (yeni pod'un duplicate sayacı).
run_kill_test() {
  local label=$1 mode=$2 code before tw=0 tk victim="" c commits_at_kill written_at_kill p
  local prev=-1 stable=0 cur
  COUNTED=0; IN_WINDOW=0; SETTLED=0; DUP=0
  kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=0 >/dev/null
  # Kapanmakta olan pod da tüketir: gerçekten gidene kadar bekle.
  kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=$CONSUMER --timeout=90s >/dev/null 2>&1 || true
  code=$(create_link "https://example.com/eo/$label")
  if [[ -z "$code" ]]; then warn "link oluşturulamadı"; return 0; fi
  before=$(stats_clicks "$code")
  clicks "$code" "$N" 20
  note "$N tıklama üretildi, hepsi topic'te bekliyor (tüketici kapalı)"
  kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=1 >/dev/null
  for _ in $(seq 1 180); do
    victim=$(consumer_pods | head -1)
    if [[ -n "$victim" ]]; then
      if [[ "$mode" == default ]]; then
        if (( $(stats_clicks "$code") > before )); then tw=$(date +%s); break; fi
      else
        c=$(consumer_metric "$victim" '^consumer_commits_total')
        if awk -v c="$c" 'BEGIN{exit !(c > 0)}'; then tw=$(date +%s); break; fi
      fi
    fi
    sleep 1
  done
  if (( tw == 0 )); then
    warn "tüketici 3 dk içinde aralığı açmadı: ilk parti ne yazıldı ne commit edildi"
    return 0
  fi
  commits_at_kill=$(consumer_metric "$victim" '^consumer_commits_total')
  written_at_kill=$(( $(stats_clicks "$code") - before ))
  kubectl -n "$NS" delete pod "$victim" --force --grace-period=0 >/dev/null 2>&1 || true
  tk=$(date +%s)
  note "öldürülen pod: $victim · aralık açıldıktan $(( tk - tw )) sn sonra · o an yazılmış $written_at_kill/$N · pod'un commit sayısı ${commits_at_kill%%.*}"
  # KANIT: öldürme anında pod gerçekten iki adımın ARASINDA mıydı? (Pencere DELAY_S sn açık kalır.)
  if (( tk - tw < DELAY_S - 3 )); then
    if [[ "$mode" == default ]] && (( written_at_kill > 0 )) \
       && awk -v c="$commits_at_kill" 'BEGIN{exit !(c == 0)}'; then IN_WINDOW=1; fi
    if [[ "$mode" == trap ]] && (( written_at_kill == 0 )) \
       && awk -v c="$commits_at_kill" 'BEGIN{exit !(c > 0)}'; then IN_WINDOW=1; fi
  fi
  # DURULMA ÖLÇÜSÜ BROKER'DAKİ GRUP GECİKMESİ. Yeni pod partition'ı ancak sert öldürülen üyenin
  # oturumu dolunca alır (franz-go varsayılanı 45 sn). yaz→commit'te gecikme her şey yazılıp commit
  # edilince 0 olur; commit→yaz'da commit'te 0 olur ve son yazma DELAY_S sn sonra gelir.
  kubectl -n "$NS" rollout status "$(wl $CONSUMER)" --timeout=120s >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do
    if [[ "$(group_lag)" == 0 ]]; then SETTLED=1; break; fi
    sleep 3
  done
  if [[ "$mode" == trap ]]; then sleep $(( DELAY_S + 5 )); fi
  for _ in $(seq 1 60); do
    cur=$(stats_clicks "$code")
    if [[ "$cur" == "$prev" ]]; then stable=$(( stable + 1 )); else stable=0; fi
    (( stable >= 4 )) && break          # 4 ardışık ölçümde (12 sn) değişmiyorsa durulmuştur
    prev=$cur; sleep 3
  done
  COUNTED=$(( $(stats_clicks "$code") - before ))
  for p in $(consumer_pods); do
    [[ "$p" == "$victim" ]] && continue
    DUP=$(awk -v a="$DUP" -v b="$(consumer_metric "$p" '^consumer_records_total.*result="duplicate"')" 'BEGIN{print a + b}')
  done
  return 0
}

step "VARSAYILAN (yaz → commit): ilk parti yazılır yazılmaz öldür — commit ${DELAY_S} sn sonra gelecekti"
setenv "$(wl $CONSUMER)" TRAP_COMMIT_DELAY_MS="$DELAY_MS" >/dev/null
settle_rollout "$(wl $CONSUMER)"
run_kill_test default default
def=$COUNTED; def_in=$IN_WINDOW; def_settled=$SETTLED; def_dup=$DUP
note "üretilen $N · sayılan $def · yeni pod'un duplicate sayacı ${def_dup%%.*} (tekrar teslim, idempotency yuttu)"

step "TRAP (commit → yaz): ilk parti commit edilir edilmez öldür — yazma ${DELAY_S} sn sonra gelecekti"
setenv "$(wl $CONSUMER)" TRAP_COMMIT_DELAY_MS="$DELAY_MS" TRAP_COMMIT_BEFORE_WRITE=true >/dev/null
settle_rollout "$(wl $CONSUMER)"
run_kill_test trap trap
trap_res=$COUNTED; trap_in=$IN_WINDOW; trap_settled=$SETTLED
note "üretilen $N · sayılan $trap_res → kayıp $(( N - trap_res ))"

grafana_hint "08 · Stream → 'Tüketilen kayıtlar (sonuca göre)' + 'Üretilen ve tüketilen olaylar (toplam)'"
note "Tabloyu oku: varsayılan mod sayıyı KORUR (tekrarları yutar); TRAP modu KAYBEDER."
note "Ne pahasına: processed_events tablosunda tıklama başına bir satır (saklama penceresi kadar)."
note "'Tam bir kez' pazarlama terimidir; gerçekte en-az-bir-kez + idempotent yazma vardır."
# ÖLDÜRME ARALIĞA DENK GELMEDİYSE HÜKÜM YOK: iki mod o zaman aynı sayıyı verir ve "fark yok"
# demek, eksik ölçümü sonuç sanmaktır.
if (( def_in != 1 )); then
  warn "ölçüm yapılamadı: varsayılan fazda öldürme 'yazıldı, commit edilmedi' aralığına denk gelmedi — COMMIT_DELAY_MS'i büyüt."
  exit 2
fi
if (( trap_in != 1 )); then
  warn "ölçüm yapılamadı: TRAP fazında öldürme 'commit edildi, yazılmadı' aralığına denk gelmedi — COMMIT_DELAY_MS'i büyüt."
  exit 2
fi
if (( def_settled != 1 || trap_settled != 1 )); then
  warn "ölçüm yapılamadı: tüketici grubunun gecikmesi 0'a inmedi (varsayılan=$def_settled, TRAP=$trap_settled) — sayım eksik olabilir."
  exit 2
fi
if (( def <= 0 )); then
  warn "ölçüm yapılamadı: varsayılan fazda hiçbir tıklama sayılmadı."
  exit 2
fi
# FARKI İDDİA EDİYORSAN FARKI ÖLÇ: "d >= t" iki taraf da 0 iken ya da iki mod eşitken de geçerdi.
# Hüküm iki ayrı gözleme dayanır: yaz→commit TAM sayar, commit→yaz EKSİK sayar.
# EN: the verdict needs both observations — write→commit counts exactly N, commit→write counts
#     fewer — each from a kill proven to be inside its gap.
if (( def == N && trap_res < N )); then
  reproduced "yaz→commit $def/$N (tekrar teslim idempotency ile emildi), commit→yaz $trap_res/$N ($(( N - trap_res )) tıklama kayıp) — commit noktası teslimat garantisini belirliyor"
fi
if (( def != N )); then
  not_reproduced "yaz→commit sayımı korumadı ($def/$N) — en-az-bir-kez + idempotent yazma beklenen sonucu vermedi"
fi
not_reproduced "commit→yaz da tam saydı ($trap_res/$N): commit edilmiş ama yazılmamış parti kaybolmadı"
