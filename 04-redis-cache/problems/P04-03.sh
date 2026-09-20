#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-03 · Sıcak anahtar: tek bir link, tek bir Redis çekirdeği
# Redis TEK İŞ PARÇACIKLIDIR. Trafiğin %95'i tek anahtara giderse, o anahtarı hangi sunucuya
# koyarsan koy, tek bir çekirdeğin sınırına dayanırsın. Ölçeklenemeyen şey anahtar değil, ERİŞİMDİR.
ensure_healthy
step "Referans: dağıtık yük"
k6run redirect --vus 60 --duration 40s >/dev/null 2>&1 || true
sleep 12
spread_cpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redis.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[3m:15s])")
spread_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
note "dağıtık: Redis CPU tepe=$(awk -v v="$spread_cpu" 'BEGIN{printf "%.2f", v}') çekirdek · p99=$(awk -v v="$spread_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
step "Aynı yükün %95'i TEK anahtara"
HOT_SHARE=0.95 k6run hot-key --vus 60 --duration 40s >/dev/null 2>&1 || true
sleep 12
hot_cpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redis.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[3m:15s])")
hot_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
ops=$(promq "max_over_time(sum(rate(redis_commands_processed_total{namespace=\"$NS\"}[30s]))[3m:15s])")
grafana_hint "06 · Redis → 'Redis CPU' + 'ops/s' · 02 · App RED → 'p99 by route'"
note "hot-key: Redis CPU tepe=$(awk -v v="$hot_cpu" 'BEGIN{printf "%.2f", v}') çekirdek · p99=$(awk -v v="$hot_p99" 'BEGIN{printf "%.0f", v*1000}') ms · Redis ops/s tepe=$(awk -v v="$ops" 'BEGIN{printf "%.0f", v}')"
note "Redis'i ölçeklemek (cluster/sharding) BU sorunu çözmez: sıcak anahtar tek shard'a düşer."
note "Gerçek çözümler: (a) anahtarı çoğalt (key:1..N, rastgele oku) — tutarlılık maliyeti,"
note "                 (b) pod içinde L1 tut (14) — en sıcak anahtar hiç ağa çıkmaz,"
note "                 (c) CDN/edge — en popüler linkler uygulamaya hiç ulaşmaz."
awk -v a="$spread_cpu" -v b="$hot_cpu" 'BEGIN{exit !(b >= a)}' \
  && reproduced "sıcak anahtar Redis'i tek çekirdeğe sıkıştırdı (CPU $(awk -v v="$spread_cpu" 'BEGIN{printf "%.2f", v}') → $(awk -v v="$hot_cpu" 'BEGIN{printf "%.2f", v}'), ops/s $(awk -v v="$ops" 'BEGIN{printf "%.0f", v}'))"
not_reproduced "sıcak anahtar Redis'i zorlamadı — L1 devrede olabilir (14)"
