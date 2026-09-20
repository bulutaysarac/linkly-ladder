#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-04 · TRAP_NO_TTL_JITTER: paylaşılan önbellekte hizalanma DAHA kötü
# 03'te jitter yokluğu pod başına bir dalga üretiyordu. 04'te tek bir önbellek var: TÜM pod'lar
# aynı anahtarların aynı anda dolmasını aynı anda görür. Dalga bölünmez, birleşir.
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_NO_TTL_JITTER- CACHE_TTL-"
TTLS=${TTLS:-20s}
warm_and_watch() {
  kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  for i in $(seq 1 400); do status_of "$(create_link "https://example.com/j4/$i")" >/dev/null; done
  k6run redirect --vus 5 --duration 90s >/dev/null 2>&1 || true
  sleep 10
  local peak avg
  peak=$(promq "max_over_time(sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[15s]))[3m:15s])")
  avg=$(promq "avg_over_time(sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[15s]))[3m:15s])")
  echo "$peak $avg"
}
step "Jitter AÇIK (varsayılan), TTL $TTLS"
kubectl -n "$NS" set env deploy/linkly CACHE_TTL="$TTLS" TRAP_NO_TTL_JITTER- >/dev/null
read -r p1 a1 <<< "$(warm_and_watch)"
r1=$(awk -v p="$p1" -v a="$a1" 'BEGIN{printf "%.1f", (a>0? p/a : 0)}')
note "jitter'lı: tepe=$(awk -v v="$p1" 'BEGIN{printf "%.0f", v}')/s ort=$(awk -v v="$a1" 'BEGIN{printf "%.0f", v}')/s → oran=$r1"
step "Jitter KAPALI"
kubectl -n "$NS" set env deploy/linkly TRAP_NO_TTL_JITTER=true >/dev/null
read -r p2 a2 <<< "$(warm_and_watch)"
r2=$(awk -v p="$p2" -v a="$a2" 'BEGIN{printf "%.1f", (a>0? p/a : 0)}')
note "jitter'sız: tepe=$(awk -v v="$p2" 'BEGIN{printf "%.0f", v}')/s ort=$(awk -v v="$a2" 'BEGIN{printf "%.0f", v}')/s → oran=$r2"
grafana_hint "05 · Postgres → 'DB queries by op' · 06 · Redis → 'evicted / expired keys'"
note "03'e göre fark: orada her pod kendi dalgasını üretiyordu (kısmen birbirini örtüyordu);"
note "burada tek önbellek var, dalga BİRLEŞİYOR. Paylaşmak, hizalanmayı da paylaşmak demek."
awk -v a="$r1" -v b="$r2" 'BEGIN{exit !(b > a)}' \
  && reproduced "jitter'sız tepe/ortalama $r1 → $r2 (paylaşılan önbellekte dalga birleşiyor)"
not_reproduced "tepe oranı artmadı (TTL/ısıtma penceresini gözden geçir)"
