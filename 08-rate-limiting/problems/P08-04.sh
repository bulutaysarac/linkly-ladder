#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-04 · Sabit pencere sayacı: pencere SINIRINDA limitin iki katı geçer
# Sabit pencere basit ve yanlıştır: 10 sn'lik pencerede 300 limit varsa, 9.9. saniyede 300 ve
# 10.1. saniyede 300 daha geçer — 0.2 saniyede 600. Kayan pencere bunu ağırlıklı toplamla düzeltir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_FIXED_WINDOW-"
win=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_WINDOW")]}{.value}{end}') || true
lim=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_PER_IP")]}{.value}{end}') || true
note "pencere=${win:-10s} · IP başına limit=${lim:-300}"
step "Pencere sınırına hizalanmış burst: sınırın hemen öncesi ve hemen sonrası"
# burst senaryosu pencere sınırını yakalayacak şekilde iki kez koşulur
k6run burst >/dev/null 2>&1 || true
sleep 10
peak10=$(promq "max_over_time(sum(rate(http_requests_total{namespace=\"$NS\",route=\"/{code}\",code!=\"429\"}[10s]))[3m:10s])")
allow=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"allow\",key_type=\"ip\"}[3m]))")
rej=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\",key_type=\"ip\"}[3m]))")
grafana_hint "10 · Rate limit → 'Kabul edilen rps (sınır testi)' + 'decisions by key type'"
note "kayan pencere ile: 10 sn'lik en yüksek kabul edilen hız ≈ $(awk -v v="$peak10" 'BEGIN{printf "%.0f", v*10}') istek/pencere (limit ${lim:-300})"
note "izin=${allow%%.*} · ret=${rej%%.*}"
note "Sabit pencere olsaydı, iki pencerenin sınırında ~2× (${lim:-300} yerine $(( ${lim:-300} * 2 ))) geçerdi."
note "Kayan pencere sayacı bunu şöyle çözer: önceki pencerenin sayımını, pencerede ne kadar"
note "ilerlediğine göre AĞIRLIKLANDIRIR — internal/ratelimit/redis.go'daki Lua betiği."
note "Daha kesin alternatifler: sliding window LOG (her isteğin zaman damgası — pahalı) ve"
note "token bucket (patlamaya izin verir, ortalamayı korur). Seçim, 'burst'e izin var mı?' sorusudur."
awk -v p="$peak10" -v l="${lim:-300}" 'BEGIN{exit !(p*10 <= l*1.5)}' \
  && reproduced "kayan pencere sınırı korudu: tepe ≈ $(awk -v v="$peak10" 'BEGIN{printf "%.0f", v*10}') / ${lim:-300} (sabit pencerede ~$(( ${lim:-300} * 2 )) beklenirdi)"
not_reproduced "tepe hız limiti aştı — pencere hesabını kontrol et"
