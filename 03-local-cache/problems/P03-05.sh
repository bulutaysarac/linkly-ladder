#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-05 · TRAP_NO_SINGLEFLIGHT: TTL dolan sıcak anahtarda izdiham (cache stampede)
# Sıcak bir anahtarın TTL'i dolduğu anda, o anda uçuşta olan TÜM istekler aynı satır için
# veritabanına gider. Önbellek "çalışıyor" görünür (hit oranı yüksek), ama DB düzenli darbe alır.
#
# ÖLÇÜM NOTU — izdihamın büyüklüğü şudur:  (istek hızı) × (önbelleği DOLDURMA süresi)
# Bu kümede Postgres 1 ms'de cevap veriyor; delik o kadar dar ki korumasız halde bile içeri
# yalnızca 1-2 istek sızıyor ve ölçüm "sorun yok" diyor. Gerçekte doldurma maliyeti 10-500 ms'dir
# (uzak DB, JOIN, soğuk sayfa). Bu yüzden deliği gerçekçi genişliğe getiriyoruz: Postgres'e 200 ms.
# Ders: singleflight'ın değeri DB hızıyla TERS orantılıdır — DB yavaşladıkça hayat kurtarır.
SHORT_TTL=${SHORT_TTL:-5s}
VUS=${VUS:-60}
ensure_healthy
on_cleanup "setenv "$(app_workload)" TRAP_NO_SINGLEFLIGHT- CACHE_TTL-"
step "Doldurma maliyetini gerçekçi yap: Postgres'e 200 ms gecikme (Chaos Mesh)"
chaos_apply pg-delay-200ms
sleep 5
gets() { promq "sum(db_queries_total{namespace=\"$NS\",op=\"get\"})"; }
run_hot() {
  local g0 g1
  kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null || true
  for _ in $(seq 1 30); do serving && break; sleep 2; done
  # Üstte bir rollout var (TRAP env'i): ölen pod'un serisi toplamdan düşene kadar g0 şişkin
  # okunur ve "yük boyunca DB get sorgusu" olduğundan küçük çıkar. İki faz aynı bozulmayı
  # yaşamadığı için karşılaştırma da bozulur. (bkz. repro.sh → settle_scrape)
  settle_scrape
  g0=$(gets)
  # SEED küçük + HOT_SHARE yüksek: soğuk anahtarların ıskaları sinyali boğmasın.
  SEED=20 HOT_SHARE=0.99 k6run hot-key --vus "$VUS" --duration 60s >/dev/null 2>&1 || true
  sleep 20
  g1=$(gets)
  awk -v a="${g0:-0}" -v b="${g1:-0}" 'BEGIN{d=b-a; if (d<0) d=0; printf "%.0f", d}'
}
step "Koruma AÇIK (varsayılan), TTL $SHORT_TTL — sıcak anahtar sürekli dolup duruyor"
setenv "$(app_workload)" CACHE_TTL="$SHORT_TTL" TRAP_NO_SINGLEFLIGHT- >/dev/null
guarded=$(run_hot)
sf=$(promq "sum(increase(cache_stampede_wait_total{namespace=\"$NS\"}[5m]))")
note "korumalı:   yük boyunca DB get sorgusu = $guarded · singleflight'ta bekleyen çağrı = ${sf%%.*}"
note "cache_stampede_wait_total'ın YÜKSEK olması iyi haberdir: o kadar çağrı DB'ye gitmek yerine bekledi."
step "Korumayı KAPAT (TRAP_NO_SINGLEFLIGHT), aynı yük"
setenv "$(app_workload)" TRAP_NO_SINGLEFLIGHT=true >/dev/null
unguarded=$(run_hot)
note "korumasız: yük boyunca DB get sorgusu = $unguarded"
grafana_hint "04 · Cache → 'stampede wait/s' · 'cache miss vs DB qps' · 05 · Postgres → 'DB CPU'"
note "Hit oranı iki durumda da yüksek görünür — farkı yalnızca DB'ye inen sorgu sayısı gösterir."
note "TTL $SHORT_TTL boyunca korumalı hâlde pod başına anahtar başına 1 sorgu düşer; korumasız hâlde"
note "delik (200 ms) süresince gelen HER istek DB'ye iner."
awk -v g="${guarded:-0}" -v u="${unguarded:-0}" 'BEGIN{exit !(u > g*2 && u - g > 100)}' \
  && reproduced "korumasız DB get sorgusu $guarded → $unguarded'e çıktı — izdiham"
not_reproduced "koruma kapalıyken de fark oluşmadı (VUS artır ya da doldurma süresini büyüt)"
