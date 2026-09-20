#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-07 · Tüm replikalar aynı node'a düşerse yedeklilik kâğıt üstünde kalır
# topologySpreadConstraints `ScheduleAnyway` ile YUMUŞAK bir tercihtir: scheduler yer bulamazsa
# kuralı çiğner ve hepsini aynı node'a koyar. Node donduğunda "3 replikam var" demen işe yaramaz.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Replikalar hangi node'larda?"
kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName --no-headers | sed 's/^/    /'
nodes=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c .)
reps=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{.status.readyReplicas}')
note "replika=$reps · farklı node=$nodes · dağılım kuralı: $(kubectl -n "$NS" get deploy redirect -o jsonpath='{.spec.template.spec.topologySpreadConstraints[0].whenUnsatisfiable}')"
need_confirm "bir worker node DONDURULACAK (docker pause) — deney sonunda çözülür"
victim=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}')
on_cleanup "docker unpause $victim"
step "Node '$victim' donduruluyor — kubelet cevap veremeyecek"
( k6run redirect --vus 10 --duration 120s >/tmp/p0707.k6 2>&1 ) & kpid=$!
sleep 12
docker pause "$victim" >/dev/null
note "donduruldu. Kubernetes bunu ~40 sn sonra NotReady, ~5 dk sonra evict olarak görür."
for i in $(seq 1 20); do
  st=$(kubectl get node "$victim" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$st" != "True" ]] && { note "node NotReady oldu (~$((i*5)) sn)"; break; }
  sleep 5
done
sleep 20
docker unpause "$victim" >/dev/null
wait $kpid || true
e5=$(k6_5xx); reqs=$(k6_reqs)
grafana_hint "09 · Autoscaling → 'Pod dağılımı / node' · 02 · App RED → 5xx"
note "donma sırasında: $reqs istek, $e5 tanesi 5xx (hata oranı ~%$(awk -v a="$e5" -v b="$reqs" 'BEGIN{printf "%.1f", (b>0? a*100/b : 0)}'))"
note "Kritik ayrıntı: donmuş node'daki pod'lar Endpoints'te KALDI (kubelet cevap vermiyor ama"
note "API server pod'u hâlâ Ready sanıyor). Yani trafik ölü pod'lara gitmeye devam etti."
note "Kubernetes'in düğüm arızasını fark etmesi dakikalar sürer: node-monitor-grace-period (40 sn)"
note "+ pod eviction timeout (5 dk). Bu süre boyunca yedekliliğin İŞE YARAMAZ."
note "Araçlar: ingress/servis seviyesinde aktif sağlık kontrolü + hızlı devre kesme (10),"
note "topologySpread'i DoNotSchedule yapmak (ama kapasiteyi zorlar), PDB + çoklu node."
{ (( nodes < reps )) || (( e5 > 0 )); } \
  && reproduced "node donması $e5 isteği düşürdü (replikalar $nodes farklı node'da, $reps replika)"
not_reproduced "node donması etkisiz kaldı (replikalar iyi dağılmış ve trafik yönlendirilmiş)"
