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
# EN: `setenv() { setenv rollout/redirect "$@" ... }` would call ITSELF, recurse until the stack
#     blows up (`Segmentation fault: 11`) and hang the script instead of measuring. A wrapper
#     whose whole job is to call a function must not take that function's name: rename the
#     wrapper, not the callee.
# TR: `setenv() { setenv rollout/redirect "$@" ... }` KENDİNİ çağırır, yığın taşana kadar
#     özyineler (`Segmentation fault: 11`) ve script ölçüm yapmak yerine asılır. Bütün işi bir
#     fonksiyonu çağırmak olan sarmalayıcı o fonksiyonun adını alamaz: sarmalayıcıyı yeniden
#     adlandır, çağrılanı değil.
redirect_env() { setenv "$(wl redirect)" "$@" >/dev/null; }
# ROLLOUT'UN GERÇEKTEN BİTMESİNİ BEKLE — `make wait` ile aynı ölçüt: Healthy VE stableRS == currentPodHash.
# EN: `kubectl rollout status` does not know Argo Rollouts; a helper that swallows its error with
#     `|| true` returns at once. An env change on a Rollout is a CANARY (analysis steps, ~4 min),
#     so the "L2-only" phase would be measured on the OLD pods with L1 still on: a handful of L2
#     ops/s for a hot-key load of hundreds of reads/s — every read still served by L1. Wait until the
#     controller has seen the new spec (observedGeneration), then until the new revision is stable.
#     An aborted canary (Degraded) means the old pods are serving: that is "could not measure".
# TR: `kubectl rollout status` Argo Rollout'u tanımaz; hatayı `|| true` ile yutan bir yardımcı HEMEN
#     döner. Rollout'ta ortam değişikliği bir CANARY'dir (analiz adımları, ~4 dk); "L2-only" fazı
#     ESKİ pod'larda, L1 hâlâ açıkken ölçülürdü: yüzlerce okuma/s'lik sıcak anahtar yükünde birkaç
#     L2 erişim/s — okumaların hepsi hâlâ L1'den gelir. Önce denetleyicinin yeni spec'i gördüğünü
#     (observedGeneration), sonra yeni sürümün stable olduğunu bekle. İptal edilen canary (Degraded)
#     eski pod'ların hizmet verdiği demektir: bu "ölçemedik"tir.
rollout_field() { kubectl -n "$NS" get "$(wl redirect)" -o jsonpath="{$1}" 2>/dev/null || true; }
wait_rollout_done() {
  local gen ph st cu i
  [[ "$(wl redirect)" == rollout/* ]] || { settle_rollout "$(wl redirect)"; return 0; }
  gen=$(rollout_field .metadata.generation)
  for i in $(seq 1 30); do [[ "$(rollout_field .status.observedGeneration)" == "$gen" ]] && break; sleep 2; done
  for i in $(seq 1 240); do
    ph=$(rollout_field .status.phase); st=$(rollout_field .status.stableRS); cu=$(rollout_field .status.currentPodHash)
    if [[ "$ph" == Healthy && -n "$st" && "$st" == "$cu" ]]; then
      for _ in $(seq 1 25); do serving && break; sleep 2; done
      return 0
    fi
    if [[ "$ph" == Degraded ]]; then
      warn "canary İPTAL edildi: $(rollout_field .status.message | head -c 160) — pod'lar ESKİ sürümde, ölçüm anlamsız"
      exit 2
    fi
    [[ $i == 1 ]] && note "  canary adımları sürüyor ($ph) — yeni sürüm stable olana kadar bekleniyor (analiz ~4 dk)"
    sleep 2
  done
  warn "rollout 8 dk içinde Healthy olmadı ($ph) — ölçüm anlamsız"
  exit 2
}
# measure bir `$( )` içinde koşar: bekleme (ve onun exit 2'si) DIŞARIDA, çağırmadan önce yapılır.
measure() {
  HOT_SHARE=0.9 k6run hot-key --vus 40 --duration 40s >/dev/null 2>&1 || true
  sleep 12
  local p50 p99 redisops l1ops
  p50=$(promq "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
  p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
  # HAM REDIS KOMUT SAYACI BU İDDİA İÇİN KİRLİDİR.
  # `redis_commands_processed_total` Redis'e giden HER komutu sayar — L1 açıldığında devreye giren
  # PUB/SUB geçersiz kılma trafiği dahil. Ölçüldü: L2-only 767 ops/s, L1+L2 **1560** ops/s; yani
  # "L1 Redis yükünü azaltır" iddiası, L1'in EKLEDİĞİ kanal yüzünden ters göründü. İddia okuma
  # yolundaki L2 erişimleri hakkında, o hâlde ölçü de L2 önbellek işlemleri olmalı.
  # EN: the raw counter counts every command sent to Redis, including the pub/sub invalidation
  # traffic that only exists when L1 is on (767 → 1560 ops/s). The claim is about L2 lookups on
  # the read path, so the measure must be L2 cache operations, not all Redis commands.
  redisops=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\"}[2m]))")
  l1ops=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l1\"}[2m]))")
  echo "$p50 $p99 $redisops $l1ops"
}
step "(1) Yalnızca L2 (04 davranışı)"
redirect_env L1_ENABLED=false
wait_rollout_done
read -r p50a p99a opsa l1a <<< "$(measure)"
note "L2-only: p50=$(awk -v v="$p50a" 'BEGIN{printf "%.2f", v*1000}') ms · p99=$(awk -v v="$p99a" 'BEGIN{printf "%.1f", v*1000}') ms · L2 erişim/s=$(awk -v v="$opsa" 'BEGIN{printf "%.0f", v}') · L1 işlem/s=$(awk -v v="$l1a" 'BEGIN{printf "%.0f", v}')"
# L1 GERÇEKTEN KAPALI MIYDI? Kapalıysa L1 işlemi yoktur ve okumaların tamamı L2'ye gider.
# EN: was L1 really off? If it was, there are no L1 ops and every read reaches L2.
if awk -v a="$l1a" -v o="$opsa" 'BEGIN{exit !(a >= 1 || o < 1)}'; then
  warn "ölçüm yapılamadı: L2-only fazında L1 işlem/s=$(awk -v v="$l1a" 'BEGIN{printf "%.0f", v}'), L2 erişim/s=$(awk -v v="$opsa" 'BEGIN{printf "%.0f", v}')"
  warn "L1_ENABLED=false yeni pod'lara ulaşmamış ya da yük koşmamış (kubectl -n $NS get rollout redirect)"
  exit 2
fi
step "(2) L1+L2 (14 davranışı)"
redirect_env L1_ENABLED=true
wait_rollout_done
read -r p50b p99b opsb l1b <<< "$(measure)"
note "L1+L2:  p50=$(awk -v v="$p50b" 'BEGIN{printf "%.2f", v*1000}') ms · p99=$(awk -v v="$p99b" 'BEGIN{printf "%.1f", v*1000}') ms · L2 erişim/s=$(awk -v v="$opsb" 'BEGIN{printf "%.0f", v}')"
l1hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l1\",result=\"hit\"}[2m])) / clamp_min(sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l1\"}[2m])),0.001)")
grafana_hint "04 · Cache → 'Önbellek işlemleri (katman ve sonuca göre)' (l1 vs l2) · 02 · App RED → 'Gecikme (p50 / p95 / p99)' · 06 · Redis → 'Komut / sn'"
note "L1 hit oranı: $(awk -v v="$l1hit" 'BEGIN{printf "%.0f%%", v*100}') · okuma yolundaki L2 erişimi $(awk -v a="$opsa" -v b="$opsb" 'BEGIN{printf "%.0f%%", (a>0? (1-b/a)*100 : 0)}') azaldı"
note "Kazanç: sıcak anahtar okuması ağa ÇIKMIYOR — L2'ye (Redis) giden okuma, L1 isabeti kadar azalır."
note "Redis'in TOPLAM komut hızı ise düşmeyebilir, artabilir de (ör. 767 → 1560/s): L1 açıkken"
note "gelen pub/sub geçersiz kılma trafiği de Redis komutu sayılır. İddia okuma yolu hakkında; ölçü de o."
note "Bedeli bir sonraki script'te: L1 = gerçeğin N kopyası = geçersiz kılma sorunu (P14-02)."
# HÜKÜM MEKANİZMAYA BAĞLI, GECİKMEYE DEĞİL.
# EN: the verdict does not require `p50 b <= a`. p50 comes from histogram BUCKETS: both phases
#     usually land in the same bucket, and a difference below the measurement resolution cannot carry
#     a verdict either way. The claim is "hot reads stop making a network hop"; its evidence is the L1
#     hit ratio (with phase 1 proven L1-free above). Latency is reported, not judged.
# TR: hüküm `p50 b <= a` istemez. p50 histogram KOVALARINDAN gelir: iki faz çoğu zaman
#     aynı kovaya düşer ve ölçüm çözünürlüğünün altındaki bir fark iki yönde de hükmü taşıyamaz.
#     İddia "sıcak okuma ağ adımı yapmıyor"; kanıtı L1 isabet oranı (1. fazın L1'siz olduğu yukarıda
#     doğrulandı). Gecikme raporlanır, hükme girmez.
awk -v h="$l1hit" -v b="$opsb" -v a="$opsa" 'BEGIN{exit !(h > 0.5 && b < a)}' \
  && reproduced "L1 okumaların %$(awk -v v="$l1hit" 'BEGIN{printf "%.0f", v*100}')'ini karşıladı (ağ adımı yok): okuma yolundaki L2 erişimi $(awk -v v="$opsa" 'BEGIN{printf "%.0f", v}')/s → $(awk -v v="$opsb" 'BEGIN{printf "%.0f", v}')/s; p50 $(awk -v v="$p50a" 'BEGIN{printf "%.2f", v*1000}') → $(awk -v v="$p50b" 'BEGIN{printf "%.2f", v*1000}') ms (bilgi — hükme girmez)"
not_reproduced "L1 kazancı ölçülemedi: isabet oranı %$(awk -v v="$l1hit" 'BEGIN{printf "%.0f", v*100}'), L2 erişimi $(awk -v v="$opsa" 'BEGIN{printf "%.0f", v}')/s → $(awk -v v="$opsb" 'BEGIN{printf "%.0f", v}')/s — hot-key yükü, L1_ENABLED ve L1_CAPACITY"
