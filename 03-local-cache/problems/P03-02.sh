#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-02 · Her rollout/scale-out = soğuk önbellek = DB'de testere dişi
# Önbellek pod'un belleğinde; pod ölünce önbellek de ölüyor. Her dağıtım, DB'ye bir yük dalgası.
ensure_healthy
step "Önbelleği ısıt: 300 link, her birine birkaç okuma"
codes=$(mktemp)
for i in $(seq 1 300); do create_link "https://example.com/warm/$i" >> "$codes"; done
for round in 1 2 3; do while read -r c; do [[ -n "$c" ]] && status_of "$c" >/dev/null; done < "$codes"; done
sleep 12
warm_db=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[1m]))")
hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",result=\"hit\"}[1m])) / sum(rate(cache_ops_total{namespace=\"$NS\"}[1m]))")
note "ısınmış durumda: DB get/s=$(awk -v v="$warm_db" 'BEGIN{printf "%.1f", v}') · hit oranı=$(awk -v v="$hit" 'BEGIN{printf "%.0f%%", v*100}')"
step "Sürekli okuma yükü altında rollout restart — önbellek sıfırlanacak"
( k6run redirect --vus 20 --duration 90s >/tmp/p0302.k6 2>&1 ) & kpid=$!
sleep 15
kubectl -n "$NS" rollout restart deploy/linkly >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null 2>&1 || true
wait $kpid || true
sleep 12
peak_db=$(promq "max_over_time(sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[30s]))[5m:15s])")
now_db=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[1m]))")
misses=$(promq "sum(increase(cache_ops_total{namespace=\"$NS\",result=\"miss\"}[5m]))")
rm -f "$codes"
grafana_hint "04 · Cache → 'cache miss vs DB qps' · 05 · Postgres → 'DB queries by op'"
note "rollout sırasında DB get/s TEPE: $(awk -v v="$peak_db" 'BEGIN{printf "%.0f", v}') · şimdi: $(awk -v v="$now_db" 'BEGIN{printf "%.0f", v}') · toplam miss: ${misses%%.*}"
note "Her yeni pod boş bellekle doğuyor: ilk istekler zorunlu olarak DB'ye iniyor."
note "Bu yüzden 'önbellek sayesinde DB'yi küçülttük' demek tehlikelidir — DB, SOĞUK anı kaldırabilmeli."
note "Çözüm 04: önbellek pod'un dışında (Redis); pod ölse de önbellek yaşar."
awk -v p="$peak_db" -v n="$now_db" 'BEGIN{exit !(p > n*1.5 && p > 5)}' \
  && reproduced "rollout DB okumasını $(awk -v v="$now_db" 'BEGIN{printf "%.0f", v}')/s'den tepe $(awk -v v="$peak_db" 'BEGIN{printf "%.0f", v}')/s'e çıkardı — soğuk önbellek testere dişi"
not_reproduced "rollout DB'de tepe yaratmadı — önbellek süreç dışında (04)"
