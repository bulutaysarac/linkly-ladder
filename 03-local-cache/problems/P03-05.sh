#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-05 · TRAP_NO_SINGLEFLIGHT: TTL dolan sıcak anahtarda izdiham (cache stampede)
# Sıcak bir anahtarın TTL'i dolduğu anda, o anda uçuşta olan TÜM istekler aynı satır için
# veritabanına gider. Önbellek "çalışıyor" görünür (hit oranı yüksek), ama DB saniyede bir
# dikey darbe alır. Yük ne kadar yüksekse darbe o kadar büyür — koruma tam da en gerektiği anda yok.
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_NO_SINGLEFLIGHT- CACHE_TTL-"
SHORT_TTL=${SHORT_TTL:-5s}
run_hot() {
  kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  HOT_SHARE=0.95 k6run hot-key --vus 80 --duration 45s >/dev/null 2>&1 || true
  sleep 12
  promq "max_over_time(sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[15s]))[3m:15s])"
}
step "Koruma AÇIK (varsayılan), TTL $SHORT_TTL — sıcak anahtar sürekli dolup duruyor"
kubectl -n "$NS" set env deploy/linkly CACHE_TTL="$SHORT_TTL" TRAP_NO_SINGLEFLIGHT- >/dev/null
guarded=$(run_hot)
sf=$(promq "sum(increase(cache_stampede_wait_total{namespace=\"$NS\"}[5m]))")
note "korumalı: DB get/s TEPE=$(awk -v v="$guarded" 'BEGIN{printf "%.0f", v}') · singleflight bekleyen çağrı=${sf%%.*}"
note "cache_stampede_wait_total'ın YÜKSEK olması iyi haberdir: o kadar çağrı DB'ye gitmek yerine bekledi."
step "Korumayı KAPAT (TRAP_NO_SINGLEFLIGHT), aynı yük"
kubectl -n "$NS" set env deploy/linkly TRAP_NO_SINGLEFLIGHT=true >/dev/null
unguarded=$(run_hot)
note "korumasız: DB get/s TEPE=$(awk -v v="$unguarded" 'BEGIN{printf "%.0f", v}')"
grafana_hint "04 · Cache → 'stampede wait/s' · 'cache miss vs DB qps' · 05 · Postgres → 'DB CPU'"
note "Hit oranı iki durumda da yüksek görünür — farkı yalnızca DB'deki TEPE ve stampede sayacı gösterir."
awk -v g="$guarded" -v u="$unguarded" 'BEGIN{exit !(u > g*1.5 && u > 5)}' \
  && reproduced "koruma kapalıyken DB tepesi $(awk -v v="$guarded" 'BEGIN{printf "%.0f", v}')/s → $(awk -v v="$unguarded" 'BEGIN{printf "%.0f", v}')/s'e çıktı — izdiham"
not_reproduced "koruma kapalıyken de tepe oluşmadı (yük yetersiz olabilir: VUS artırıp tekrar dene)"
