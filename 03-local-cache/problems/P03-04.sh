#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-04 · Hit oranı replika sayısıyla DÜŞER
# Load balancer istekleri rastgele dağıtıyor; aynı anahtar N farklı pod'a düşebiliyor. Sabit bir
# çalışma kümesi için her pod'un gördüğü örneklem küçülüyor → ısınma N kat uzuyor, hit oranı düşüyor.
ensure_healthy
need_confirm "replika sayısı değişecek (deney sonunda geri alınır)"
orig=$(replicas_of)
on_cleanup "kubectl -n \"$NS\" scale deploy -l \"$APP_SELECTOR\" --replicas=$orig"
measure() {
  local reps=$1
  scale "$reps"; wait_endpoints "$reps"
  kubectl -n "$NS" rollout restart deploy/linkly >/dev/null
  kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null 2>&1 || true
  wait_endpoints "$reps"; sleep 5
  k6run redirect --vus 20 --duration 45s >/dev/null 2>&1 || true
  sleep 12
  promq "sum(rate(cache_ops_total{namespace=\"$NS\",result=~\"hit|negative_hit\"}[1m])) / sum(rate(cache_ops_total{namespace=\"$NS\"}[1m]))"
}
step "1 replika ile hit oranı"
h1=$(measure 1); note "1 pod → hit oranı $(awk -v v="$h1" 'BEGIN{printf "%.1f%%", v*100}')"
step "$((orig > 3 ? orig : 6)) replika ile aynı yük"
many=$(( orig > 3 ? orig : 6 ))
h6=$(measure "$many"); note "$many pod → hit oranı $(awk -v v="$h6" 'BEGIN{printf "%.1f%%", v*100}')"
grafana_hint "04 · Cache → 'hit ratio by pod' · 'cache miss vs DB qps'"
note "Aynı çalışma kümesi, aynı yük, farklı hit oranı: pod başına örneklem küçüldü."
note "Bir çözüm consistent hashing'dir (aynı anahtar hep aynı pod'a) — ama o da sıcak anahtarı tek"
note "pod'a bağlar ve ölçekleme sırasında anahtarları taşır. 04 sorunu tamamen ortadan kaldırıyor."
awk -v a="$h1" -v b="$h6" 'BEGIN{exit !(a > b + 0.02)}' \
  && reproduced "hit oranı $(awk -v v="$h1" 'BEGIN{printf "%.1f%%", v*100}') → $(awk -v v="$h6" 'BEGIN{printf "%.1f%%", v*100}') düştü (replika 1 → $many)"
not_reproduced "hit oranı replika sayısından etkilenmedi — önbellek paylaşımlı (04)"
