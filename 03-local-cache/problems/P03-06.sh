#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-06 · TRAP_NO_NEGATIVE_CACHE: "yok" cevabı önbelleklenmezse tarama doğrudan DB'ye iner
# Var olmayan kodlara yapılan her istek — ister kötü niyetli tarama, ister ölü linkler, ister
# yanlış yazılmış bir URL — önbelleği tamamen atlar. Önbellek yalnızca VAR OLANI korur;
# YOK OLAN, korumasız bir tüneldir.
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_NO_NEGATIVE_CACHE-"
run_scan() {
  kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  CODE_LEN=7 k6run scan --vus 30 --duration 40s >/dev/null 2>&1 || true
  sleep 12
  promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[1m]))"
}
step "Negatif önbellek AÇIK (varsayılan): rastgele kod taraması"
kubectl -n "$NS" set env deploy/linkly TRAP_NO_NEGATIVE_CACHE- >/dev/null
with=$(run_scan)
neg=$(promq "sum(increase(cache_ops_total{namespace=\"$NS\",result=\"negative_hit\"}[5m]))")
note "açıkken: DB get/s=$(awk -v v="$with" 'BEGIN{printf "%.0f", v}') · negatif isabet=${neg%%.*}"
step "Negatif önbellek KAPALI, aynı tarama"
kubectl -n "$NS" set env deploy/linkly TRAP_NO_NEGATIVE_CACHE=true >/dev/null
without=$(run_scan)
note "kapalıyken: DB get/s=$(awk -v v="$without" 'BEGIN{printf "%.0f", v}')"
grafana_hint "04 · Cache → 'ops by result & layer' (negative_hit) · 05 · Postgres → 'DB queries by op'"
note "Not: negatif önbelleğin TTL'i kısa olmalı — yeni oluşturulan bir link, eski 'yok' cevabının"
note "arkasında kalmasın. Bu seviyede CACHE_NEGATIVE_TTL=10s (pozitif TTL'in altıda biri)."
note "Tarama ayrıca bir hız sınırı sorunudur: 08'de 404 oranına göre limit uygulanacak."
awk -v a="$with" -v b="$without" 'BEGIN{exit !(b > a*1.5)}' \
  && reproduced "negatif önbellek kapalıyken tarama DB'yi $(awk -v v="$with" 'BEGIN{printf "%.0f", v}')/s → $(awk -v v="$without" 'BEGIN{printf "%.0f", v}')/s dövüyor"
not_reproduced "fark ölçülmedi (yük ya da TTL ayarını gözden geçir)"
