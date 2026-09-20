#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-02 · Her istek için +1 Redis gidiş-gelişi (aslında iki: kiracı + IP)
# Doğruluk için ödediğin gecikme. 07'de limit kontrolü bellekteki bir map'ti (~100ns);
# şimdi iki ağ çağrısı. Sıcak yolda yapılan her "küçük" kontrol, p50'ye doğrudan eklenir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Limit kontrolünün kendi süresi"
k6run redirect --vus 20 --duration 40s >/dev/null 2>&1 || true
sleep 10
rl_p99=$(promq "histogram_quantile(0.99, sum(rate(ratelimit_check_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")
rl_p50=$(promq "histogram_quantile(0.50, sum(rate(ratelimit_check_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")
req_p50=$(promq "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
req_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
share=$(awk -v a="$rl_p50" -v b="$req_p50" 'BEGIN{printf "%.0f", (b>0? a*100/b : 0)}')
redis_ops=$(promq "sum(rate(redis_commands_processed_total{namespace=\"$NS\"}[2m]))")
http_rps=$(promq "sum(rate(http_requests_total{namespace=\"$NS\",route=\"/{code}\"}[2m]))")
grafana_hint "10 · Rate limit → 'decisions by key type' · 06 · Redis → 'ops/s' · 02 · App RED → p50"
note "limit kontrolü: p50=$(awk -v v="$rl_p50" 'BEGIN{printf "%.2f", v*1000}') ms · p99=$(awk -v v="$rl_p99" 'BEGIN{printf "%.2f", v*1000}') ms"
note "istek toplam: p50=$(awk -v v="$req_p50" 'BEGIN{printf "%.2f", v*1000}') ms · p99=$(awk -v v="$req_p99" 'BEGIN{printf "%.2f", v*1000}') ms"
note "limit kontrolü isteğin ~%$share'ini alıyor"
note "Redis ops/s=$(awk -v v="$redis_ops" 'BEGIN{printf "%.0f", v}') · HTTP rps=$(awk -v v="$http_rps" 'BEGIN{printf "%.0f", v}') → istek başına ~$(awk -v a="$redis_ops" -v b="$http_rps" 'BEGIN{printf "%.1f", (b>0? a/b : 0)}') Redis komutu"
note "Beklenen oran ~3: 1 önbellek GET + 2 limit kontrolü (kiracı + IP). Sayı bundan büyükse"
note "bir yerde gereksiz bir tur var demektir."
note "Azaltma: (a) pipeline ile iki kontrolü tek gidiş-gelişte yap, (b) pod'da kısa ömürlü bir"
note "yerel token tamponu tut (doğruluğu bir miktar feda eder), (c) ucuz reddi ingress'e bırak."
awk -v v="$rl_p50" 'BEGIN{exit !(v > 0)}' \
  && reproduced "limit kontrolü sıcak yola $(awk -v v="$rl_p50" 'BEGIN{printf "%.2f", v*1000}') ms ekledi (isteğin ~%$share'i, istek başına ~$(awk -v a="$redis_ops" -v b="$http_rps" 'BEGIN{printf "%.1f", (b>0? a/b : 0)}') Redis komutu)"
not_reproduced "limit kontrolü süresi ölçülemedi (dağıtık limiter devrede mi?)"
