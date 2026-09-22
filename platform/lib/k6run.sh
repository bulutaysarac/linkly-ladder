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
exec k6 run --tag "level=$NS" -e "BASE_URL=$BASE_URL" -e "LEVEL=$NS" -e "API_KEY=${API_KEY:-}" -o experimental-prometheus-rw "$@" "$LADDER_ROOT/platform/k6/scenarios/$S.js"
