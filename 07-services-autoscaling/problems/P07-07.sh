#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-07 · Tüm replikalar aynı node'a düşerse yedeklilik kâğıt üstünde kalır
# topologySpreadConstraints `ScheduleAnyway` ile YUMUŞAK bir tercihtir: scheduler yer bulamazsa
# kuralı çiğner ve hepsini aynı node'a koyar. Node donduğunda "3 replikam var" demen işe yaramaz.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Replikalar hangi node'larda?"
kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName --no-headers | sed 's/^/    /'
nodes=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c .) || true
reps=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{.status.readyReplicas}') || true
note "replika=$reps · farklı node=$nodes · dağılım kuralı: $(kubectl -n "$NS" get deploy redirect -o jsonpath='{.spec.template.spec.topologySpreadConstraints[0].whenUnsatisfiable}')"
need_confirm "bir worker node DONDURULACAK (docker pause) — deney sonunda çözülür"
victim=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}') || true
# Temizlik yalnızca `docker unpause` DEĞİL: dondurulmuş bir node'da containerd'nin PLEG'i
# ölüyor ve kubelet "container runtime is down" diyerek NotReady kalıyor — gerçekte oldu,
# node 49 dakika NotReady kaldı ve kümenin geri kalanı (Chaos Mesh, Argo, KEDA) o node'a
# düşen pod'larla birlikte çürüdü. Sonraki HER deney bozuk bir ortamı ölçtü.
# Bir deney, kümeyi bulduğu gibi bırakmak zorundadır — "geri aldım" demek yetmez, DOĞRULA.
on_cleanup "for i in \$(seq 1 30); do [ \"\$(kubectl get node $victim -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)\" = True ] && break; sleep 5; done"
on_cleanup "docker exec $victim systemctl restart containerd >/dev/null 2>&1 || true"
on_cleanup "docker unpause $victim"
# ÖNCE TABAN: donma sırasındaki sayıyı neyle kıyaslayacağız? İlk koşuda 120 saniyede yalnızca
# 13 istek tamamlandı ve 5xx=0 çıktı — script "etkisiz kaldı" dedi. Oysa asıl kanıt tam da oydu:
# istekler ölü pod'lara yönlendirilip ASILI KALDI, yani 5xx üretmeden ÜRETKENLİK çöktü.
# Bir arızanın işareti her zaman hata kodu değildir; bazen sadece "iş bitmiyor"dur.
step "Taban: donma öncesi tamamlanan istek hızı"
with_timeout 90 k6run redirect --vus 10 --duration 30s >/dev/null 2>&1 || true
base_reqs=$(k6_reqs); base_rps=$(awk -v r="$base_reqs" 'BEGIN{printf "%.1f", r/30}')
note "taban: $base_reqs istek / 30 sn = $base_rps istek/s"
step "Node '$victim' donduruluyor — kubelet cevap veremeyecek"
# Yükü zaman sınırıyla koş: donmuş bir node'da istekler asılı kalabiliyor ve k6'nın kendisi
# de takılabiliyor. 43 dakikalık bir takılma yaşandı; bir deney adımı SINIRLI sürmeli.
( with_timeout 200 k6run redirect --vus 10 --duration 120s >/tmp/p0707.k6 2>&1 ) & kpid=$!
sleep 12
docker pause "$victim" >/dev/null
note "donduruldu. Kubernetes bunu ~40 sn sonra NotReady, ~5 dk sonra evict olarak görür."
for i in $(seq 1 20); do
  st=$(kubectl get node "$victim" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || true
  [[ "$st" != "True" ]] && { note "node NotReady oldu (~$((i*5)) sn)"; break; }
  sleep 5
done
sleep 20
docker unpause "$victim" >/dev/null
wait $kpid 2>/dev/null || true
e5=$(k6_5xx); reqs=$(k6_reqs)
grafana_hint "09 · Autoscaling → 'Pod dağılımı / node' · 02 · App RED → 5xx"
froz_rps=$(awk -v r="$reqs" 'BEGIN{printf "%.1f", r/120}')
note "donma sırasında: $reqs istek / 120 sn = $froz_rps istek/s (tabanın %$(awk -v a="$froz_rps" -v b="$base_rps" 'BEGIN{printf "%.0f", (b>0? a*100/b : 0)}')'i) · 5xx=$e5"
note "Kritik ayrıntı: donmuş node'daki pod'lar Endpoints'te KALDI (kubelet cevap vermiyor ama"
note "API server pod'u hâlâ Ready sanıyor). Yani trafik ölü pod'lara gitmeye devam etti."
note "Kubernetes'in düğüm arızasını fark etmesi dakikalar sürer: node-monitor-grace-period (40 sn)"
note "+ pod eviction timeout (5 dk). Bu süre boyunca yedekliliğin İŞE YARAMAZ."
note "Araçlar: ingress/servis seviyesinde aktif sağlık kontrolü + hızlı devre kesme (10),"
note "topologySpread'i DoNotSchedule yapmak (ama kapasiteyi zorlar), PDB + çoklu node."
{ awk -v f="$froz_rps" -v b="$base_rps" 'BEGIN{exit !(b > 0 && f < b*0.5)}' || (( e5 > 0 )); } \
  && reproduced "node donunca üretkenlik $base_rps → $froz_rps istek/s'e düştü ($e5 adet 5xx) — trafik ölü pod'lara gitmeye devam etti"
not_reproduced "node donması ölçülebilir etki yaratmadı ($base_rps → $froz_rps istek/s, $e5 adet 5xx)"
