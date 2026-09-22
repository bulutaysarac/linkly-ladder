#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-04 · Devre kesici: açılma, yarı açık deneme ve flapping riski
# Devre kesicinin işi bağımlılığı kurtarmak değil; ONA VE SANA nefes aldırmaktır. Eşikler yanlışsa
# iki yönde de zarar verir: çok hassas → sağlıklı bağımlılığı "bozuk" ilan eder (yanlış pozitif),
# çok tembel → arızayı fark etmez. Ayrıca yarı açık pencerede flapping (aç-kapa-aç) olabilir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_NO_BREAKER-"
step "Postgres'e %50 paket kaybı (ağır arıza)"
chaos_apply pg-loss-50
sleep 5
# İKİ HATA BİRDEN YAPILIYORDU.
# (1) `dependency_requests_total` devre AÇIKKEN hızlıca reddedilen çağrıları da sayar
#     (result="open"). Yani "bağımlılığa giden çağrı" diye raporlanan sayı, bağımlılığa GİTMEYEN
#     çağrıları da içeriyordu: breaker açıkken 1663 göründü, oysa gerçekten giden 165'ti.
# (2) İki fazın da penceresi [3m] idi; fazlar ~1 dakika arayla koştuğu için ikinci fazın
#     ölçümü birinci fazın trafiğini de içeriyordu.
# Üstüne, iki fazın ÜRETTİĞİ İSTEK SAYISI çok farklı: breaker açıkken istekler hızlı reddedilir
# ve k6 çok daha fazla istek basar. Mutlak sayılar karşılaştırılamaz; oran karşılaştırılır:
# "her 100 istekten kaçı bozuk bağımlılığa ULAŞTI?"
# EN: two bugs at once — the counter includes fast-rejected calls (result="open"), so the number
# reported as "calls to the dependency" counted calls that never reached it (1663 vs the real
# 165); and both phases queried a [3m] window while running ~1 minute apart, so phase 2 measured
# phase 1's traffic too. On top of that the two phases push very different request volumes, so
# absolute counts are not comparable — the ratio is: of every 100 requests, how many REACHED the
# broken dependency?
PH_REACH=0; PH_OPEN=0; PH_REQS=0; PH_P99=0
run_phase() {
  local t0 dur all open
  t0=$(date +%s)
  k6run mixed --vus 25 --duration 50s >/dev/null 2>&1 || true
  sleep 20                        # son kazıma yükün tamamını kapsasın
  dur=$(( $(date +%s) - t0 ))
  all=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"postgres\"}[${dur}s]))")
  open=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"postgres\",result=\"open\"}[${dur}s]))")
  PH_OPEN=${open%%.*}
  PH_REACH=$(awk -v a="$all" -v o="$open" 'BEGIN{d=a-o; printf "%d", (d<0?0:d)}')
  PH_REQS=$(promq "sum(increase(http_requests_total{namespace=\"$NS\"}[${dur}s]))")
  PH_REQS=${PH_REQS%%.*}
  PH_P99=$(num "$(promq "max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[30s])) by (le))[${dur}s:15s])")")
}
step "(1) Devre kesici AÇIK (varsayılan)"
run_phase
reach_on=$PH_REACH; open_rej=$PH_OPEN; reqs_on=$PH_REQS; p99_on=$PH_P99
state_max=$(promq "max_over_time(max(breaker_state{namespace=\"$NS\",dep=\"postgres\"})[4m:15s])")
note "breaker açık: bağımlılığa ULAŞAN çağrı=$reach_on (devre-açık reddi=$open_rej) · istek=$reqs_on · tepe durum=${state_max%%.*} (2=açık) · p99=$(awk -v v="$p99_on" 'BEGIN{printf "%.0f", v*1000}') ms"
step "(2) TRAP_NO_BREAKER: devre kesici yok, her istek bozuk bağımlılığa gidiyor"
setenv "$(wl redirect)" TRAP_NO_BREAKER=true >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
run_phase
reach_off=$PH_REACH; reqs_off=$PH_REQS; p99_off=$PH_P99
grafana_hint "11 · Resilience → 'breaker state by dep' + 'dependency errors/s' · 02 · App RED → p99"
note "breaker yok: bağımlılığa ULAŞAN çağrı=$reach_off · istek=$reqs_off · p99=$(awk -v v="$p99_off" 'BEGIN{printf "%.0f", v*1000}') ms"
note "Oran: breaker açıkken her 100 istekten $(awk -v r="$reach_on" -v q="$reqs_on" 'BEGIN{printf "%.1f", (q>0? r*100/q : 0)}') tanesi bozuk bağımlılığa ulaştı; breaker yokken $(awk -v r="$reach_off" -v q="$reqs_off" 'BEGIN{printf "%.1f", (q>0? r*100/q : 0)}') tanesi."
note "Devre açıkken istek, bağımlılığa GİTMEDEN hızlıca reddedilir (ya da degrade moda düşer):"
note "hem bağımlılık nefes alır hem client hızlı cevap alır. Yavaş hata, hızlı hatadan KÖTÜDÜR."
note "Ayar riski: OpenDuration çok kısa + HalfOpenProbes çok az → flapping. Grafana'da 'breaker state'"
note "paneli testere dişi görünüyorsa eşikler yanlış demektir. Bu deneyde tepe durum ${state_max%%.*} idi."
note "Kritik ayrıntı (kodda): ErrNotFound devre kesiciyi TETİKLEMEZ. 404'ler hata değildir; bunu"
note "ayırt etmemek, çok sayıda 404'ün sağlıklı bir bağımlılığı 'bozuk' ilan etmesine yol açar."
awk -v ra="$reach_on" -v qa="$reqs_on" -v rb="$reach_off" -v qb="$reqs_off" -v pa="$p99_on" -v pb="$p99_off" \
  'BEGIN{exit !(qa > 0 && qb > 0 && (ra/qa) < (rb/qb) && pa < pb)}' \
  && reproduced "devre kesici bozuk bağımlılığa ulaşan istek oranını %$(awk -v r="$reach_off" -v q="$reqs_off" 'BEGIN{printf "%.0f", (q>0? r*100/q : 0)}') → %$(awk -v r="$reach_on" -v q="$reqs_on" 'BEGIN{printf "%.0f", (q>0? r*100/q : 0)}') düşürdü ve p99 $(awk -v v="$p99_off" 'BEGIN{printf "%.0f", v*1000}') → $(awk -v v="$p99_on" 'BEGIN{printf "%.0f", v*1000}') ms oldu (açık-devre reddi $open_rej, tepe durum ${state_max%%.*})"
not_reproduced "devre kesici etkisi ölçülemedi (ulaşan/istek: $reach_on/$reqs_on vs $reach_off/$reqs_off · p99 $(awk -v v="$p99_on" 'BEGIN{printf "%.0f", v*1000}')/$(awk -v v="$p99_off" 'BEGIN{printf "%.0f", v*1000}') ms) — arıza yeterince ağır mı?"
