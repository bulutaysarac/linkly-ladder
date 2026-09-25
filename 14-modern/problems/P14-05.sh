#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P14-05 · GAME DAY: merdivenin tüm korumaları aynı anda sınanıyor
# Tek tek her koruma çalışıyor. Peki HEP BİRLİKTE? Gerçek olaylar tek bir arıza değildir:
# bir bağımlılık yavaşlar, bir pod ölür, bir dağıtım yapılır ve hepsi aynı 10 dakikada olur.
# Bu script üç arızayı ÜST ÜSTE bindiriyor ve sistemin kısmen çalışır kalıp kalmadığını ölçüyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
need_confirm "game day: Redis gecikmesi + DB paket kaybı + pod öldürme ÜST ÜSTE uygulanacak"
step "Taban: her şey sağlıklıyken"
# Taban kendi penceresinden okunur: sabit [2m], önceki deneyin kuyruğunu tabana katar.
tb=$(date +%s)
RATE=${GAMEDAY_RATE:-300} k6run steady --duration 30s >/dev/null 2>&1 || true
sleep 10
base_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[$(( $(date +%s) - tb ))s])) by (le))")
note "taban p99=$(awk -v v="$base_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
# Korumalar game day'den ÖNCE dinlenmede mi? Trafik almayan bir pod'un breaker'ı, açıldığı andaki
# durumda donar (yarı açığa geçmek için istek gerekir): Postgres'ten önce kalkan api pod'ları
# saatlerce "breaker açık · cache_only" raporlayabilir. Aşağıdaki tepe değerler 5 dakikalık pencereden
# okunduğu için, bu satır olmadan o bayat durum "game day'de breaker devreye girdi" sayılırdı.
pre_br=$(promq "max(breaker_state{namespace=\"$NS\"})"); pre_dg=$(promq "max(degraded_mode{namespace=\"$NS\"})")
note "game day öncesi: breaker=${pre_br%%.*} · degrade=${pre_dg%%.*} (ikisi de 0 olmalı)"
if awk -v b="$pre_br" -v d="$pre_dg" 'BEGIN{exit !(b > 0 || d > 0)}'; then
  warn "korumalar game day BAŞLAMADAN devrede — aşağıdaki breaker/degrade tepe değerleri bu arızayı ölçmüyor"
fi
# KONTROL DÜZLEMİ DE ÖLÇÜNÜN PARÇASI. 6 çekirdekli VM'i doyuran her şey (yük üreteci, derleme)
# API sunucusunu aç bırakır; lease yazmaları 25 sn'ye çıkar, controller-manager ve scheduler lider
# kirasını kaybedip yeniden başlar. O sırada öldürülen pod'un yerine yenisi
# KONMAZ ve game day sistemin değil kümenin dayanıklılığını ölçer. Restart olduysa hüküm verme.
# EN: if the control plane restarted during the run, the result describes the cluster, not the app.
cp_restarts() { kubectl -n kube-system get pods -l tier=control-plane \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
cp_before=$(cp_restarts)
step "GAME DAY başlıyor: üç arıza üst üste (sabit ${GAMEDAY_RATE:-300} istek/s)"
gd_start=$(date +%s)
# SABİT GELİŞ HIZI (steady.js): kapalı döngü bir yük (`mixed`) muaf girişte VM'i doyurur ve
# sistemi değil kümeyi ölçer; sabit geliş hızı ise sisteme bilinen bir yük verir.
( RATE=${GAMEDAY_RATE:-300} k6run steady --duration 150s >/tmp/p1405.k6 2>&1 ) & kpid=$!
sleep 15
note "  [00:15] Redis'e 200 ms gecikme"
chaos_apply redis-delay-200ms
sleep 30
note "  [00:45] Postgres'e %30 paket kaybı"
chaos_apply pg-loss-30
sleep 30
note "  [01:15] bir redirect pod'u öldürülüyor"
victim=$(kubectl -n "$NS" get pod -l "$APP_SELECTOR" -o jsonpath='{.items[0].metadata.name}') || true
kubectl -n "$NS" delete pod "$victim" --force --grace-period=0 >/dev/null 2>&1 || true
sleep 30
note "  [01:45] arızalar kaldırılıyor"
"$LADDER_ROOT/platform/lib/chaos.sh" delete redis-delay-200ms >/dev/null 2>&1 || true
"$LADDER_ROOT/platform/lib/chaos.sh" delete pg-loss-30 >/dev/null 2>&1 || true
wait $kpid || true
sleep 12
e5=$(k6_5xx); reqs=$(k6_reqs); e404=$(k6_404)
dropped=$(_k6q '.metrics.dropped_iterations.count // 0')
cp_after=$(cp_restarts)
avail=$(awk -v a="$e5" -v b="$reqs" 'BEGIN{printf "%.2f", (b>0? (1-a/b)*100 : 0)}')
breaker=$(promq "max_over_time(max(breaker_state{namespace=\"$NS\"})[5m:15s])")
shed=$(promq "sum(increase(load_shed_total{namespace=\"$NS\"}[5m]))")
retries=$(promq "sum(increase(retry_total{namespace=\"$NS\"}[5m]))")
degraded=$(promq "max_over_time(max(degraded_mode{namespace=\"$NS\"})[5m:15s])")
# ARIZANIN KENDİSİ, KENDİ BAĞIMLILIĞININ ETİKETİNDE. L2 önbelleğin Redis çağrıları Redis'in kendi
# guard'ından geçer (dep="redis"); 200 ms'lik Redis gecikmesi burada görünür, "postgres p99"da değil.
# L1 isabetleri Redis'e hiç gitmez: seri yalnızca L1 ıskalarının L2 çağrılarından oluşur.
# EN: the injected Redis delay must show up under dep="redis", not inside the postgres histogram.
redis_p99=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace=\"$NS\",dep=\"redis\"}[1m])) by (le))[5m:15s])")
pg_p99=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace=\"$NS\",dep=\"postgres\"}[1m])) by (le))[5m:15s])")
budget=$(promq "slo:period_error_budget_remaining:ratio{sloth_slo=\"redirect-availability\"} or vector(1)")
# İSTEMCİNİN GÖRDÜĞÜ ile UYGULAMANIN SAYDIĞI yan yana. Aradaki fark, istemciyle uygulama
# arasındaki bir katmanın (ingress, hız sınırı, hazır endpoint'i kalmamış servis) ürettiği
# cevaptır. Yalnızca istemcinin gördüğüne bakan bir game day tek haneli bir erişilebilirlik
# raporlayıp sistemi çökmüş gösterebilir: k6 tek IP'den geldiğinde 5xx'lerin neredeyse tamamı
# ingress'in hız sınırıdır, uygulamanın kendi 5xx sayısı ≈0'dır. `exempt` sayısı, yükün muafiyet jetonuyla (loadtest.sh)
# gerçekten limiter'ı atladığını gösterir; 0 ise ölçülen yine limiter'lardır.
# EN: the client's view and the app's own count, side by side; the gap is a layer in between.
win=$(( $(date +%s) - gd_start ))s
app_reqs=$(promq "sum(increase(http_requests_total{namespace=\"$NS\",service=~\"redirect|api\"}[$win]))")
app_5xx=$(promq "sum(increase(http_requests_total{namespace=\"$NS\",service=~\"redirect|api\",code=~\"5..\"}[$win]))")
app_429=$(promq "sum(increase(http_requests_total{namespace=\"$NS\",service=~\"redirect|api\",code=\"429\"}[$win]))")
exempt=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"exempt\"}[$win]))")
grafana_hint "11 · Resilience → 'Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)' + 'Bağımlılık gecikmesi p99' · 06 · Redis → 'Uygulama → Redis gecikmesi (p99)' · 12 · SLO → 'Kalan hata bütçesi'"
note "istemci (k6): $reqs istek · $e5 adet 5xx · uygulama: ${app_reqs%%.*} istek · ${app_5xx%%.*} adet 5xx · ${app_429%%.*} adet 429"
note "arada üretilen 5xx (ingress/endpoint yok): $(awk -v a="$e5" -v b="$app_5xx" 'BEGIN{d=a-b; printf "%.0f", (d>0?d:0)}') · limiter muafiyeti: ${exempt%%.*} istek"
if awk -v x="$exempt" 'BEGIN{exit !(x < 1)}'; then
  warn "muafiyet sayısı 0: yük limiter'ı atlamadı, aşağıdaki erişilebilirlik limiter'ları da ölçüyor olabilir"
fi
note "SONUÇ: $reqs istek · $e5 adet 5xx · erişilebilirlik %$avail · k6'nın yetişemediği istek: ${dropped%%.*}"
note "korumalar: breaker tepe durum=${breaker%%.*} · yük atma=${shed%%.*} · retry=${retries%%.*} · degrade=${degraded%%.*}"
note "bağımlılık p99 tepe: redis=$(awk -v v="$redis_p99" 'BEGIN{printf "%.0f", v*1000}') ms (enjekte edilen +200 ms burada görünmeli) · postgres=$(awk -v v="$pg_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
if awk -v v="$redis_p99" 'BEGIN{exit !(v < 0.15)}'; then
  warn "Redis p99 tepesi 150 ms'nin altında: gecikme Redis'e ulaşmamış ya da dep=\"redis\" ölçülmüyor (L2 önbellek Redis guard'ından geçiyor mu?)"
fi
note "kalan hata bütçesi: $(awk -v v="$budget" 'BEGIN{printf "%.2f%%", v*100}')"
note "Beklenen davranış: sistem KISMEN bozulur, tamamen değil. Her koruma kendi işini yapar ve"
note "toplam etki, parçaların toplamından AZ olur — çünkü biri diğerinin yükünü emer."
note "Bu bir 'test' değil bir PROVA'dır: amacı geçmek değil, hangi korumanın ne zaman devreye"
note "girdiğini GÖRMEK ve runbook'u buna göre yazmak."
note "Tam tur için: tools/ladder-matrix/run.sh — tüm seviyelerin tüm scriptlerini bu seviyeye koşar."
if (( cp_after > cp_before )); then
  warn "kontrol düzlemi deney sırasında $(( cp_after - cp_before )) kez yeniden başladı — sonuç kümeyi ölçüyor, hüküm verilmiyor"
  exit 2
fi
awk -v a="$avail" 'BEGIN{exit !(a > 50)}' \
  && reproduced "üç eşzamanlı arıza altında sistem %$avail erişilebilir kaldı (breaker ${breaker%%.*}, shed ${shed%%.*}, retry ${retries%%.*}) — kısmi bozulma, tam çöküş değil"
not_reproduced "sistem game day'i geçemedi (erişilebilirlik %$avail) — hangi korumanın devreye girmediğini panellerden bul"
