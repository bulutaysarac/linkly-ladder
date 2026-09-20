#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-02 · (devralınan P00-03) ölçeklenemez — ama ARTIK POD BAZINDA GÖRÜNÜR
ensure_healthy
need_confirm "replica sayısı geçici olarak 3'e çıkacak"
orig=$(replicas_of)
on_cleanup "kubectl -n \"$NS\" scale deploy -l \"$APP_SELECTOR\" --replicas=$orig"
scale 3; wait_endpoints 3
code=$(create_link "https://example.com/sharded")
miss=0; tot=60
for i in $(seq 1 $tot); do [[ "$(status_of "$code")" == 404 ]] && miss=$((miss+1)); done
sleep 12
step "Aynı gerçeği metrikten oku: hangi pod kaç tane not_found saydı?"
curl -sG "$PROM_URL/api/v1/query" --data-urlencode \
  "query=sum by (pod) (redirect_total{namespace=\"$NS\",result=\"not_found\"})" \
  | jq -r '.data.result[] | "    \(.metric.pod): \(.value[1]) not_found"'
grafana_hint "03 · App Business → 'redirect 404 by pod' (00'da bu panel BOŞTU)"
note "$tot okumadan $miss tanesi 404 (~%$(( miss * 100 / tot )))"
note "01'in kazancı: sorunun pod dağılımını görüyorsun. Sorun aynı: her pod kendi map'i."
scale "$orig" >/dev/null 2>&1 || true
(( miss > 0 )) && reproduced "%$(( miss * 100 / tot )) 404 — store pod'lar arasında paylaşılmıyor"
not_reproduced "hiç 404 yok — paylaşılan store (02)"
