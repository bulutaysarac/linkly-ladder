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
step "Yük altında primary'yi öldür"
( k6run mixed --vus 15 --duration 120s >/tmp/p0902.k6 2>&1 ) & kpid=$!
sleep 15
t0=$(date +%s)
kubectl -n "$NS" delete pod "$primary" --wait=false >/dev/null
newp=""
for i in $(seq 1 60); do
  # BURADA dep_pod KULLANMA: failover sırasında primary rolü bir süre HİÇ YOK ve ölçmek
  # istediğimiz şey tam olarak o boşluk. Bekleyen bir yardımcı, ölçtüğün olayı yutar.
  newp=$(kubectl -n "$NS" get pods -l 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$newp" && "$newp" != "$primary" ]] && break
  sleep 2
done
t1=$(date +%s)
wait $kpid || true
e5=$(k6_5xx); reqs=$(k6_reqs)
grafana_hint "05 · Postgres → 'Bağlantılar ve üst sınır' + 'Replikasyon gecikmesi' · 02 · App RED → '5xx (uç noktaya göre)'"
note "yeni primary: ${newp:-?} · terfi süresi: ~$((t1-t0)) sn"
note "yük: $reqs istek, $e5 tanesi 5xx (~%$(awk -v a="$e5" -v b="$reqs" 'BEGIN{printf "%.1f", (b>0? a*100/b : 0)}'))"
note "02 ile fark: orada kesinti İNSAN müdahalesine kadar sürüyordu; burada ~$((t1-t0)) sn."
note "Ama sıfır değil ve olamaz: yeni primary'nin WAL'i uygulaması, rolün ilan edilmesi ve"
note "istemcilerin yeni adrese yönlenmesi gerekir."
note "Uygulama tarafında gereken: yazma hatalarında retry + İDEMPOTENCY. Retry idempotent değilse"
note "failover, çift kayıt üretir — 06'daki processed_events deseninin yazma yolundaki karşılığı."
note "SLO yazarken: 'failover var' cümlesi '%100 erişilebilirlik' anlamına GELMEZ (11)."
(( e5 > 0 )) \
  && reproduced "failover penceresinde $e5 istek düştü (~$((t1-t0)) sn), sonra sistem kendini toparladı — insan müdahalesi olmadan"
not_reproduced "failover kesintisiz geçti (yük yazma içermiyor olabilir — mixed senaryosunu kontrol et)"
