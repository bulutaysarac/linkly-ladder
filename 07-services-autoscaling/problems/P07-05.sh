#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-05 · Node kapasitesi bitince HPA "istiyor" ama alamıyor: Pending pod
# HPA replika SAYISI ister; o replikaları yerleştirmek scheduler'ın işidir. Node'larda yer yoksa
# pod Pending'de bekler ve otomatik ölçekleme sessizce durur. kind'da cluster autoscaler YOK —
# bulutta bu noktada node eklenir ve bu da dakikalar sürer (ölçekleme zincirinin en yavaş halkası).
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" scale deploy/redirect --replicas=2"
on_cleanup "kubectl -n \"$NS\" set resources deploy/redirect --requests=cpu=150m"
step "Küme kapasitesi"
kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.allocatable.cpu,BELLEK:.status.allocatable.memory --no-headers | sed 's/^/    /'
alloc=$(promq 'sum(kube_node_status_allocatable{resource="cpu"})')
reqd=$(promq 'sum(kube_pod_container_resource_requests{resource="cpu"})')
note "toplam ayrılabilir CPU=$(awk -v v="$alloc" 'BEGIN{printf "%.1f", v}') · şu an istenen=$(awk -v v="$reqd" 'BEGIN{printf "%.1f", v}')"
step "İsteği büyüt ve çok replika iste — kapasiteyi kasıtlı olarak aş"
kubectl -n "$NS" set resources deploy/redirect --requests=cpu=900m >/dev/null
kubectl -n "$NS" scale deploy/redirect --replicas=10 >/dev/null
sleep 45
pending=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" --field-selector status.phase=Pending --no-headers 2>/dev/null | grep -c . || true)
ready=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{.status.readyReplicas}')
reason=$(kubectl -n "$NS" get events --field-selector reason=FailedScheduling -o jsonpath='{range .items[-1:]}{.message}{end}' 2>/dev/null | head -c 160)
grafana_hint "09 · Autoscaling → 'Pending pod' + 'Node CPU allocatable vs requests'"
note "istenen replika=10 · hazır=${ready:-0} · PENDING=$pending"
[[ -n "$reason" ]] && note "scheduler diyor ki: $reason"
note "HPA'nın istediği ile kümenin verebildiği arasındaki fark burada görünür. HPA bunu bilmez;"
note "desiredReplicas=10 der ve mutlu görünür. Gerçeği yalnızca Pending sayacı söyler."
note "Bulutta çözüm: cluster autoscaler / Karpenter — ama o da node açmak için DAKİKALAR ister."
note "Yani ölçekleme zinciri: metrik(15s) → HPA(15s) → scheduler → NODE(dakikalar) → imaj → başlangıç."
note "Kapasite planlaması bu zincirin en yavaş halkasına göre yapılır, en hızlısına göre değil."
(( pending > 0 )) \
  && reproduced "$pending pod Pending'de kaldı — HPA istedi, küme veremedi (hazır ${ready:-0}/10)"
not_reproduced "tüm replikalar yerleşti — küme kapasitesi yetti (istek değerini artırıp tekrar dene)"
