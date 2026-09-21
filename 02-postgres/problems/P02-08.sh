#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-08 · Sıcak link → satır kilidi kuyruğu (01'deki mutex'in DB'deki hâli)
# Her redirect aynı satıra UPDATE atıyor. Postgres satır kilidi tek sıralı: 500 eşzamanlı tıklama
# CPU'ya değil, KİLİT KUYRUĞUNA giriyor. Üstelik her UPDATE yeni satır sürümü (MVCC) → ölü satır.
ensure_healthy
pgpod=$(dep_pod app.kubernetes.io/name=postgres) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
psql() { kubectl -n "$NS" exec "$pgpod" -c postgres -- psql -U linkly -d linkly -tAc "$1" 2>/dev/null; }
step "Referans: trafiğin dağıldığı durum (mixed)"
k6run mixed --vus 60 --duration 40s >/dev/null 2>&1 || true
sleep 10
spread_p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")")
note "dağıtık yükte redirect p99: $(awk -v v="$spread_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
step "Aynı yük, trafiğin %90'ı TEK linke (hot key)"
HOT_SHARE=0.9 k6run hot-key --vus 60 --duration 40s >/dev/null 2>&1 || true
sleep 12
hot_p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")")
upd_p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(db_query_duration_seconds_bucket{namespace=\"$NS\",op=\"increment_clicks\"}[1m])) by (le))")")
get_p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(db_query_duration_seconds_bucket{namespace=\"$NS\",op=\"get\"}[1m])) by (le))")")
locks=$(promq "sum(pg_locks_count{namespace=\"$NS\"})")
dead=$(psql "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='links'")
grafana_hint "05 · Postgres → 'locks' + 'DB query p99 by op' (increment_clicks) + 'dead tuples'"
note "hot-key yükte redirect p99: $(awk -v v="$hot_p99" 'BEGIN{printf "%.0f", v*1000}') ms (dağıtıkta $(awk -v v="$spread_p99" 'BEGIN{printf "%.0f", v*1000}') ms)"
note "UPDATE p99: $(awk -v v="$upd_p99" 'BEGIN{printf "%.0f", v*1000}') ms · SELECT p99: $(awk -v v="$get_p99" 'BEGIN{printf "%.0f", v*1000}') ms ← fark kilit kuyruğu"
note "PG kilit sayısı: ${locks%%.*} · links tablosunda ölü satır: ${dead:-?}"
note "Ölü satırlar boşuna değil: her tıklama yeni bir satır sürümü yazıyor, autovacuum temizlemeye çalışıyor."
note "Sonuç: sistemin en POPÜLER linki, en YAVAŞ linki oluyor. Ölçek arttıkça kötüleşir."
note "Çözüm 05: tıklamayı istek yolundan çıkar (bounded kuyruk + batch) · 06: dayanıklı olay akışı."
awk -v u="$upd_p99" -v g="$get_p99" 'BEGIN{exit !(u > g)}' \
  && reproduced "sıcak satırda UPDATE, SELECT'ten yavaş ($(awk -v v="$upd_p99" 'BEGIN{printf "%.0f", v*1000}') ms vs $(awk -v v="$get_p99" 'BEGIN{printf "%.0f", v*1000}') ms) — tıklama sayacı okuma yolunu yavaşlatıyor"
not_reproduced "sıcak satır gecikme yaratmadı — yazma istek yolundan çıkmış (05)"
