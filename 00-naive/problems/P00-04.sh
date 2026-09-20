#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-04 · Rollout sırasında hata dalgası (readiness + graceful shutdown yok)
#
# ÖLÇÜM NOTU: yükü TEK VU ile veriyoruz. Nedeni P00-01: paralel istek mutex'siz map'i çökertir ve
# hata oranı %99'a fırlar — o zaman "rollout mu çökme mi kaybettirdi?" ayırt edilemez. Tek VU'da
# eşzamanlı yazım yok, yani ölçtüğümüz tek şey rollout penceresi.
ensure_healthy
ensure_fresh_pod
pod=$(pod_name); before=$(restarts_of "$pod")
step "Tek akışlı sürekli redirect yükü (40 sn) — çökmeyi tetiklemeden"
( k6run redirect --vus 1 --duration 40s >/tmp/p0004.k6 2>&1 ) &
kpid=$!
sleep 14
step "rollout restart — eski pod trafikten çekilmeden ölüyor mu, yeni pod hazır olmadan trafik alıyor mu?"
kubectl -n "$NS" rollout restart deploy/linkly >/dev/null
wait $kpid || true
fr=$(k6_failed_rate); reqs=$(k6_reqs); e5=$(k6_5xx); e404=$(k6_404)
newpod=$(pod_name); crashed=$(restarts_of "$newpod")
grafana_hint "15 · k6 → 'failed rate' ; 01 · Pods & Resources → pod değişimi aynı anda"
note "k6: $reqs istek · 5xx=$e5 · 404=$e404 · toplam failed oranı=$fr  (detay: /tmp/p0004.k6)"
note "AYRIM: 5xx = rollout penceresi (bu sorun) · 404 = yeni pod'un belleği boş (P00-02, ayrı sorun)."
(( ${crashed:-0} > 0 )) && warn "bu tur sırasında süreç de çöktü (P00-01) — ölçüm karışmış olabilir, tekrar dene"
note "Sebep: readinessProbe yok → yeni pod hazır olmadan Endpoint'e girer; preStop/graceful shutdown yok → eski pod işlenmekte olan istekleri bırakır."
(( e5 > 0 )) && reproduced "rollout penceresinde $e5 istek 5xx aldı — kesintisiz dağıtım yok (ayrıca $e404 adet 404: P00-02)"
not_reproduced "rollout sırasında hiç 5xx olmadı — probe + graceful shutdown var (01). (404=$e404 hâlâ P00-02'nin işi)"
