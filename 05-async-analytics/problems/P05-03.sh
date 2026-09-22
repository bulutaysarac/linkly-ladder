#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P05-03 · Analitik yazıcısı redirect ile AYNI süreçte ve AYNI veritabanında yarışıyor
# Yazma istek yolundan çıktı ama SÜREÇTEN çıkmadı: aynı pod'un CPU'sunu, aynı bağlantı havuzunu
# ve aynı veritabanını paylaşıyor. Yani izolasyon kısmi.
ensure_healthy
step "Sadece okuma: taban p99 ve havuz kullanımı"
k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 10
base_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
base_acq=$(promq "histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace=\"$NS\"}[1m])) by (le))")
note "taban: redirect p99=$(awk -v v="$base_p99" 'BEGIN{printf "%.0f", v*1000}') ms · havuz bekleme p99=$(awk -v v="$base_acq" 'BEGIN{printf "%.1f", v*1000}') ms"
step "Aynı anda yoğun tıklama (yazıcı sürekli toplu yazıyor) + okuma"
k6run hot-key --vus 80 --duration 45s >/dev/null 2>&1 || true
sleep 10
busy_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
busy_acq=$(promq "histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace=\"$NS\"}[1m])) by (le))")
batch=$(promq "histogram_quantile(0.99, sum(rate(analytics_batch_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")
wq=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"write_clicks\"}[2m]))")
# AYIRT EDİCİ İŞARET, GERÇEKTEN OLUŞAN BİR ŞEY OLMALI.
# Bu script doğru bir kural koyuyordu ("eşiğin, X olmadığında oluşmayacak bir şeyi ölçmeli") ama
# yanlış bir işaret seçmişti: AYNI havuzda BEKLEME. Ölçüldü — havuz beklemesi iki fazda da
# 0.1 ms; bu ölçekte havuz darboğaz değil, veritabanının kendisi darboğaz (toplu yazma p99
# 2500 ms). Yani ayırt edici işaret 05'te bile hiç oluşmuyordu ve script kendi seviyesinde
# NOT-REPRODUCED diyordu.
# Gerçekten ayırt edici olan şey şu: yazma sorguları KİMİN sürecinden geliyor? 05'te yazıcı
# uygulamanın İÇİNDE, yani write_clicks sorguları uygulama pod'larından çıkar. 06'da yazıcı ayrı
# bir deployment (analytics-*) olduğu için uygulama pod'larından çıkan write_clicks SIFIRLANIR.
# Bu, "izolasyon bir süreç meselesidir" iddiasının birebir ölçüsüdür.
# EN: the rule was right ("measure something that would not happen without X") but the chosen
# signal never occurred: pool wait stayed at 0.1 ms in both phases because the pool is not the
# bottleneck here — the database is (batch write p99 2500 ms). The signal that really does flip
# is WHOSE process issues the writes: inside the app at 05, a separate deployment at 06.
wq_app=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"write_clicks\",pod=~\"$(app_name)-.*\"}[2m]))")
grafana_hint "07 · Analytics → 'batch write latency p99' · 05 · Postgres → 'App pool: acquire wait p99'"
note "yoğun: redirect p99=$(awk -v v="$busy_p99" 'BEGIN{printf "%.0f", v*1000}') ms · havuz bekleme p99=$(awk -v v="$busy_acq" 'BEGIN{printf "%.1f", v*1000}') ms"
note "toplu yazma p99=$(awk -v v="$batch" 'BEGIN{printf "%.0f", v*1000}') ms · write_clicks sorgu/s=$(awk -v v="$wq" 'BEGIN{printf "%.1f", v}')"
note "Paylaşılan üç kaynak: pod CPU'su, DB bağlantı havuzu, veritabanının kendisi."
note "Çözüm 06+07: tüketiciyi AYRI BİR SÜREÇ ve ayrı bir deployment yap — kendi havuzu, kendi"
note "CPU limiti, kendi ölçeklenmesi. İzolasyon bir arayüz meselesi değil, bir SÜREÇ meselesidir."
# `b >= a` bir kanıt değil: p99 iki koşu arasında zaten oynar ve bu eşik GÜRÜLTÜYLE geçilir.
# 06'da yazıcı ayrı bir süreç ve ayrı bir havuz kullanıyor — yani bu script orada NOT-REPRODUCED
# demeli. Ayırt edici işaret paylaşılan kaynak: AYNI bağlantı havuzunda bekleme.
# Kural: iddian "X, Y'yi etkiliyor" ise, eşiğin X olmadığında oluşmayacak bir şeyi ölçmeli.
note "uygulama pod'larından çıkan write_clicks/s=$(awk -v v="$wq_app" 'BEGIN{printf "%.1f", v}') — 06'da bu sayı SIFIRLANIR (yazıcı ayrı deployment)"
awk -v a="$base_p99" -v b="$busy_p99" -v w="$wq_app" \
    'BEGIN{exit !( a > 0 && b > a*1.3 && w > 0 )}' \
  && reproduced "yazıcı uygulamanın İÇİNDE ($(awk -v v="$wq_app" 'BEGIN{printf "%.1f", v}') write_clicks/s uygulama pod'larından) ve çalışırken okuma p99'u $(awk -v v="$base_p99" 'BEGIN{printf "%.0f", v*1000}')→$(awk -v v="$busy_p99" 'BEGIN{printf "%.0f", v*1000}') ms oldu (havuz bekleme $(awk -v v="$base_acq" 'BEGIN{printf "%.1f", v*1000}')→$(awk -v v="$busy_acq" 'BEGIN{printf "%.1f", v*1000}') ms)"
not_reproduced "yazıcı okuma yolunu etkilemedi (p99 $(awk -v v="$base_p99" 'BEGIN{printf "%.0f", v*1000}')→$(awk -v v="$busy_p99" 'BEGIN{printf "%.0f", v*1000}') ms · uygulamadan write_clicks/s=$(awk -v v="$wq_app" 'BEGIN{printf "%.1f", v}')) — yazıcı ayrı süreçte (06)"
