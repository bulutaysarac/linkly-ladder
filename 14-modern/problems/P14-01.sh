#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P14-01 · L1'in geri dönüşü: ağ adımını ödemeden isabet
# 04'te önbelleği paylaştık ve her isabette bir ağ adımı ödedik (P04-02). 14 L1'i geri getiriyor —
# ama 03'ün ödemediği borcu ödeyerek: her kopya bir geçersiz kılma kanalı borçlanır (P14-02).
# Bu script kazancı ölçüyor; bedeli bir sonraki script ölçüyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
need_metric redis_commands_processed_total "redis ServiceMonitor deploy/servicemonitor.yaml'da mı?"
on_cleanup "setenv \"$(wl redirect)\" L1_ENABLED=true"
# YEREL SARMALAYICI KENDİ ADINI KULLANAMAZ.
# EN: this line used to read `setenv() { setenv rollout/redirect "$@" ... }` — the inner call is
#     the function itself, so it recursed until the stack blew up (`Segmentation fault: 11`) and
#     the script hung instead of measuring. The bulk rename that introduced `setenv` rewrote both
#     the CALL SITE and this WRAPPER, and the wrapper's whole job was to call the thing it was
#     renamed to. Rename the wrapper, not the callee.
# TR: bu satır `setenv() { setenv rollout/redirect "$@" ... }` idi — içteki çağrı fonksiyonun
#     KENDİSİ, yani yığın taşana kadar özyineledi (`Segmentation fault: 11`) ve script ölçüm
#     yapmak yerine asıldı. `setenv`i getiren toplu değiştirme hem ÇAĞRI YERİNİ hem bu
#     SARMALAYICIYI değiştirdi; sarmalayıcının bütün işi ise yeni adı çağırmaktı.
#     Sarmalayıcıyı yeniden adlandır, çağrılanı değil.
redirect_env() { setenv "$(wl redirect)" "$@" >/dev/null; }
waitrollout() { kubectl -n "$NS" rollout status rollout/redirect --timeout=240s >/dev/null 2>&1 || kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=240s >/dev/null 2>&1 || true; }
measure() {
  waitrollout; for _ in $(seq 1 25); do serving && break; sleep 2; done
  HOT_SHARE=0.9 k6run hot-key --vus 40 --duration 40s >/dev/null 2>&1 || true
  sleep 12
  local p50 p99 redisops
  p50=$(num "$(promq "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")")
  p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")")
  redisops=$(promq "sum(rate(redis_commands_processed_total{namespace=\"$NS\"}[2m]))")
  echo "$p50 $p99 $redisops"
}
step "(1) Yalnızca L2 (04 davranışı)"
redirect_env L1_ENABLED=false
read -r p50a p99a opsa <<< "$(measure)"
note "L2-only: p50=$(awk -v v="$p50a" 'BEGIN{printf "%.2f", v*1000}') ms · p99=$(awk -v v="$p99a" 'BEGIN{printf "%.1f", v*1000}') ms · Redis ops/s=$(awk -v v="$opsa" 'BEGIN{printf "%.0f", v}')"
step "(2) L1+L2 (14 davranışı)"
redirect_env L1_ENABLED=true
read -r p50b p99b opsb <<< "$(measure)"
note "L1+L2:  p50=$(awk -v v="$p50b" 'BEGIN{printf "%.2f", v*1000}') ms · p99=$(awk -v v="$p99b" 'BEGIN{printf "%.1f", v*1000}') ms · Redis ops/s=$(awk -v v="$opsb" 'BEGIN{printf "%.0f", v}')"
l1hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l1\",result=\"hit\"}[2m])) / clamp_min(sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l1\"}[2m])),0.001)")
grafana_hint "04 · Cache → 'hit ratio by pod' (layer=l1 vs l2) · 06 · Redis → ops/s · 02 · App RED → p50"
note "L1 hit oranı: $(awk -v v="$l1hit" 'BEGIN{printf "%.0f%%", v*100}') · Redis yükü $(awk -v a="$opsa" -v b="$opsb" 'BEGIN{printf "%.0f%%", (a>0? (1-b/a)*100 : 0)}') azaldı"
note "Kazanç iki yönlü: sıcak anahtar için gecikme (ağ adımı yok) VE Redis'in yükü (P04-03'teki"
note "tek çekirdek tavanına daha geç ulaşılır)."
note "Bedeli bir sonraki script'te: L1 = gerçeğin N kopyası = geçersiz kılma sorunu (P14-02)."
# KARAR TUZAĞI: ">=" / "<=" iki taraf da 0 iken GEÇER.
# EN: "b >= a" is true when nothing was measured at all (0 >= 0). That turns a failed measurement
#     into a passing experiment — the loudest possible false positive, because it looks like proof.
#     Guard the comparison with "we actually measured something".
# TR: "b >= a", hiçbir şey ölçülmediğinde de doğrudur (0 >= 0). Yani başarısız bir ölçüm, GEÇEN
#     bir deneye dönüşür — mümkün olan en gürültülü yanlış pozitif, çünkü kanıt gibi görünür.
#     Karşılaştırmayı "gerçekten bir şey ölçtük mü?" koşuluyla koru.
awk -v a="$p50a" -v b="$p50b" 'BEGIN{exit !(a > 0 && b > 0 && b <= a)}' \
  && reproduced "L1 p50'yi $(awk -v v="$p50a" 'BEGIN{printf "%.2f", v*1000}') → $(awk -v v="$p50b" 'BEGIN{printf "%.2f", v*1000}') ms'e indirdi, Redis ops/s $(awk -v v="$opsa" 'BEGIN{printf "%.0f", v}') → $(awk -v v="$opsb" 'BEGIN{printf "%.0f", v}') (L1 hit %$(awk -v v="$l1hit" 'BEGIN{printf "%.0f", v*100}'))"
not_reproduced "L1 kazancı ölçülemedi (hot-key yükü ve L1_CAPACITY'yi kontrol et)"
