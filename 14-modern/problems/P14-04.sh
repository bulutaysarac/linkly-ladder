#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P14-04 · Kapasite modeli: ölçülmüş sayılarla zarf arkası hesabı
# System Design Primer'ın klasik sorusu: "100 milyon redirect/gün için ne gerekir?"
# Bu script cevabı TAHMİNLE değil, bu cluster'da ölçülmüş değerlerle veriyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Tek pod kapasitesini ÖLÇ (kademeli yük)"
orig=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.spec.replicas}' 2>/dev/null || kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.replicas}') || true
on_cleanup "kubectl -n \"$NS\" scale rollout/redirect --replicas=$orig 2>/dev/null || kubectl -n \"$NS\" scale "$(wl redirect)" --replicas=$orig"
kubectl -n "$NS" scale rollout/redirect --replicas=1 >/dev/null 2>&1 || kubectl -n "$NS" scale "$(wl redirect)" --replicas=1 >/dev/null
sleep 15; wait_endpoints 1
k6run stairs >/dev/null 2>&1 || true
sleep 15
peak_rps=$(promq "max_over_time(sum(rate(http_requests_total{namespace=\"$NS\",route=\"/{code}\",code!=\"429\",code!=\"503\"}[30s]))[6m:15s])")
p99=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))[6m:15s])")
cpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[6m:15s])")
hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",result=~\"hit|negative_hit\"}[3m])) / clamp_min(sum(rate(cache_ops_total{namespace=\"$NS\"}[3m])),0.001)")
dbq=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[3m]))")
note "ÖLÇÜLEN (tek pod): tepe kabul edilen rps=$(awk -v v="$peak_rps" 'BEGIN{printf "%.0f", v}') · tepe p99=$(awk -v v="$p99" 'BEGIN{printf "%.0f", v*1000}') ms · CPU=$(awk -v v="$cpu" 'BEGIN{printf "%.2f", v}') çekirdek"
note "önbellek hit oranı=$(awk -v v="$hit" 'BEGIN{printf "%.0f%%", v*100}') · DB okuma/s=$(awk -v v="$dbq" 'BEGIN{printf "%.1f", v}')"
step "Model: 100 milyon redirect/gün"
awk -v rps="$peak_rps" -v hit="$hit" 'BEGIN{
  daily=100000000; avg=daily/86400; peak=avg*3;
  printf "    ortalama = %.0f rps · tepe (3x) = %.0f rps\n", avg, peak;
  if (rps>0) printf "    gereken pod = %.0f (ölçülen %.0f rps/pod) + yedeklilik + burst tamponu\n", peak/rps+0.999, rps;
  printf "    DB okuma (hit %.0f%%) = %.0f/s · SOĞUK anda = %.0f/s\n", hit*100, peak*(1-hit), peak;
}'
note "Kritik satır SONUNCUSU: soğuk anda DB, tepe trafiğin TAMAMINI görür (P03-02)."
note "Kapasiteyi ortalamaya göre planlarsan ilk dağıtım seni devirir."
note "Tam model ve tüm darboğaz sıralaması: 14-modern/docs-capacity.md"
awk -v r="$peak_rps" 'BEGIN{exit !(r>0)}' \
  && reproduced "tek pod kapasitesi ölçüldü ($(awk -v v="$peak_rps" 'BEGIN{printf "%.0f", v}') rps, p99 $(awk -v v="$p99" 'BEGIN{printf "%.0f", v*1000}') ms) — kapasite modeli tahmine değil ölçüme dayanıyor"
not_reproduced "kapasite ölçülemedi (stairs yükü çalıştı mı?)"
