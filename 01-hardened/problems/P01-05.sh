#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-05 · Süreç İÇİ hız sınırı: N replikada limit N katına çıkar
# Limiter her pod'un belleğinde. "200 rps" yazdın; 3 pod ile client 600 rps geçirir.
ensure_healthy
need_confirm "limit düşürülüp replica 3'e çıkacak (deney sonunda geri alınır)"
orig=$(replicas_of)
on_cleanup 'kubectl -n "$NS" set env "$(app_workload)" RATE_LIMIT_PER_SEC=5000 RATE_LIMIT_BURST=10000'
on_cleanup "kubectl -n \"$NS\" scale deploy -l \"$APP_SELECTOR\" --replicas=$orig"
LIMIT=${LIMIT:-50}
step "Limiti pod başına $LIMIT rps'e çek, TEK pod ile geçen trafiği ölç"
kubectl -n "$NS" set env "$(app_workload)" RATE_LIMIT_PER_SEC="$LIMIT" RATE_LIMIT_BURST="$LIMIT" >/dev/null
scale 1; wait_endpoints 1; sleep 3
k6run redirect --vus 20 --duration 20s >/dev/null 2>&1 || true
one_ok=$(( $(k6_reqs) - $(k6_429) )); one_429=$(k6_429)
note "1 pod: kabul=$one_ok · 429=$one_429 → ölçülen ~$(( one_ok / 20 )) rps (beklenen ~$LIMIT)"
step "Aynı yük, 3 pod"
scale 3; wait_endpoints 3; sleep 3
k6run redirect --vus 20 --duration 20s >/dev/null 2>&1 || true
three_ok=$(( $(k6_reqs) - $(k6_429) ))
note "3 pod: kabul=$three_ok · 429=$(k6_429) → ölçülen ~$(( three_ok / 20 )) rps"
kubectl -n "$NS" set env "$(app_workload)" RATE_LIMIT_PER_SEC=5000 RATE_LIMIT_BURST=10000 >/dev/null
scale "$orig" >/dev/null 2>&1 || true
grafana_hint "10 · Rate limit → 'allow by pod' (her pod kendi kovasını dolduruyor)"
note "Limit bir SÖZDÜR; süreç içi tutulursa replika sayısıyla çarpılır. Üstelik dağılım eşitse şanslısın:"
note "değilse aynı client bazı pod'larda limitlenip bazılarında geçer — öngörülemez adalet."
awk -v a="$one_ok" -v b="$three_ok" 'BEGIN{exit !(b > a*1.5)}' \
  && reproduced "3 pod'da geçen trafik ~$(( three_ok / (one_ok>0?one_ok:1) ))x arttı ($one_ok → $three_ok) — limit pod sayısıyla çarpıldı"
not_reproduced "replika sayısı geçen trafiği değiştirmedi — limiter paylaşımlı (08)"
