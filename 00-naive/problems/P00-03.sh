#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-03 · replicas>1 → istekler rastgele pod'a → ~%66 404
ensure_healthy
step "3 replikaya çık, 1 link oluştur, 30 kez oku"
need_confirm "replica sayısı değişecek"
orig=$(replicas_of)
scale 3
wait_endpoints 3
code=$(create_link "https://example.com/sharding")
note "kod $code yalnızca TEK bir pod'un belleğinde"
miss=0; tot=60
for i in $(seq 1 $tot); do [[ "$(status_of "$code")" == 404 ]] && miss=$((miss+1)); done
grafana_hint "03 · App Business → 'redirect 404 by pod'"
note "$tot okumadan $miss tanesi 404 (linkin olmadığı pod'lara düştü)"
note "eski replika sayısına dönmek için: kubectl -n $NS scale deploy/linkly --replicas=$orig"
(( miss > 0 )) && reproduced "%$(( miss * 100 / tot )) 404 — store pod'lar arasında paylaşılmıyor"
not_reproduced "hiç 404 yok — store paylaşımlı (02)"
