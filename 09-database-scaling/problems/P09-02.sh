#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P09-02 · Failover penceresi: otomatik devretme ANLIK DEĞİLDİR
# 02'de primary ölünce kesinti kalıcıydı (P02-03). Şimdi operatör bir replikayı terfi ettiriyor —
# ama bu 10-30 saniye sürer ve o sürede YAZMA yapılamaz. HA, kesintiyi sıfırlamaz; SÜRESİNİ
# ve İNSAN MÜDAHALESİNİ ortadan kaldırır. Bu fark, SLO yazarken bilmen gereken şeydir.
ensure_healthy
step "Mevcut topoloji"
kubectl -n "$NS" get pods -l cnpg.io/cluster=pg -L cnpg.io/instanceRole --no-headers 2>/dev/null | sed 's/^/    /'
primary=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
note "primary: ${primary:-bulunamadı}"
[[ -z "$primary" ]] && { warn "CNPG primary bulunamadı"; exit 2; }
need_confirm "primary pod silinecek (failover tetiklenecek)"
uid0=$(kubectl -n "$NS" get pod "$primary" -o jsonpath='{.metadata.uid}' 2>/dev/null) || true
step "Yük altında primary'yi ÇÖKERT (zorla sil: kapanış yok, devir yok)"
( k6run mixed --vus 15 --duration 120s >/tmp/p0902.k6 2>&1 ) & kpid=$!
sleep 15
t0=$(date +%s)
# ÇÖKME, KAPANIŞ DEĞİL. Düzgün silinen (graceful) bir primary'yi CNPG kapanırken replikaya devreder ve
# PgBouncer sorguları bekletir: istemci hiçbir şey görmez. Sorunun anlattığı pencere bir ÇÖKMEDE açılır —
# operatör arızayı fark etmeli, replikayı terfi ettirmeli, istemciler yeni adrese yönlenmeli.
# EN: a graceful delete is handed over by CNPG during shutdown and PgBouncer hides it; the failover
#     window this problem is about opens on a CRASH, so the pod is killed without a grace period.
kubectl -n "$NS" delete pod "$primary" --force --grace-period=0 >/dev/null 2>&1 || true
# PENCERE = yazma yeniden mümkün olana kadar: primary rolünde, HAZIR ve silinenden farklı bir pod
# (terfi eden replika ya da aynı adla yeniden kalkan yeni pod — UID'i farklıdır). Kümenin tamamen
# iyileşmesi (silinen pod'un replika olarak geri kurulması) dakikalar sürer ve yazma kesintisinin
# parçası değildir; deneyin sonunda ayrıca beklenir.
# EN: the window closes when a Ready pod other than the killed one holds the primary role; full
#     cluster recovery (re-seeding the old primary as a replica) takes minutes and is awaited separately.
newp=""
for i in $(seq 1 120); do
  newp=$(kubectl -n "$NS" get pods -l 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary' -o json 2>/dev/null \
    | jq -r --arg u "$uid0" '[.items[] | select(.metadata.uid != $u) | select(.metadata.deletionTimestamp == null)
              | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name][0] // empty' 2>/dev/null) || true
  [[ -n "$newp" ]] && break
  sleep 1
done
t1=$(date +%s)
wait $kpid || true
e5=$(k6_5xx); reqs=$(k6_reqs)
sleep 12
wp99=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/api/links\"}[30s])) by (le))[$(( $(date +%s) - t0 + 30 ))s:15s])")
wp99_ms=$(awk -v v="$wp99" 'BEGIN{printf "%.0f", v * 1000}')
grafana_hint "05 · Postgres → 'Bağlantılar ve üst sınır' + 'Replikasyon gecikmesi' · 02 · App RED → '5xx (uç noktaya göre)'"
note "primary: $primary → ${newp:-?} ($([[ "$newp" == "$primary" ]] && echo 'aynı adla yeni pod kalktı' || echo 'replika terfi etti')) · yazma yeniden mümkün olana kadar: ~$((t1-t0)) sn"
note "yük: $reqs istek, $e5 tanesi 5xx (~%$(awk -v a="$e5" -v b="$reqs" 'BEGIN{printf "%.1f", (b>0? a*100/b : 0)}')) · yazma yolu (POST /api/links) en kötü p99: ${wp99_ms} ms"
note "02 ile fark: orada kesinti İNSAN müdahalesine kadar sürüyordu; burada ~$((t1-t0)) sn."
note "Ama sıfır değil ve olamaz: yeni primary'nin WAL'i uygulaması, rolün ilan edilmesi ve"
note "istemcilerin yeni adrese yönlenmesi gerekir."
note "Uygulama tarafında gereken: yazma hatalarında retry + İDEMPOTENCY. Retry idempotent değilse"
note "failover, çift kayıt üretir — 06'daki processed_events deseninin yazma yolundaki karşılığı."
note "SLO yazarken: 'failover var' cümlesi '%100 erişilebilirlik' anlamına GELMEZ (11)."
[[ -n "$newp" ]] || { warn "2 dk içinde primary rolünde hazır bir pod olmadı — pencere ölçülemedi"; exit 2; }
# Ortamı bulduğun gibi bırak: silinen pod replika olarak geri kurulana kadar bekle (en çok 6 dk).
phase=""
for _ in $(seq 1 72); do
  phase=$(kubectl -n "$NS" get cluster.postgresql.cnpg.io pg -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$phase" == "Cluster in healthy state" ]] && break
  sleep 5
done
[[ "$phase" == "Cluster in healthy state" ]] || warn "küme 6 dk içinde tamamen iyileşmedi (son durum: ${phase:-?}) — sonraki deneyden önce bekle"

{ (( e5 > 0 )) || (( wp99_ms >= 1000 )); } \
  && reproduced "failover penceresi ~$((t1-t0)) sn: $e5 istek düştü, yazmalar p99 ${wp99_ms} ms bekledi — sonra sistem insan müdahalesi olmadan toparlandı"
not_reproduced "failover penceresi görünmedi: 5xx=$e5, yazma p99 ${wp99_ms} ms (<1 sn)"
