#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-03 · Tek replika + PDB = güvenlik yanılsaması. Node drain'de kesinti kaçınılmaz.
ensure_healthy
node=$(kubectl -n "$NS" get pod -l "$APP_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}')
step "PDB ne vaat ediyor, gerçekte ne oluyor?"
kubectl -n "$NS" get pdb linkly -o jsonpath='  minAvailable={.spec.minAvailable} · şu an izin verilen kesinti={.status.disruptionsAllowed}{"\n"}'
note "pod şu node'da: $node"
need_confirm "node cordon+drain edilecek (deney sonunda uncordon edilir)"
( k6run redirect --vus 1 --duration 70s >/tmp/p0103.k6 2>&1 ) & kpid=$!
sleep 10
step "Node drain — PDB 'en az 1 pod' diyor ama taşınacak ikinci pod yok"
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=45s 2>&1 | tail -3 | sed 's/^/    /'
sleep 20
kubectl uncordon "$node" >/dev/null
wait $kpid || true
e5=$(k6_5xx); e404=$(k6_404)
grafana_hint "02 · App RED → 5xx ; 01 · Pods & Resources → 'Pod fazları' (Pending)"
note "drain sırasında: 5xx=$e5 · 404=$e404"
note "PDB gönüllü kesintiyi ENGELLER ama kesintisizliği SAĞLAYAMAZ: tek replikada drain ya bloke olur ya kesinti yaratır."
(( e5 > 0 )) && reproduced "node drain'de $e5 istek 5xx aldı — tek replikada PDB yanılsamadan ibaret"
not_reproduced "drain sırasında 5xx görülmedi (bu turda drain bloke olmuş olabilir — çıktıyı oku)"
