#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-03 · Yeni pod "hazır" ama SOĞUK: ilk istekleri yavaş
# readiness "süreç ayakta ve dinliyor" der; "önbelleğim ısındı, havuzum açık, JIT'im yerleşti"
# demez. HPA ölçeklerken tam da yükün en yüksek olduğu anda soğuk pod'lar trafiğe girer.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Isınmış durumda taban p99"
k6run redirect --vus 20 --duration 40s >/dev/null 2>&1 || true
sleep 10
warm=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")")
note "ısınmış p99=$(awk -v v="$warm" 'BEGIN{printf "%.1f", v*1000}') ms"
step "Yük altında yeni pod'lar ekle (soğuk pod trafiğe girsin)"
( k6run redirect --vus 30 --duration 70s >/tmp/p0703.k6 2>&1 ) & kpid=$!
sleep 12
kubectl -n "$NS" scale "$(wl redirect)" --replicas=6 >/dev/null
on_cleanup "kubectl -n \"$NS\" scale "$(wl redirect)" --replicas=2"
sleep 25
# Yeni (genç) pod'ların p99'unu ayrı ölç
young=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[30s])) by (le, pod))")")
wait $kpid || true
sleep 8
peak=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[30s])) by (le))[3m:15s])")
step "Pod yaşına göre p99 (en genç pod'lar en yavaş olmalı)"
curl -sG "$PROM_URL/api/v1/query" --data-urlencode \
  "query=topk(6, histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le, pod)))" \
  | jq -r '.data.result[] | "    \(.metric.pod): \((.value[1]|tonumber*1000)|floor) ms"' 2>/dev/null | head -8
grafana_hint "09 · Autoscaling → 'Pod yaşı vs p99' · 04 · Cache → 'hit ratio by pod'"
note "ısınmış p99=$(awk -v v="$warm" 'BEGIN{printf "%.1f", v*1000}') ms · ölçekleme sonrası TEPE p99=$(awk -v v="$peak" 'BEGIN{printf "%.1f", v*1000}') ms"
note "Soğuk pod'un maliyeti bu seviyede küçük çünkü önbellek PAYLAŞIMLI (04) — L2 zaten sıcak."
note "03'te (pod içi önbellek) aynı deney çok daha sert olurdu: her yeni pod boş bellekle doğuyordu."
note "Kalan soğukluk: DB bağlantı havuzu (MinConns), Go heap/JIT ve ingress'in upstream keşfi."
note "Araçlar: startupProbe ile 'hazır' tanımını sıkılaştır, MinConns ile havuzu önden aç,"
note "preStop+readiness ile trafiği kademeli al (slow start — ingress-nginx'te annotasyon)."
# SIFIR BİR TABAN HER ŞEYİ ARTIŞ GİBİ GÖSTERİR.
# EN: `warm` comes from a Prometheus query; when that query fails `promq` returns 0 — and then
#     "p > w" is true for ANY peak, so a broken measurement reports REPRODUCED and looks like
#     proof of a cold-start effect. It happened: the query failed, warm printed as 0.0 ms and the
#     verdict passed on a number that was never measured. A baseline of zero is not a baseline.
# TR: `warm` bir Prometheus sorgusundan gelir; sorgu başarısız olduğunda `promq` 0 döndürür ve
#     "p > w" HERHANGİ bir tepe için doğru olur — yani bozuk bir ölçüm REPRODUCED basar ve soğuk
#     başlangıç kanıtı gibi görünür. Gerçekte oldu: sorgu patladı, ısınmış p99 "0.0 ms" yazıldı
#     ve hüküm hiç ölçülmemiş bir sayının üstüne kuruldu. Sıfır bir taban, taban değildir.
awk -v w="$warm" -v p="$peak" 'BEGIN{exit !(w > 0 && p > w)}' \
  && reproduced "ölçekleme anında p99 $(awk -v v="$warm" 'BEGIN{printf "%.1f", v*1000}') → $(awk -v v="$peak" 'BEGIN{printf "%.1f", v*1000}') ms'e çıktı — soğuk pod'lar trafiğe girdi"
not_reproduced "soğuk başlangıç etkisi ölçülemedi (paylaşılan önbellek sayesinde küçük olabilir)"
