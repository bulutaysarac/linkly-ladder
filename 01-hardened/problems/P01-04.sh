#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-04 · Bellek hâlâ sınırsız büyüyor — ama artık büyümeyi ÖNCEDEN görüyorsun
#
# ÖLÇÜM NOTU: "öncesi/sonrası heap" ölçmek YANILTIR — süreç test sırasında OOM olup yeniden doğarsa
# son ölçüm sıfırdan başlar ve "büyüme yok" gibi görünür (ilk denemede tam olarak bu oldu).
# Bu yüzden pencere içindeki TEPE değere ve OOM kanıtına bakıyoruz. Aynı tuzağa P00-08'de de düştük.
ensure_healthy
ensure_fresh_pod
pod=$(pod_name)
lim=$(kubectl -n "$NS" get deploy linkly -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}') || true
step "Sürekli link üret; heap, links_total ve konteyner belleği birlikte nasıl tırmanıyor?"
h0=$(promq "max(go_memstats_heap_alloc_bytes{namespace=\"$NS\"})")
note "başlangıç heap: $(( ${h0%%.*} / 1024 / 1024 )) MB · konteyner limiti: $lim · store'da eviction/TTL YOK"
URL_SIZE=${URL_SIZE:-2000} k6run create --vus 1 --duration "${DURATION:-90s}" || true
sleep 15
peak_heap=$(promq "max_over_time(max(go_memstats_heap_alloc_bytes{namespace=\"$NS\"})[10m:15s])")
peak_links=$(promq "max_over_time(max(links_total{namespace=\"$NS\"})[10m:15s])")
peak_ws=$(peak_working_set_mb 10m)
restarts_now=$(restarts_of "$pod"); reason=$(last_reason)
grafana_hint "01 · Pods & Resources → 'Heap alloc' + 'Bellek working set' · 03 · App Business → 'links_total'"
note "TEPE heap: $(( ${peak_heap%%.*} / 1024 / 1024 )) MB · TEPE links_total: ${peak_links%%.*} · TEPE working set: ${peak_ws} MB / $lim"
note "restart: ${restarts_now:-0} · son sonlanma nedeni: ${reason:-yok}"
note "01'in kazancı: eğriyi ÖNCEDEN görüp alarm yazabilmek. Tavan aynı yerde — çarpmadan haberin oluyor, o kadar."
[[ "$reason" == *OOMKilled* ]] && reproduced "bellek limiti ($lim) doldu → OOMKilled; store'da üst sınır yok, tek çıkış ölüm"
awk -v a="${h0%%.*}" -v b="${peak_heap%%.*}" 'BEGIN{exit !(b > a*1.5 && b > 20*1024*1024)}' \
  && reproduced "heap $(( ${h0%%.*} / 1024 / 1024 ))MB → tepe $(( ${peak_heap%%.*} / 1024 / 1024 ))MB (${peak_links%%.*} link); büyüme monoton, geri dönüş yok"
not_reproduced "bellek anlamlı büyümedi — store sınırlı ya da süreç dışında (02/03)"
