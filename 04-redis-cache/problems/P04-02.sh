#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-02 · Paylaşılan önbelleğin bedeli: sıcak yolda bir ağ gidiş-gelişi
# 03'te önbellek isabeti bir map aramasıydı (~100ns). 04'te bir ağ çağrısı (~0.3-1ms).
# Tutarlılığı kazandık, gecikmeyi ödedik. Ölçmeden "daha iyi" demek mühendislik değil temennidir.
ensure_healthy
step "Önbelleği ısıt, sonra sabit yük altında gecikmeyi ölç"
k6run redirect --vus 20 --duration 30s >/dev/null 2>&1 || true
k6run redirect --vus 20 --duration 45s || true
sleep 12
p50=$(num "$(promq "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")")
p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")")
hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\",result=\"hit\"}[2m])) / sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\"}[2m]))")
redis_cpu=$(promq "sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redis.*\",image!=\"\",image!~\".*pause.*\"}[2m]))")
grafana_hint "02 · App RED → 'latency p50/p95/p99' · 06 · Redis → 'App → Redis latency p99'"
note "hit oranı: $(awk -v v="$hit" 'BEGIN{printf "%.0f%%", v*100}') · redirect p50=$(awk -v v="$p50" 'BEGIN{printf "%.2f", v*1000}') ms · p99=$(awk -v v="$p99" 'BEGIN{printf "%.1f", v*1000}') ms"
note "Redis CPU: $(awk -v v="$redis_cpu" 'BEGIN{printf "%.2f", v}') çekirdek"
note "KARŞILAŞTIRMA: Grafana'da level=lvl03 seç ve aynı paneldeki p50'ye bak (03'te önbellek isabeti"
note "bellek erişimiydi). Fark, tutarlılık için ödediğin gecikmedir — ve genellikle ödemeye değer."
note "14'te L1+L2: en sıcak anahtarlar pod belleğinde, gerisi Redis'te — iki dünyanın iyi yanı,"
note "karşılığında yine bir geçersiz kılma kanalı borcu (pub/sub)."
awk -v v="$p50" 'BEGIN{exit !(v*1000 > 0.5)}' \
  && reproduced "önbellek isabeti artık ağ üzerinden: p50=$(awk -v v="$p50" 'BEGIN{printf "%.2f", v*1000}') ms (03'te bellek erişimiydi)"
not_reproduced "p50 bellek erişimi mertebesinde — L1 devrede olabilir (14)"
