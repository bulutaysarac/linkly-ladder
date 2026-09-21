#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-04 · TRAP_NO_TTL_JITTER: paylaşılan önbellekte hizalanma DAHA kötü
# 03'te jitter yokluğu pod başına bir dalga üretiyordu. 04'te tek bir önbellek var: TÜM pod'lar
# aynı anahtarların aynı anda dolmasını aynı anda görür. Dalga bölünmez, birleşir.
#
# ÖLÇÜM NOTU (P03-07 ile aynı): darbe 1-2 saniye sürüyor, Prometheus 15 sn'de bir örnekliyor ve
# `rate(...[15s])` onu düzlüyor. Bu yüzden pod'un /metrics ucunu saniyede bir kendimiz örnekliyoruz.
# Sayaç olarak `result="miss"` seçildi: TTL Redis tarafında dolduğu için uygulama "expired" değil
# ıska görür. İlk ısınma saniyeleri atlanır, geriye yalnızca TTL dolmaları kalır.
TTLS=${TTLS:-30s}
LOAD=${LOAD:-150}
SKIP=${SKIP:-35}
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_NO_TTL_JITTER- CACHE_TTL-"
warm_and_watch() {
  local out=$1 pod
  kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null || true
  for _ in $(seq 1 30); do serving && break; sleep 2; done
  pod=$(pod_name)
  SEED=300 k6run redirect --vus 20 --duration "${LOAD}s" >/dev/null 2>&1 &
  local kpid=$!
  sample_series "$pod" "$LOAD" "$out" '^cache_ops_total\{.*result="miss"' "$SKIP"
  wait "$kpid" 2>/dev/null || true
}
step "Jitter AÇIK (varsayılan, ±%20), TTL $TTLS — ${LOAD}s boyunca saniyede bir örnekleniyor"
kubectl -n "$NS" set env deploy/linkly CACHE_TTL="$TTLS" TRAP_NO_TTL_JITTER- >/dev/null
warm_and_watch /tmp/p0404-jitter.txt
read -r p1 a1 r1 <<< "$(peak_avg /tmp/p0404-jitter.txt)"
note "jitter'lı:  tepe=${p1}/s ort=${a1}/s → tepe/ortalama=$r1"
step "Jitter KAPALI (TRAP_NO_TTL_JITTER), aynı senaryo"
kubectl -n "$NS" set env deploy/linkly TRAP_NO_TTL_JITTER=true >/dev/null
warm_and_watch /tmp/p0404-nojitter.txt
read -r p2 a2 r2 <<< "$(peak_avg /tmp/p0404-nojitter.txt)"
note "jitter'sız: tepe=${p2}/s ort=${a2}/s → tepe/ortalama=$r2"
note "Saniyelik seriler: /tmp/p0404-jitter.txt · /tmp/p0404-nojitter.txt"
grafana_hint "05 · Postgres → 'DB queries by op' · 06 · Redis → 'evicted / expired keys'"
note "03'e göre fark: orada her pod kendi dalgasını üretiyordu (kısmen birbirini örtüyordu);"
note "burada tek önbellek var, dalga BİRLEŞİYOR. Paylaşmak, hizalanmayı da paylaşmak demek."
awk -v a="$r1" -v b="$r2" 'BEGIN{exit !(b > a * 1.8 && b > 3)}' \
  && reproduced "jitter'sız tepe/ortalama $r1 → $r2 (paylaşılan önbellekte dalga birleşiyor)"
not_reproduced "tepe oranı artmadı (TTL/ısıtma penceresini gözden geçir)"
