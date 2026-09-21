#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-04 · Rollout sırasında hata dalgası (readiness probe + graceful shutdown yok)
#
# ÖLÇÜM NOTU 1: yük TEK VU ile verilir (~1700 rps yeterli). Paralel istek P00-01'i tetikler, hata
#   oranı %99'a fırlar ve "rollout mu çökme mi kaybettirdi?" ayırt edilemez.
# ÖLÇÜM NOTU 2: k6'nın tek `http_req_failed` oranı yanıltır. Rollout'tan SONRAKİ 404'ler P00-02'dir
#   (yeni pod'un belleği boş); rollout penceresinin kendisi 5xx üretir. Sadece 5xx'e bakıyoruz.
# ÖLÇÜM NOTU 3: tek rollout YARIŞA bağlıdır — bazen eski pod son isteğini bitirir, yeni pod anında
#   dinlemeye başlar ve pencere hiç yakalanmaz. Bu yüzden ROLLOUTS kez tekrarlıyoruz. Yarışı
#   "bazen olmuyor" diye yok saymak, üretimde "bazen oluyor" demektir.
ROLLOUTS=${ROLLOUTS:-3}
ensure_healthy
ensure_fresh_pod

step "Yapısal durum: pod'un trafik almaya hazır olduğunu kim söylüyor?"
probes=$(kubectl -n "$NS" get "$(app_workload)" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}') || true
prestop=$(kubectl -n "$NS" get "$(app_workload)" -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop}') || true
note "readinessProbe: ${probes:-YOK — konteyner başlar başlamaz Endpoint'e ekleniyor}"
note "preStop hook:   ${prestop:-YOK — pod, ingress'in listesinden düşmeden ölmeye başlıyor}"

step "Tek akışlı sürekli redirect yükü (${ROLLOUTS} rollout boyunca)"
dur=$(( 15 + ROLLOUTS * 15 ))
( k6run redirect --vus 1 --duration "${dur}s" >/tmp/p0004.k6 2>&1 ) &
kpid=$!
sleep 12
for i in $(seq 1 "$ROLLOUTS"); do
  step "rollout restart #$i/$ROLLOUTS"
  kubectl -n "$NS" rollout restart "$(app_workload)" >/dev/null
  kubectl -n "$NS" rollout status "$(app_workload)" --timeout=60s >/dev/null 2>&1 || true
  sleep 5
done
wait $kpid || true

fr=$(k6_failed_rate); reqs=$(k6_reqs); e5=$(k6_5xx); e404=$(k6_404)
newpod=$(pod_name); crashed=$(restarts_of "$newpod")
grafana_hint "15 · k6 → 'failed rate' ; 01 · Pods & Resources → pod değişimi aynı anda"
note "k6: $reqs istek · 5xx=$e5 · 404=$e404 · toplam failed oranı=$fr  (detay: /tmp/p0004.k6)"
note "AYRIM: 5xx = rollout penceresi (bu sorun) · 404 = yeni pod'un belleği boş (P00-02, ayrı sorun)"
(( ${crashed:-0} > 0 )) && warn "bu tur sırasında süreç de çöktü (P00-01) — ölçüm karışmış olabilir"
(( e5 > 0 )) && reproduced "$ROLLOUTS rollout'ta $e5 istek 5xx aldı — kesintisiz dağıtım yok (ayrıca $e404 adet 404: P00-02)"
warn "Bu turda 5xx yakalanmadı — yarışı kazandın. Yapısal boşluk (probe yok, preStop yok) duruyor:"
warn "ROLLOUTS=6 make repro P=P00-04 ile tekrar dene, ya da 'kubectl delete pod --force' ile sert öldür."
not_reproduced "rollout penceresinde 5xx görülmedi (404=$e404 hâlâ P00-02'nin işi)"
