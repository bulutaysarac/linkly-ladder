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
lim=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}') || true
req=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}') || true
on_cleanup "kubectl -n \"$NS\" set resources deploy/redirect --limits=cpu=$lim"
on_cleanup "kubectl -n \"$NS\" scale deploy/redirect --replicas=2"
# ÖLÇÜM NOTU: throttling ancak kotaya ÇARPARSAN görünür. İlk hâl 2 replika × 300m limit ile
# 40 VU koşuyordu; uygulama toplam 0.13 çekirdek kullandı, yani kotanın yakınına bile gitmedi
# ve "throttle=0.00" çıktı. Karar da p99 farkına bakıyordu — iki ayrı 45 sn'lik koşunun p99'u
# bu kümede zaten oynuyor, yani ölçüm gürültüyü okuyordu.
# Doğrusu: TEK pod + dar kota + kotayı aşacak yük. Ölçü de p99 değil, throttling'in kendisi.
TIGHT=${TIGHT:-50m}   # ÖLÇÜLDÜ: 200m kotada bile kısıtlama 0 çıktı; uygulama o kadar CPU istemiyor
on_cleanup "kubectl -n \"$NS\" set resources deploy/redirect --requests=cpu=${req:-150m}"
step "TEK pod, dar kota ($TIGHT) ve kotayı aşacak yük"
kubectl -n "$NS" scale deploy/redirect --replicas=1 >/dev/null; wait_endpoints 1
kubectl -n "$NS" set resources deploy/redirect --requests=cpu=100m --limits=cpu=$TIGHT >/dev/null
kubectl -n "$NS" rollout status deploy/redirect --timeout=180s >/dev/null 2>&1 || true
wait_endpoints 1; sleep 5
k6run redirect --vus 120 --duration 60s >/dev/null 2>&1 || true
sleep 15
tight_p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")")
tight_cpu=$(promq "sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\",image!=\"\",image!~\".*pause.*\"}[1m]))")
tight_thr=$(promq "sum(rate(container_cpu_cfs_throttled_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\"}[1m]))")
note "limitli: p99=$(awk -v v="$tight_p99" 'BEGIN{printf "%.0f", v*1000}') ms · CPU=$(awk -v v="$tight_cpu" 'BEGIN{printf "%.2f", v}') çekirdek · throttle=$(awk -v v="$tight_thr" 'BEGIN{printf "%.2f", v}') s/s"
tight_thr_total=$(promq "sum(increase(container_cpu_cfs_throttled_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\"}[2m]))")
step "Kotayı pratikte KALDIR (4 çekirdek), AYNI yük — tek pod"
# `--limits=cpu=0` geçerli görünüp bozuk bir spec üretebiliyor (pod'lar hazır olmuyor, iki
# ReplicaSet takılı kalıyor — gerçekte oldu). Niyet "kota beni sınırlamasın"; bunu geçerli bir
# değerle ifade et: node'un verebileceğinden büyük bir limit, pratikte limitsizdir.
kubectl -n "$NS" set resources deploy/redirect --requests=cpu=100m --limits=cpu=4 >/dev/null 2>&1 || \
  kubectl -n "$NS" patch deploy redirect --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]' >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/redirect --timeout=180s >/dev/null 2>&1 || true
wait_endpoints 1; sleep 5
k6run redirect --vus 120 --duration 60s >/dev/null 2>&1 || true
sleep 15
free_p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")")
free_cpu=$(promq "sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\",image!=\"\",image!~\".*pause.*\"}[1m]))")
grafana_hint "01 · Pods & Resources → 'CPU throttling (s/s)' (bu ortamda BOŞ) + 'CPU kullanımı' · 02 · App RED → p99"
note "limitsiz: p99=$(awk -v v="$free_p99" 'BEGIN{printf "%.0f", v*1000}') ms · CPU=$(awk -v v="$free_cpu" 'BEGIN{printf "%.2f", v}') çekirdek"
note "Limit kalkınca CPU kullanımı arttı ve p99 düştüyse, aradaki fark THROTTLING'dir."
note "Kural: CPU limiti koymadan önce 'bu servis dilim içinde ne kadar patlıyor?' sorusunu sor."
note "Bellek limiti şarttır (OOM koruması); CPU limiti çoğu zaman zarar verir — request yeterlidir."
note "Ortam sınırı: throttling metriği yoksa bu farkı p99 üzerinden okumak zorundasın (yukarıdaki not)."
free_thr_total=$(promq "sum(increase(container_cpu_cfs_throttled_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\"}[2m]))")
note "kısılan süre: kotalı $(awk -v v="$tight_thr_total" 'BEGIN{printf "%.1f", v}') sn · kotasız $(awk -v v="$free_thr_total" 'BEGIN{printf "%.1f", v}') sn (2 dk pencerede)"
note "Ölçü p99 değil THROTTLING'in kendisi: p99 iki koşu arasında zaten oynar, kısılan süre oynamaz."
awk -v tt="$tight_thr_total" -v ft="$free_thr_total" 'BEGIN{exit !(tt > 1 && tt > ft*2)}' \
  && reproduced "dar kota $(awk -v v="$tight_thr_total" 'BEGIN{printf "%.1f", v}') sn CPU kısıtlaması üretti (kotasız $(awk -v v="$free_thr_total" 'BEGIN{printf "%.1f", v}') sn); p99 $(awk -v v="$free_p99" 'BEGIN{printf "%.0f", v*1000}') → $(awk -v v="$tight_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
not_reproduced "kısıtlama ölçülemedi (kotalı $(awk -v v="$tight_thr_total" 'BEGIN{printf "%.1f", v}') sn) — TIGHT'ı daraltıp VUS'u artır"
