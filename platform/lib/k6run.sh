#!/usr/bin/env bash
# k6 senaryosunu bu seviye için koş; metrikleri Prometheus'a remote-write ile yaz (k6 dashboard'u).
set -euo pipefail
: "${NS:?}" "${BASE_URL:?}"
LADDER_ROOT=${LADDER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
PROM_URL=${PROM_URL:-http://prometheus.localtest.me}
source "$LADDER_ROOT/platform/lib/apikey.sh"
# API_KEY boşsa ladder.js Authorization başlığını HİÇ göndermez (13 öncesi davranış korunur).
API_KEY=$(ladder_api_key || true)
# Yük hangi girişten gidiyor? Limiter'ı sınamayan her deney yük girişinden, jetonla (loadtest.sh).
# Seçim hem ekrana hem k6 metriklerine (entry=load|public) yazılır: sonradan "bu sayı limiter'dan mı
# geçti?" sorusu cevapsız kalmasın.
source "$LADDER_ROOT/platform/lib/loadtest.sh"
LOADTEST_TOKEN=""; K6_BASE_URL=$BASE_URL; ENTRY=public
if [[ "${LIMITS_ENFORCED:-0}" != 1 ]]; then
  LOADTEST_TOKEN=$(ladder_loadtest_token)
  load_url=$(ladder_load_url)
  if [[ -n "$LOADTEST_TOKEN" && -n "$load_url" ]]; then K6_BASE_URL=$load_url; ENTRY=load; fi
fi
echo "k6 girişi: $ENTRY ($K6_BASE_URL)" >&2
S=$1; shift
export K6_PROMETHEUS_RW_SERVER_URL=${K6_PROMETHEUS_RW_SERVER_URL:-$PROM_URL/api/v1/write}
export K6_PROMETHEUS_RW_TREND_STATS=${K6_PROMETHEUS_RW_TREND_STATS:-p(50),p(95),p(99),avg,max}
# SENARYO TANIMLI DOSYALARDA --duration/--vus ÖLDÜRÜCÜDÜR.
# EN: k6 refuses to start when --duration/--vus are combined with an options.scenarios block:
#     "using multiple execution config shortcuts is not supported". It exits immediately and
#     writes no summary; the caller wraps the run in `|| true` (a failing load run is normal), so
#     an unstarted run would read as 0 requests and 0 rejections — "no difference between the
#     modes". The flags are translated to env vars here, once, for every scenario file: a
#     scenario that grows a `scenarios:` block keeps working without touching its call sites.
# TR: k6, --duration/--vus ile options.scenarios bloğu bir aradayken BAŞLAMAZ: "using multiple
#     execution config shortcuts is not supported". Anında çıkar ve özet yazmaz; çağıran script
#     koşuyu `|| true` ile sarmaladığı için (başarısız bir yük koşusu normaldir) hiç başlamamış
#     bir koşu 0 istek, 0 ret — "modlar arasında fark yok" — diye okunurdu. Bayraklar BURADA,
#     bir kez ve her senaryo dosyası için env değişkenine çevrilir: `scenarios:` bloğu kazanan
#     bir senaryo, çağrı yerlerine dokunmadan çalışmaya devam eder.
SCEN_FILE="$LADDER_ROOT/platform/k6/scenarios/$S.js"
if grep -q 'scenarios:' "$SCEN_FILE" 2>/dev/null; then
  conv=(); i=0; argv=("$@")
  while (( i < ${#argv[@]} )); do
    case "${argv[i]}" in
      --duration) conv+=(-e "DURATION=${argv[i+1]}"); i=$(( i + 2 )) ;;
      --vus)      conv+=(-e "VUS=${argv[i+1]}");      i=$(( i + 2 )) ;;
      *)          conv+=("${argv[i]}");               i=$(( i + 1 )) ;;
    esac
  done
  # BOŞ DİZİ TUZAĞI (bash 3.2): `k6run burst` gibi EK ARGÜMANSIZ bir çağrıda conv boştur ve
  # "${conv[@]}" set -u altında "unbound variable" verir — yani korumasız açılımla, senaryo
  # dosyası `scenarios:` içerdiği anda argümansız her k6 koşusu HİÇ BAŞLAMAZ.
  # EN: with no extra args `conv` is empty and "${conv[@]}" is an unbound-variable error on
  # bash 3.2 — every argument-less k6 run against a scenarios file would fail to start at all.
  set -- ${conv[@]+"${conv[@]}"}
fi
# p(99) k6'NIN VARSAYILAN ÖZETİNDE YOK (avg,min,med,max,p(90),p(95)). Eklenmezse özet satırı
# `p99=NaN` basar ve özetten p(99) okuyan scriptler (P08-06: normal kullanıcı p99) hep 0 okur —
# ölçüm yokken "normal kullanıcı etkilenmedi". Tüm senaryolar için buradan ekleniyor.
# EN: p(99) is not in k6's default summary stats; without this every script reading it gets 0.
exec k6 run --summary-trend-stats "avg,min,med,max,p(90),p(95),p(99)" --tag "level=$NS" --tag "entry=$ENTRY" -e "BASE_URL=$K6_BASE_URL" -e "LEVEL=$NS" -e "API_KEY=${API_KEY:-}" \
  -e "LOADTEST_TOKEN=$LOADTEST_TOKEN" -e "LADDER_OWNER=${K6_OWNER:-none} " -o experimental-prometheus-rw "$@" "$LADDER_ROOT/platform/k6/scenarios/$S.js"
