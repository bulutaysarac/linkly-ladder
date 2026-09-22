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
k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 15
r1=$(loki_rejects)
ingest1=$(promq 'sum(rate(loki_distributor_bytes_received_total[2m])) or vector(0)')
note "info: Loki reddi=${r1%%.*} · alınan bayt/s=$(awk -v v="$ingest1" 'BEGIN{printf "%.0f", v}')"
step "(2) LOG_LEVEL=debug ile AYNI yük"
setenv "$(wl redirect)" LOG_LEVEL=debug >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 15
r2=$(loki_rejects)
ingest2=$(promq 'sum(rate(loki_distributor_bytes_received_total[2m])) or vector(0)')
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
