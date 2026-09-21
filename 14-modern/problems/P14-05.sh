#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P14-05 · GAME DAY: merdivenin tüm korumaları aynı anda sınanıyor
# Tek tek her koruma çalışıyor. Peki HEP BİRLİKTE? Gerçek olaylar tek bir arıza değildir:
# bir bağımlılık yavaşlar, bir pod ölür, bir dağıtım yapılır ve hepsi aynı 10 dakikada olur.
# Bu script üç arızayı ÜST ÜSTE bindiriyor ve sistemin kısmen çalışır kalıp kalmadığını ölçüyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
need_confirm "game day: Redis gecikmesi + DB paket kaybı + pod öldürme ÜST ÜSTE uygulanacak"
on_cleanup "$LADDER_ROOT/platform/lib/chaos.sh delete redis-delay-200ms; $LADDER_ROOT/platform/lib/chaos.sh delete pg-loss-30"
step "Taban: her şey sağlıklıyken"
k6run mixed --vus 20 --duration 30s >/dev/null 2>&1 || true
sleep 10
base_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
note "taban p99=$(awk -v v="$base_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
step "GAME DAY başlıyor: üç arıza üst üste"
( k6run mixed --vus 25 --duration 150s >/tmp/p1405.k6 2>&1 ) & kpid=$!
sleep 15
note "  [00:15] Redis'e 200 ms gecikme"
chaos_apply redis-delay-200ms
sleep 30
note "  [00:45] Postgres'e %30 paket kaybı"
chaos_apply pg-loss-30
sleep 30
note "  [01:15] bir redirect pod'u öldürülüyor"
victim=$(kubectl -n "$NS" get pod -l "$APP_SELECTOR" -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" delete pod "$victim" --force --grace-period=0 >/dev/null 2>&1 || true
sleep 30
note "  [01:45] arızalar kaldırılıyor"
"$LADDER_ROOT/platform/lib/chaos.sh" delete redis-delay-200ms >/dev/null 2>&1 || true
"$LADDER_ROOT/platform/lib/chaos.sh" delete pg-loss-30 >/dev/null 2>&1 || true
wait $kpid || true
sleep 12
e5=$(k6_5xx); reqs=$(k6_reqs); e404=$(k6_404)
avail=$(awk -v a="$e5" -v b="$reqs" 'BEGIN{printf "%.2f", (b>0? (1-a/b)*100 : 0)}')
breaker=$(promq "max_over_time(max(breaker_state{namespace=\"$NS\"})[5m:15s])")
shed=$(promq "sum(increase(load_shed_total{namespace=\"$NS\"}[5m]))")
retries=$(promq "sum(increase(retry_total{namespace=\"$NS\"}[5m]))")
degraded=$(promq "max_over_time(max(degraded_mode{namespace=\"$NS\"})[5m:15s])")
budget=$(promq "slo:period_error_budget_remaining:ratio{sloth_slo=\"redirect-availability\"} or vector(1)")
grafana_hint "11 · Resilience (breaker/shed/retry) · 12 · SLO (bütçe) · 02 · App RED"
note "SONUÇ: $reqs istek · $e5 adet 5xx · erişilebilirlik %$avail"
note "korumalar: breaker tepe durum=${breaker%%.*} · yük atma=${shed%%.*} · retry=${retries%%.*} · degrade=${degraded%%.*}"
note "kalan hata bütçesi: $(awk -v v="$budget" 'BEGIN{printf "%.2f%%", v*100}')"
note "Beklenen davranış: sistem KISMEN bozulur, tamamen değil. Her koruma kendi işini yapar ve"
note "toplam etki, parçaların toplamından AZ olur — çünkü biri diğerinin yükünü emer."
note "Bu bir 'test' değil bir PROVA'dır: amacı geçmek değil, hangi korumanın ne zaman devreye"
note "girdiğini GÖRMEK ve runbook'u buna göre yazmak."
note "Tam tur için: tools/ladder-matrix/run.sh — tüm seviyelerin tüm scriptlerini bu seviyeye koşar."
awk -v a="$avail" 'BEGIN{exit !(a > 50)}' \
  && reproduced "üç eşzamanlı arıza altında sistem %$avail erişilebilir kaldı (breaker ${breaker%%.*}, shed ${shed%%.*}, retry ${retries%%.*}) — kısmi bozulma, tam çöküş değil"
not_reproduced "sistem game day'i geçemedi (erişilebilirlik %$avail) — hangi korumanın devreye girmediğini panellerden bul"
