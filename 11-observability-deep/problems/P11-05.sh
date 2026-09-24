#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-05 · Gözlemlenebilirliğin de bir kapasitesi vardır: debug log Loki'yi limitler
# "Sorun yaşıyoruz, log seviyesini debug yapalım" — ve tam o anda log boru hattı doluyor,
# Loki 429 dönmeye başlıyor ve SORUNU ARAŞTIRDIĞIN LOGLAR KAYBOLUYOR. Gözlemlenebilirlik,
# gözlemlediği sistemden bağımsız değildir; onunla birlikte ölçeklenmesi gerekir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" LOG_LEVEL=info"
loki_rejects() {
  promq 'sum(increase(loki_discarded_samples_total[3m])) or sum(increase(loki_request_duration_seconds_count{status_code="429"}[3m])) or vector(0)'
}
step "(1) LOG_LEVEL=info (varsayılan) altında yük"
# FAZ BAŞINA PENCERE. Sabit bir `rate(...[2m])` her iki fazda da KOMŞU fazın trafiğini içerir:
# ikinci ölçüm, yeni pod'lar daha yeni ayağa kalkmışken birinci fazın kuyruğunu okur ve sonuç
# ters çıkar — debug seviyesinde bayt/s DAHA DÜŞÜK görünür, ki bu fiziksel olarak saçmadır.
# Her faz kendi süresi kadar bir pencere okur.
# EN: a fixed [2m] window straddles both phases; the second reading is dominated by the first
# phase's tail while the new pods have barely started, so debug appears to log LESS than info.
T0=$(date +%s)
k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 15
W1=$(( $(date +%s) - T0 ))
r1=$(loki_rejects)
ingest1=$(promq "sum(increase(loki_distributor_bytes_received_total[${W1}s]) ) / ${W1} or vector(0)")
note "info: Loki reddi=${r1%%.*} · alınan bayt/s=$(awk -v v="$ingest1" 'BEGIN{printf "%.0f", v}')"
step "(2) LOG_LEVEL=debug ile AYNI yük"
setenv "$(wl redirect)" LOG_LEVEL=debug >/dev/null
settle_rollout "$(wl redirect)"
T0=$(date +%s)
k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 15
W2=$(( $(date +%s) - T0 ))
r2=$(loki_rejects)
ingest2=$(promq "sum(increase(loki_distributor_bytes_received_total[${W2}s]) ) / ${W2} or vector(0)")
note "debug: Loki reddi=${r2%%.*} · alınan bayt/s=$(awk -v v="$ingest2" 'BEGIN{printf "%.0f", v}')"
grafana_hint "Explore → Loki: {namespace=\"$NS\"} sorgusunda boşluk var mı? · platform/helm/loki.values.yaml → ingestion_rate_mb"
note "Loki'nin limiti platform/helm/loki.values.yaml'da: ingestion_rate_mb=8. Aşınca kayıtlar DÜŞER."
note "Araçlar: (a) log seviyesini ÇALIŞIRKEN değiştirebilmek (burada env + rollout; daha iyisi"
note "runtime endpoint), (b) log SAMPLING (her N'inci satır), (c) yüksek hacimli alanları trace'e"
note "taşımak — tek istek detayı log'un değil trace'in işi."
note "Asıl ders: teşhis araçların, teşhis ettiğin olay sırasında ÇALIŞMAYA DEVAM ETMELİ."
note "Gözlemlenebilirliği kapasite planlamasının dışında tutmak, onu tam gerektiği anda kaybetmektir."
awk -v a="$ingest1" -v b="$ingest2" 'BEGIN{exit !(b > a)}' \
  && reproduced "debug seviyesi log hacmini $(awk -v v="$ingest1" 'BEGIN{printf "%.0f", v}') → $(awk -v v="$ingest2" 'BEGIN{printf "%.0f", v}') bayt/s'e çıkardı (Loki reddi ${r1%%.*} → ${r2%%.*})"
not_reproduced "log hacmi farkı ölçülemedi (Loki metrikleri Prometheus'ta mı?)"
