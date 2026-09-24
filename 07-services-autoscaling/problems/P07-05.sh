#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-05 · Node kapasitesi bitince HPA "istiyor" ama alamıyor: Pending pod
# HPA replika SAYISI ister; o replikaları yerleştirmek scheduler'ın işidir. Node'larda yer yoksa
# pod Pending'de bekler ve otomatik ölçekleme sessizce durur. kind'da cluster autoscaler YOK —
# bulutta bu noktada node eklenir ve bu da dakikalar sürer (ölçekleme zincirinin en yavaş halkası).
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
need_confirm "redirect 10 replikaya çıkacak ve kümenin CPU rezervi dolacak (deney sonunda geri alınır)"
on_cleanup "kubectl -n \"$NS\" scale "$(wl redirect)" --replicas=2"
orig_lim=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null) || true
on_cleanup "setres "$(wl redirect)" --requests=cpu=150m --limits=cpu=${orig_lim:-300m}"
# HPA 10 REPLİKAYI TUTMALI. `kubectl scale` HPA'nın hedefini yalnızca bir sonraki döngüye (15 sn)
# kadar değiştirir: CPU düşük, HPA önerisi tabana (2) iner ve küçültme politikası (60 sn'de %50)
# 45 sn'lik bekleme içinde replikaları yarıya indirebilir — Pending pod'lar silinir ve ölçüm
# kapasiteyi değil HPA'yı ölçer. Tabanı (minReplicas) geçici olarak 10'a çekmek, 10'u HPA'nın
# KENDİ isteği yapar: tam da bu sorunun anlattığı "HPA istiyor, küme veremiyor" durumu. Temizlik
# eski tabanı geri koyar.
# EN: `kubectl scale` only moves the HPA's target until its next sync; with low CPU the HPA
#     recommends the floor and may halve the replicas inside the 45 s wait, deleting the Pending
#     pods. Raising minReplicas makes 10 the HPA's own request; cleanup restores the original floor.
orig_min=$(kubectl -n "$NS" get hpa redirect -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)
orig_max=$(kubectl -n "$NS" get hpa redirect -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)
if [[ -n "$orig_min" ]]; then
  on_cleanup "kubectl -n \"$NS\" patch hpa redirect --type=merge -p '{\"spec\":{\"minReplicas\":$orig_min,\"maxReplicas\":${orig_max:-12}}}'"
fi
step "Küme kapasitesi"
kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.allocatable.cpu,BELLEK:.status.allocatable.memory --no-headers | sed 's/^/    /'
alloc=$(promq 'sum(kube_node_status_allocatable{resource="cpu"})')
reqd=$(promq 'sum(kube_pod_container_resource_requests{resource="cpu"})')
note "toplam ayrılabilir CPU=$(awk -v v="$alloc" 'BEGIN{printf "%.1f", v}') · şu an istenen=$(awk -v v="$reqd" 'BEGIN{printf "%.1f", v}')"
step "İsteği büyüt ve çok replika iste — kapasiteyi kasıtlı olarak aş"
# LİMİTİ DE BÜYÜT: Kubernetes `requests > limits` olan bir pod'u REDDEDER. Yalnızca request
# büyütülürse (ör. 900m) limit 300m kaldığı için API isteği geri çevirir; script `set -e` ile ölür
# ve deney hiç kurulmaz.
# İSTEK DEĞERİ ORTAMA GÖRE: bu küme 4 node × 6 = 24 CPU "ayrılabilir" gösteriyor (gerçekte VM 6
# çekirdek, ama scheduler'ın gördüğü sayı budur ve Pending kararını O verir). 10 × 900m = 9 CPU
# rahat sığar ve PENDING=0 kalır. Pod'u bir node'a SIĞMAYACAK kadar büyük iste: node başına
# ayrılabilirin yarısından fazlası → 10 replikanın çoğu yer bulamaz.
node_cpu=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || echo 6) || true
# node_cpu "6" gibi bir tam sayı (ya da "6000m"). Her iki biçimi de millicore'a çevir.
case "$node_cpu" in *m) milli=${node_cpu%m} ;; *) milli=$(( node_cpu * 1000 )) ;; esac
req=$(( milli * 60 / 100 ))                      # node'un %60'ı → iki pod aynı node'a sığmaz
setres "$(wl redirect)" --requests=cpu=${req}m --limits=cpu=$(( req + 500 ))m >/dev/null
if [[ -n "$orig_min" ]]; then
  kubectl -n "$NS" patch hpa redirect --type=merge \
    -p "{\"spec\":{\"minReplicas\":10,\"maxReplicas\":$(( ${orig_max:-12} > 10 ? ${orig_max:-12} : 10 ))}}" >/dev/null
fi
kubectl -n "$NS" scale "$(wl redirect)" --replicas=10 >/dev/null
sleep 45
# KANIT: 45 sn sonra istenen replika HÂLÂ 10 mu? Değilse Pending sayısı kapasiteyi değil, isteği
# küçülten birini ölçer — hüküm verme.
want=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
if [[ "$want" != 10 ]]; then
  warn "ölçüm yapılamadı: istenen replika 45 sn içinde 10'dan ${want:-?}'a değişti (HPA ya da başka bir denetleyici küçülttü)."
  exit 2
fi
pending=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" --field-selector status.phase=Pending --no-headers 2>/dev/null | grep -c . || true)
ready=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.status.readyReplicas}') || true
reason=$(kubectl -n "$NS" get events --field-selector reason=FailedScheduling -o jsonpath='{range .items[-1:]}{.message}{end}' 2>/dev/null | head -c 160) || true
grafana_hint "09 · Autoscaling → 'Yer bekleyen pod' + 'Düğüm CPU: ayrılabilir / istenen'"
note "pod başına istek=${req}m (node ayrılabilir=${node_cpu}) · istenen replika=10 · hazır=${ready:-0} · PENDING=$pending"
[[ -n "$reason" ]] && note "scheduler diyor ki: $reason"
note "HPA'nın istediği (burada tabanı 10'a çekildi; bir yük dalgasında CPU'nun istediği) ile kümenin"
note "verebildiği arasındaki fark burada görünür. HPA bunu bilmez: Deployment 10 replika der, HPA 'mevcut"
note "10' görür ve mutlu görünür. Gerçeği yalnızca Pending sayacı söyler."
note "Bulutta çözüm: cluster autoscaler / Karpenter — ama o da node açmak için DAKİKALAR ister."
note "Yani ölçekleme zinciri: metrics-server(15s) → HPA(15s) → scheduler → NODE(dakikalar) → imaj → başlangıç."
note "Kapasite planlaması bu zincirin en yavaş halkasına göre yapılır, en hızlısına göre değil."
(( pending > 0 )) \
  && reproduced "$pending pod Pending'de kaldı — HPA 10 replika istedi, küme veremedi (hazır ${ready:-0}/10)"
not_reproduced "tüm replikalar yerleşti — küme kapasitesi yetti (istek değerini artırıp tekrar dene)"
