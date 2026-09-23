#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-04 · Süreç içi hız sınırı 3 replikada 3 katı (P01-05'in 02'deki hâli)
# 01'de bunu ölçmek için replika sayısını elle artırmak gerekiyordu; 02'de zaten 3 replika VAR,
# yani bu artık teorik bir uyarı değil, üretimdeki mevcut durum.
limits_enforced   # bu script limiter'ı sınıyor — yük girişi ve muafiyet jetonu KULLANILMAZ
ensure_healthy
LIMIT=${LIMIT:-40}
orig=$(replicas_of)
on_cleanup "setenv "$(app_workload)" RATE_LIMIT_PER_SEC=5000 RATE_LIMIT_BURST=10000"
on_cleanup "kubectl -n \"$NS\" scale deploy -l \"$APP_SELECTOR\" --replicas=$orig"
step "Limiti pod başına $LIMIT rps yap, TEK pod ile ölç"
setenv "$(app_workload)" RATE_LIMIT_PER_SEC="$LIMIT" RATE_LIMIT_BURST="$LIMIT" >/dev/null
scale 1; wait_endpoints 1; sleep 3
k6run redirect --vus 20 --duration 20s >/dev/null 2>&1 || true
one_ok=$(( $(k6_reqs) - $(k6_429) ))
note "1 pod → kabul edilen: $one_ok (~$(( one_ok / 20 )) rps, ayarlanan $LIMIT)"
step "Aynı yük, seviyenin gerçek replika sayısı ($orig)"
scale "$orig"; wait_endpoints "$orig"; sleep 3
k6run redirect --vus 20 --duration 20s >/dev/null 2>&1 || true
n_ok=$(( $(k6_reqs) - $(k6_429) ))
note "$orig pod → kabul edilen: $n_ok (~$(( n_ok / 20 )) rps)"
grafana_hint "10 · Rate limit → 'allow by pod' (her pod kendi kovası)"
note "Limit, kapasiteyi korumak içindi; korunması gereken kaynak (DB) TEK, koruma ise pod başına."
note "Yani tam korunması gereken yerde koruma $orig katına gevşiyor. 08: Redis'te paylaşılan limiter."
awk -v a="$one_ok" -v b="$n_ok" 'BEGIN{exit !(b > a*1.5)}' \
  && reproduced "$orig replikada geçen trafik $one_ok → $n_ok'ya çıktı; limit replika sayısıyla çarpıldı"
not_reproduced "replika sayısı geçen trafiği değiştirmedi — paylaşılan limiter (08)"
