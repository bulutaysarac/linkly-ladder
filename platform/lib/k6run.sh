#!/usr/bin/env bash
# k6 senaryosunu bu seviye için koş; metrikleri Prometheus'a remote-write ile yaz (k6 dashboard'u).
set -euo pipefail
: "${NS:?}" "${BASE_URL:?}"
LADDER_ROOT=${LADDER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
PROM_URL=${PROM_URL:-http://prometheus.localtest.me}
source "$LADDER_ROOT/platform/lib/apikey.sh"
# API_KEY boşsa ladder.js Authorization başlığını HİÇ göndermez (13 öncesi davranış korunur).
API_KEY=$(ladder_api_key || true)
S=$1; shift
export K6_PROMETHEUS_RW_SERVER_URL=${K6_PROMETHEUS_RW_SERVER_URL:-$PROM_URL/api/v1/write}
export K6_PROMETHEUS_RW_TREND_STATS=${K6_PROMETHEUS_RW_TREND_STATS:-p(50),p(95),p(99),avg,max}
# SENARYO TANIMLI DOSYALARDA --duration/--vus ÖLDÜRÜCÜDÜR.
# EN: k6 refuses to start when CLI --duration/--vus are combined with an options.scenarios block:
#     "using multiple execution config shortcuts is not supported". It exits immediately, writes
#     no summary, and the calling script — which wraps the run in `|| true` because a failing load
#     run is normal — reads 0 requests and 0 rejections and concludes "no difference between the
#     three modes". P08-01/03/06 measured a k6 that never ran. The flags are translated to env
#     vars here instead of being fixed at four call sites, because the next scenario file that
#     grows a `scenarios:` block would silently break the same way.
# TR: k6, CLI --duration/--vus ile options.scenarios bloğu bir aradayken BAŞLAMAZ: "using multiple
#     execution config shortcuts is not supported". Anında çıkar, özet yazmaz ve çağıran script —
#     başarısız bir yük koşusu normal olduğu için koşuyu `|| true` ile sarmalar — 0 istek, 0 ret
#     okuyup "üç mod arasında fark yok" der. P08-01/03/06 hiç koşmamış bir k6'yı ölçtü.
#     Bayraklar dört çağrı yerinde değil BURADA çevriliyor: `scenarios:` bloğu kazanan bir sonraki
#     senaryo dosyası da aynı şekilde sessizce bozulurdu.
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
  set -- "${conv[@]}"
fi
exec k6 run --tag "level=$NS" -e "BASE_URL=$BASE_URL" -e "LEVEL=$NS" -e "API_KEY=${API_KEY:-}" -o experimental-prometheus-rw "$@" "$LADDER_ROOT/platform/k6/scenarios/$S.js"
