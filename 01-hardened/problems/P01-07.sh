#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-07 · TRAP_LIVENESS_STRICT: sağlık uçlarını iş zincirinin arkasına koymak → restart fırtınası
# "Tek middleware zinciri var, her şey oradan geçsin" çok yaygın bir karardır. Sonucu şudur:
# trafik dalgası → probe hız sınırına takılır → kubelet pod'u ÖLDÜRÜR → yük kalan pod'a biner →
# o da ölür. Yani yük artışı, kendi kendine bir KESİNTİYE dönüşür.
ensure_healthy
step "Tuzağı aç: sağlık uçları iş zincirine giriyor + limit düşük"
kubectl -n "$NS" set env deploy/linkly TRAP_LIVENESS_STRICT=true RATE_LIMIT_PER_SEC=30 RATE_LIMIT_BURST=30 >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=120s >/dev/null
for _ in $(seq 1 20); do serving && break; sleep 2; done
pod=$(pod_name); before=$(restarts_of "$pod")
note "pod: $pod (restart: $before) · limit 30 rps · liveness her 10 sn'de bir /healthz"
step "Limitin üstünde trafik ver (60 sn) — probe da aynı kovadan içiyor"
k6run redirect --vus 10 --duration 60s >/dev/null 2>&1 || true
sleep 20
after=$(restarts_of "$pod"); [[ -z "$after" ]] && after=$(restarts_of "$(pod_name)")
probe429=$(kubectl -n "$NS" describe pod -l "$APP_SELECTOR" 2>/dev/null | grep -c 'Liveness probe failed' || true)
grafana_hint "01 · Pods & Resources → 'Restart sayısı' · 10 · Rate limit → 'reject/s'"
note "restart: $before → ${after:-?} · 'Liveness probe failed' olay sayısı: $probe429"
note "Doğrusu: sağlık uçları hız sınırının ve iş timeout'unun DIŞINDA kalır; liveness yalnızca"
note "'süreç kurtarılamaz mı?' sorusunu sorar. Bağımlılık kontrolü liveness'a girerse aynı tuzak 10'da büyür (P10-02)."
step "Tuzağı kapat"
kubectl -n "$NS" set env deploy/linkly TRAP_LIVENESS_STRICT- RATE_LIMIT_PER_SEC=5000 RATE_LIMIT_BURST=10000 >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=120s >/dev/null
{ (( ${after:-0} > before )) || (( probe429 > 0 )); } \
  && reproduced "yük altında liveness probe düştü → konteyner öldürüldü (restart $before→${after:-?}, $probe429 probe hatası)"
not_reproduced "sağlık uçları yükten etkilenmedi — zincirin dışındalar"
