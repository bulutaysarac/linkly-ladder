#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-06 · TRAP_NO_NEGATIVE_CACHE: "yok" cevabı önbelleklenmezse tarama doğrudan DB'ye iner
# Var olmayan kodlara yapılan her istek — ister kötü niyetli tarama, ister ölü linkler, ister
# yanlış yazılmış bir URL — önbelleği tamamen atlar. Önbellek yalnızca VAR OLANI korur;
# YOK OLAN, korumasız bir tüneldir.
ensure_healthy
on_cleanup "setenv "$(app_workload)" TRAP_NO_NEGATIVE_CACHE-"
run_scan() {
  kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null || true
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  # SINIRLI HAVUZ ŞART. Sınırsız rastgele kodla aynı eksik anahtar hiç tekrarlanmaz; negatif
  # önbellekte tutulacak bir cevap olmaz ve deney iddiasını SINAYAMAZ. Sınırsız havuzla ölçülen:
  # açıkken DB get/s=3639 · negatif isabet=0, kapalıyken 1696 — sonuç iddianın tersi çıkar, çünkü
  # ölçülen şey negatif önbellek değil, iki koşunun gürültüsüdür.
  # EN: with an unbounded key space a missing key never repeats, so the negative cache has
  # nothing to serve and the experiment cannot test its claim — it measures run-to-run noise.
  KEYS=${SCAN_KEYS:-60} CODE_LEN=7 k6run scan --vus 30 --duration 60s >/dev/null 2>&1 || true
  sleep 18
  promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[1m]))"
}
step "Negatif önbellek AÇIK (varsayılan): rastgele kod taraması"
setenv "$(app_workload)" TRAP_NO_NEGATIVE_CACHE- >/dev/null
with=$(run_scan)
neg=$(promq "sum(increase(cache_ops_total{namespace=\"$NS\",result=\"negative_hit\"}[5m]))")
note "açıkken: DB get/s=$(awk -v v="$with" 'BEGIN{printf "%.0f", v}') · negatif isabet=${neg%%.*}"
step "Negatif önbellek KAPALI, aynı tarama"
setenv "$(app_workload)" TRAP_NO_NEGATIVE_CACHE=true >/dev/null
without=$(run_scan)
note "kapalıyken: DB get/s=$(awk -v v="$without" 'BEGIN{printf "%.0f", v}')"
grafana_hint "04 · Cache → 'ops by result & layer' (negative_hit) · 05 · Postgres → 'DB queries by op'"
note "Not: negatif önbelleğin TTL'i kısa olmalı — yeni oluşturulan bir link, eski 'yok' cevabının"
note "arkasında kalmasın. Bu seviyede CACHE_NEGATIVE_TTL=10s (pozitif TTL'in altıda biri)."
note "Tarama ayrıca bir hız sınırı sorunudur: 08'de 404 oranına göre limit uygulanacak."
# MEKANİZMANIN ÇALIŞTIĞINI DA İSTE: negatif isabet 0 ise karşılaştırılan iki sayı da negatif
# önbellek hakkında değildir; o zaman "fark yok" demek değil, "ölçemedik" demek gerekir.
if awk -v n="${neg%%.*}" 'BEGIN{exit !(n+0==0)}'; then
  warn "ölçüm yapılamadı: negatif isabet 0 — negatif önbellek hiç devreye girmedi."
  warn "Havuz yeterince küçük mü (SCAN_KEYS=${SCAN_KEYS:-60}) ve CACHE_NEGATIVE_TTL yükten uzun mu?"
  exit 2
fi
awk -v a="$with" -v b="$without" 'BEGIN{exit !(a > 0 && b > a*1.5)}' \
  && reproduced "negatif önbellek kapalıyken tarama DB'yi $(awk -v v="$with" 'BEGIN{printf "%.0f", v}')/s → $(awk -v v="$without" 'BEGIN{printf "%.0f", v}')/s dövüyor (negatif isabet ${neg%%.*})"
not_reproduced "fark ölçülmedi (açık $(awk -v v="$with" 'BEGIN{printf "%.0f", v}')/s · kapalı $(awk -v v="$without" 'BEGIN{printf "%.0f", v}')/s · negatif isabet ${neg%%.*}) — SCAN_KEYS'i küçült ya da TTL'i uzat"
