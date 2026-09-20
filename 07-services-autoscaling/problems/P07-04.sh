#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-04 · CPU limiti bir "en fazla" değil, bir KOTA'dır: throttling
# CPU limiti, 100 ms'lik dilimlerde kullanabileceğin çekirdek-zamanını sınırlar. Kotan dilim
# ortasında biterse, dilim bitene kadar BEKLERSİN — ortalama CPU %50 görünürken p99 fırlar.
# "CPU'muz boşta ama yavaşız" tablosunun en sık sebebi budur.
#
# ORTAM NOTU: bu kurulumdaki cAdvisor container_cpu_cfs_throttled_* metriğini YAYINLAMIYOR
# (kind + Docker Desktop, cgroup v1). Bu yüzden throttling'i doğrudan okuyamıyoruz; dolaylı
# kanıtla ölçüyoruz: aynı yük altında limitli ve limitsiz p99 farkı. Ölçemediğin şeyi
# ölçebildiğin bir şeyle kuşatmak, gözlemlenebilirliğin sık kullanılan bir tekniğidir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
has_throttle=$(curl -s "$PROM_URL/api/v1/label/__name__/values" | jq -r '.data[]' | grep -c 'container_cpu_cfs_throttled' || true)
note "throttling metriği mevcut mu: $([[ ${has_throttle:-0} -gt 0 ]] && echo evet || echo HAYIR — ortam sınırı)"
lim=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}')
req=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
on_cleanup "kubectl -n \"$NS\" set resources deploy/redirect --limits=cpu=$lim"
on_cleanup "kubectl -n \"$NS\" scale deploy/redirect --replicas=2"
step "Sıkı CPU limiti ($lim, istek $req) ile sabit yük"
kubectl -n "$NS" scale deploy/redirect --replicas=2 >/dev/null; wait_endpoints 2
k6run redirect --vus 40 --duration 45s >/dev/null 2>&1 || true
sleep 10
tight_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
tight_cpu=$(promq "sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\",image!=\"\",image!~\".*pause.*\"}[1m]))")
tight_thr=$(promq "sum(rate(container_cpu_cfs_throttled_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\"}[1m]))")
note "limitli: p99=$(awk -v v="$tight_p99" 'BEGIN{printf "%.0f", v*1000}') ms · CPU=$(awk -v v="$tight_cpu" 'BEGIN{printf "%.2f", v}') çekirdek · throttle=$(awk -v v="$tight_thr" 'BEGIN{printf "%.2f", v}') s/s"
step "CPU limitini KALDIR, aynı yük"
kubectl -n "$NS" set resources deploy/redirect --limits=cpu=0 >/dev/null 2>&1 || \
  kubectl -n "$NS" patch deploy redirect --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]' >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/redirect --timeout=180s >/dev/null 2>&1 || true
wait_endpoints 2; sleep 5
k6run redirect --vus 40 --duration 45s >/dev/null 2>&1 || true
sleep 10
free_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
free_cpu=$(promq "sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\",image!=\"\",image!~\".*pause.*\"}[1m]))")
grafana_hint "01 · Pods & Resources → 'CPU throttling (s/s)' (bu ortamda BOŞ) + 'CPU kullanımı' · 02 · App RED → p99"
note "limitsiz: p99=$(awk -v v="$free_p99" 'BEGIN{printf "%.0f", v*1000}') ms · CPU=$(awk -v v="$free_cpu" 'BEGIN{printf "%.2f", v}') çekirdek"
note "Limit kalkınca CPU kullanımı arttı ve p99 düştüyse, aradaki fark THROTTLING'dir."
note "Kural: CPU limiti koymadan önce 'bu servis dilim içinde ne kadar patlıyor?' sorusunu sor."
note "Bellek limiti şarttır (OOM koruması); CPU limiti çoğu zaman zarar verir — request yeterlidir."
note "Ortam sınırı: throttling metriği yoksa bu farkı p99 üzerinden okumak zorundasın (yukarıdaki not)."
awk -v t="$tight_p99" -v f="$free_p99" 'BEGIN{exit !(t > f)}' \
  && reproduced "CPU limiti p99'u $(awk -v v="$free_p99" 'BEGIN{printf "%.0f", v*1000}') → $(awk -v v="$tight_p99" 'BEGIN{printf "%.0f", v*1000}') ms yükseltti (CPU $(awk -v v="$free_cpu" 'BEGIN{printf "%.2f", v}') → $(awk -v v="$tight_cpu" 'BEGIN{printf "%.2f", v}') çekirdek) — kota etkisi"
not_reproduced "limitli/limitsiz p99 farkı ölçülemedi (yükü artırıp tekrar dene)"
