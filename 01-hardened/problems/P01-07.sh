#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-07 · TRAP_LIVENESS_STRICT: sağlık uçlarını iş zincirinin arkasına koymak → restart fırtınası
# "Tek middleware zinciri var, her şey oradan geçsin" çok yaygın bir karardır. Sonucu şudur:
# trafik dalgası → probe hız sınırına takılır → kubelet pod'u ÖLDÜRÜR → yük kalan pod'a biner →
# o da ölür. Yani yük artışı, kendi kendine bir KESİNTİYE dönüşür.
limits_enforced   # bu script limiter'ı sınıyor — yük girişi ve muafiyet jetonu KULLANILMAZ
ensure_healthy
on_cleanup 'setenv "$(app_workload)" TRAP_LIVENESS_STRICT- RATE_LIMIT_PER_SEC=5000 RATE_LIMIT_BURST=10000'
step "Tuzağı aç: sağlık uçları iş zincirine giriyor + limit düşük"
setenv "$(app_workload)" TRAP_LIVENESS_STRICT=true RATE_LIMIT_PER_SEC=30 RATE_LIMIT_BURST=30 >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=120s >/dev/null || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
pod=$(pod_name); before=$(restarts_of "$pod")
note "pod: $pod (restart: $before) · limit 30 rps · liveness her 10 sn'de bir /healthz"
note "liveness toleransı: failureThreshold($(kubectl -n "$NS" get "$(app_workload)" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.failureThreshold}')) × periodSeconds($(kubectl -n "$NS" get "$(app_workload)" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.periodSeconds}')) sn — yük bundan UZUN sürmeli"
step "Limitin üstünde trafik ver (150 sn) — probe da aynı kovadan içiyor"
k6run redirect --vus 10 --duration "${DURATION:-150s}" >/dev/null 2>&1 || true
sleep 20
after=$(restarts_of "$pod"); [[ -z "$after" ]] && after=$(restarts_of "$(pod_name)")
# Olayları describe'dan değil doğrudan event API'sinden say: describe çıktısı kırpılıyor.
probe429=$(kubectl -n "$NS" get events --field-selector reason=Unhealthy -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -ci 'liveness' || true)
ready429=$(kubectl -n "$NS" get events --field-selector reason=Unhealthy -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -ci 'readiness' || true)
grafana_hint "01 · Pods & Resources → 'Restart sayısı' · 10 · Rate limit → 'reject/s'"
note "restart: $before → ${after:-?} · Unhealthy(liveness) olayı: $probe429 · Unhealthy(readiness) olayı: $ready429"
note "readiness de aynı kovadan içiyor: probe 429 alınca pod Endpoints'ten DÜŞER — yani daha restart olmadan trafik almayı bırakır."
note "Doğrusu: sağlık uçları hız sınırının ve iş timeout'unun DIŞINDA kalır; liveness yalnızca"
note "'süreç kurtarılamaz mı?' sorusunu sorar. Bağımlılık kontrolü liveness'a girerse aynı tuzak 10'da büyür (P10-02)."
step "Tuzağı kapat"
setenv "$(app_workload)" TRAP_LIVENESS_STRICT- RATE_LIMIT_PER_SEC=5000 RATE_LIMIT_BURST=10000 >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=120s >/dev/null || true
{ (( ${after:-0} > before )) || (( probe429 > 0 )) || (( ready429 > 0 )); } \
  && reproduced "yük altında sağlık probe'ları düştü (liveness $probe429, readiness $ready429 olay; restart ${before}→${after:-?}) — trafik artışı kendini kesintiye çevirdi"
not_reproduced "sağlık uçları yükten etkilenmedi — zincirin dışındalar"
