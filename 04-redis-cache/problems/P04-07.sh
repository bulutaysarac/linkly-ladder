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
# TABANSIZ BİR TEPE, TEPE DEĞİLDİR.
# EN: the verdict used to be `maxp99 > 0` — true for any request that ever completed. It claimed
#     "KEYS * spiked redirect latency" while never measuring what the latency was WITHOUT the
#     KEYS calls, so it could not fail and therefore could not tell you anything. Now the same
#     load runs twice: once clean, once with KEYS * in the middle, and the spike is the
#     DIFFERENCE. Each phase reads its own window (`[${dur}s:15s]`) so phase 2 cannot inherit
#     phase 1's peak.
# TR: hüküm `maxp99 > 0` idi — tamamlanan herhangi bir istek için doğru. "KEYS * gecikmeyi tepe
#     yaptırdı" diyordu ama gecikmenin KEYS ÇAĞRISI OLMADAN ne olduğunu hiç ölçmüyordu; yani
#     düşemezdi ve bu yüzden hiçbir şey söyleyemezdi. Artık aynı yük iki kez koşuyor: biri temiz,
#     biri ortasında KEYS * ile; tepe ikisinin FARKI. Her faz kendi penceresini okuyor
#     (`[${dur}s:15s]`), yani 2. faz 1. fazın tepesini devralamıyor.
PHASE_P99=""
phase_load() {   # $1 = "keys" ise yükün ortasında /debug/keys çağrılır
  local kpid t0 dur out i
  ( k6run redirect --vus 20 --duration 45s >/tmp/p0407.k6 2>&1 ) & kpid=$!
  t0=$(date +%s)
  sleep 15
  if [[ "${1:-}" == "keys" ]]; then
    for i in 1 2 3; do
      out=$(curl -s --max-time 30 "$BASE_URL/debug/keys") || true
      note "  KEYS çağrısı $i → $(echo "$out" | head -c 120)"
    done
  fi
  wait_pid_quiet "$kpid"
  sleep 20                       # son kazıma yükün tamamını kapsasın
  dur=$(( $(date +%s) - t0 ))
  PHASE_P99=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[30s])) by (le))[${dur}s:15s])")
}
step "(1) TABAN: aynı yük, KEYS çağrısı YOK"
phase_load; base_max=$PHASE_P99
note "taban tepe p99=$(awk -v v="$base_max" 'BEGIN{printf "%.0f", v*1000}') ms"
step "(2) Aynı yükün ortasında /debug/keys (KEYS *) çağır"
phase_load keys; maxp99=$PHASE_P99
p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
grafana_hint "06 · Redis → 'commands by type' (KEYS görünürse alarm) + 'App → Redis latency p99'"
note "KEYS fazı: p99=$(awk -v v="$p99" 'BEGIN{printf "%.0f", v*1000}') ms · pencere içi TEPE p99=$(awk -v v="$maxp99" 'BEGIN{printf "%.0f", v*1000}') ms (taban tepe $(awk -v v="$base_max" 'BEGIN{printf "%.0f", v*1000}') ms)"
note "KEYS'in süresi anahtar sayısıyla doğru orantılı: ${keys:-?} anahtarda milisaniyeler,"
note "1 milyonda saniyeler. Ve o süre boyunca Redis BAŞKA HİÇBİR ŞEY yapmaz."
note "Güvenli karşılığı: SCAN (imleç tabanlı, çağrı başına sınırlı iş) ya da kendi tuttuğun sayaç."
note "Aynı tuzağın akrabaları: FLUSHALL, büyük bir hash'te HGETALL, sınırsız SMEMBERS, DEBUG SLEEP."
awk -v b="$base_max" -v v="$maxp99" 'BEGIN{exit !(b > 0 && v > b * 1.5)}' \
  && reproduced "KEYS * tepe p99'u $(awk -v v="$base_max" 'BEGIN{printf "%.0f", v*1000}') → $(awk -v v="$maxp99" 'BEGIN{printf "%.0f", v*1000}') ms yaptı (${keys:-?} anahtar) — tek iş parçacıklı Redis sırayı durdurdu"
not_reproduced "ölçülebilir etki yok (taban $(awk -v v="$base_max" 'BEGIN{printf "%.0f", v*1000}') ms, KEYS ile $(awk -v v="$maxp99" 'BEGIN{printf "%.0f", v*1000}') ms) — N ile anahtar sayısını artır"
