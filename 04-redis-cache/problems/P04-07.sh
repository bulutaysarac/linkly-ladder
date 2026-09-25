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
step "Önbelleği gerçekçi bir boyuta getir (anahtar sayısı ne kadar çoksa kilit o kadar uzun)"
# Bu kümedeki trafik önbellekte birkaç bin anahtar tutar ve anahtarlar 60 sn'de (CACHE_TTL) dolar:
# o boyutta KEYS milisaniyenin altında biter ve ölçülecek bir şey kalmaz. KEYS'in bedelini gösteren,
# üretim önbelleğinin boyutudur. Redis'in içinde (Lua, tek komut) FILL kadar süresiz anahtar yazılır —
# 300 bin anahtar ~20 MB, 64 MB'lık sınırın altında — ve deney sonunda aynı yolla silinir.
FILL=${FILL:-300000}
redis_lua() { kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli EVAL "$1" 0 "$FILL" >/dev/null; }
unfill() { redis_lua "for i=1,tonumber(ARGV[1]) do redis.call('DEL','fill:'..i) end return 1"; }
on_cleanup unfill
redis_lua "for i=1,tonumber(ARGV[1]) do redis.call('SET','fill:'..i,'x') end return 1" \
  || { warn "Redis'e doldurma anahtarları yazılamadı"; exit 2; }
for i in $(seq 1 200); do c=$(create_link "https://example.com/k/$i"); [[ -n "$c" ]] && status_of "$c" >/dev/null || true; done
keys=$(kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli DBSIZE 2>/dev/null | tr -d '\r') || true
note "Redis'teki anahtar sayısı: ${keys:-?}"
# TABANSIZ BİR TEPE, TEPE DEĞİLDİR.
# EN: a verdict like `maxp99 > 0` is true for any request that ever completed. It would claim
#     "KEYS * spiked redirect latency" without ever measuring what the latency is WITHOUT the
#     KEYS calls, so it cannot fail and therefore cannot tell you anything. So the same
#     load runs twice: once clean, once with KEYS * in the middle, and the spike is the
#     DIFFERENCE. Each phase reads its own window (`[${dur}s:15s]`) so phase 2 cannot inherit
#     phase 1's peak.
# TR: `maxp99 > 0` gibi bir hüküm tamamlanan herhangi bir istek için doğrudur. "KEYS * gecikmeyi
#     tepe yaptırdı" der ama gecikmenin KEYS ÇAĞRISI OLMADAN ne olduğunu hiç ölçmez; yani
#     düşemez ve bu yüzden hiçbir şey söyleyemez. Bu yüzden aynı yük iki kez koşuyor: biri temiz,
#     biri ortasında KEYS * ile; tepe ikisinin FARKI. Her faz kendi penceresini okuyor
#     (`[${dur}s:15s]`), yani 2. faz 1. fazın tepesini devralamıyor.
PHASE_P99=""
phase_load() {   # $1 = "keys" ise yükün ortasında /debug/keys çağrılır
  local kpid t0 dur out i
  ( k6run redirect --vus 20 --duration 45s >/tmp/p0407.k6 2>&1 ) & kpid=$!
  t0=$(date +%s)
  sleep 15
  # Tek bir KEYS, 300 bin anahtarda onlarca milisaniye sürer: birkaç çağrı 30 sn'lik pencerenin küçük bir
  # kısmını bloklar ve p99'a yansımaz. Bir milyonlarca anahtarlık üretim önbelleğinde tek çağrı saniyeler
  # sürer; bu laboratuvarın 64 MB'lık Redis'i o boyuta çıkamaz. Aynı etkiyi — GET'lerin KEYS'in arkasında
  # sıraya girmesini — görünür kılan şey sıklıktır: uç 20 sn boyunca ARALIKSIZ çağrılır (bir izleme betiği
  # ya da "kaç anahtar var?" diye durmadan soran bir debug paneli gibi). Redis zamanın çoğunda KEYS'le meşgul
  # olur ve her GET o an çalışan KEYS bitene kadar bekler.
  # EN: one KEYS over 300k keys takes tens of ms; production-size caches (millions of keys) make it seconds,
  #     which this 64 MB lab Redis cannot hold. Frequency reproduces the same queueing: the endpoint is
  #     called back-to-back for 20 s, so Redis spends most of that time in KEYS and every GET waits.
  if [[ "${1:-}" == "keys" ]]; then
    local took=0 n=0 ms end=$((SECONDS + ${KEYS_SECS:-20}))
    while (( SECONDS < end )); do
      out=$(curl -s --max-time 30 "$BASE_URL/debug/keys") || true
      ms=$(echo "$out" | jq -r '.took_ms // 0' 2>/dev/null) || ms=0
      ms=${ms%.*}; [[ "$ms" =~ ^[0-9]+$ ]] || ms=0
      took=$((took + ms)); n=$((n + 1))
      (( n == 1 )) && note "  ilk KEYS çağrısı → $(echo "$out" | head -c 120)"
    done
    note "  ${KEYS_SECS:-20} sn'de $n KEYS çağrısı · Redis'in kilitli kaldığı toplam süre: ${took} ms (sürenin %$(( took / (${KEYS_SECS:-20} * 10) )) kadarı)"
  fi
  wait_pid_quiet "$kpid"
  sleep 20                       # son kazıma yükün tamamını kapsasın
  dur=$(( $(date +%s) - t0 ))
  PHASE_P99=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[30s])) by (le))[${dur}s:15s])")
}
step "(1) TABAN: aynı yük, KEYS çağrısı YOK"
phase_load; base_max=$PHASE_P99
note "taban tepe p99=$(awk -v v="$base_max" 'BEGIN{printf "%.0f", v*1000}') ms"
step "(2) Aynı yükün ortasında /debug/keys (KEYS *) 20 sn boyunca aralıksız çağrılıyor"
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
not_reproduced "ölçülebilir etki yok (taban $(awk -v v="$base_max" 'BEGIN{printf "%.0f", v*1000}') ms, KEYS ile $(awk -v v="$maxp99" 'BEGIN{printf "%.0f", v*1000}') ms) — FILL ile anahtar sayısını artır"
