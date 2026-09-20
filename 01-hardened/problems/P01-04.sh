#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-04 · Bellek hâlâ sınırsız büyüyor — ama artık büyümeyi ÖNCEDEN görüyorsun
# 00'da (P00-08) OOM'u ancak öldükten sonra anlıyordun. 01'de go_memstats + links_total var:
# ölmeden önce trend görünür. Sorun aynı: store'da eviction yok.
ensure_healthy
ensure_fresh_pod
step "Sürekli link üret, heap ile links_total birlikte nasıl tırmanıyor?"
h0=$(promq "max(go_memstats_heap_alloc_bytes{namespace=\"$NS\"})"); l0=$(promq "max(links_total{namespace=\"$NS\"})")
note "başlangıç: heap=$(( ${h0%%.*} / 1024 / 1024 ))MB · links=${l0%%.*}"
URL_SIZE=${URL_SIZE:-2000} k6run create --vus 1 --duration "${DURATION:-60s}" || true
sleep 12
h1=$(promq "max(go_memstats_heap_alloc_bytes{namespace=\"$NS\"})"); l1=$(promq "max(links_total{namespace=\"$NS\"})")
lim=$(kubectl -n "$NS" get deploy linkly -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
grafana_hint "01 · Pods & Resources → 'Heap alloc' ve 'Bellek working set' · 03 · App Business → 'links_total'"
note "bitiş:      heap=$(( ${h1%%.*} / 1024 / 1024 ))MB · links=${l1%%.*} (limit $lim)"
note "01'in kazancı: eğriyi ÖNCEDEN görüp alarm yazabilirsin. Kazanç bu kadar — tavan hâlâ aynı yerde."
awk -v a="${h0%%.*}" -v b="${h1%%.*}" 'BEGIN{exit !(b>a*1.5)}' \
  && reproduced "heap $(( ${h0%%.*} / 1024 / 1024 ))MB → $(( ${h1%%.*} / 1024 / 1024 ))MB; store hiç küçülmüyor, tek çıkış OOM (P00-08)"
not_reproduced "heap anlamlı büyümedi — store artık sınırlı ya da dışarıda (02/03)"
