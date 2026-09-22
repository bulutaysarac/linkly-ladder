#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-07 · TRAP_DEBUG_KEYS: KEYS * tek komutla tüm Redis'i kilitler
# Redis TEK İŞ PARÇACIKLIDIR: bir komut çalışırken diğerleri SIRADA BEKLER. KEYS O(N)'dir.
# Bir milyon anahtarda "sadece debug için" eklenmiş bir uç, tüm redirect'leri saniyelerce durdurur.
ensure_healthy
on_cleanup "setenv "$(app_workload)" TRAP_DEBUG_KEYS-"
rpod=$(dep_pod app.kubernetes.io/name=redis) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
step "Tuzağı aç: /debug/keys ucu (KEYS * çalıştırır)"
setenv "$(app_workload)" TRAP_DEBUG_KEYS=true >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
step "Önbelleği doldur (anahtar sayısı ne kadar çoksa kilit o kadar uzun)"
for i in $(seq 1 ${N:-4000}); do c=$(create_link "https://example.com/k/$i"); [[ -n "$c" ]] && status_of "$c" >/dev/null || true; done
keys=$(kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli DBSIZE 2>/dev/null | tr -d '\r') || true
note "Redis'teki anahtar sayısı: ${keys:-?}"
step "Sürekli redirect yükü altında /debug/keys çağır"
( k6run redirect --vus 20 --duration 45s >/tmp/p0407.k6 2>&1 ) & kpid=$!
sleep 15
for i in 1 2 3; do
  out=$(curl -s --max-time 30 "$BASE_URL/debug/keys")
  note "  KEYS çağrısı $i → $(echo "$out" | head -c 120)"
done
wait $kpid || true
p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")")
maxp99=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[30s])) by (le))[3m:15s])")
grafana_hint "06 · Redis → 'commands by type' (KEYS görünürse alarm) + 'App → Redis latency p99'"
note "redirect p99=$(awk -v v="$p99" 'BEGIN{printf "%.0f", v*1000}') ms · pencere içi TEPE p99=$(awk -v v="$maxp99" 'BEGIN{printf "%.0f", v*1000}') ms"
note "KEYS'in süresi anahtar sayısıyla doğru orantılı: ${keys:-?} anahtarda milisaniyeler,"
note "1 milyonda saniyeler. Ve o süre boyunca Redis BAŞKA HİÇBİR ŞEY yapmaz."
note "Güvenli karşılığı: SCAN (imleç tabanlı, çağrı başına sınırlı iş) ya da kendi tuttuğun sayaç."
note "Aynı tuzağın akrabaları: FLUSHALL, büyük bir hash'te HGETALL, sınırsız SMEMBERS, DEBUG SLEEP."
awk -v v="$maxp99" 'BEGIN{exit !(v > 0)}' \
  && reproduced "KEYS * çalışırken redirect gecikmesi tepe yaptı (tepe p99 $(awk -v v="$maxp99" 'BEGIN{printf "%.0f", v*1000}') ms, ${keys:-?} anahtar)"
not_reproduced "ölçülebilir etki yok (anahtar sayısını N ile artırıp tekrar dene)"
