#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-06 · Yavaş DB + sunucu tarafı timeout yok → havuz dolar → kaskad
# Client context'i 3 sn sonra vazgeçiyor. Ama STATEMENT_TIMEOUT boş olduğu için Postgres sorguyu
# çalıştırmaya DEVAM ediyor: bağlantı meşgul kalıyor, havuz doluyor, yeni istekler bekliyor.
# Vazgeçmek, işin durmasını sağlamaz — yalnızca beklemeyi bırakır.
ensure_healthy
st=$(kubectl -n "$NS" get "$(app_workload)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="STATEMENT_TIMEOUT")]}{.value}{end}') || true
step "Ayarlar"
note "client tarafı DB_QUERY_TIMEOUT: $(kubectl -n "$NS" get "$(app_workload)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="DB_QUERY_TIMEOUT")]}{.value}{end}')"
note "sunucu tarafı STATEMENT_TIMEOUT: '${st:-<boş — KAPALI>}'"
step "Postgres'e 2 sn gecikme enjekte et (Chaos Mesh)"
chaos_apply pg-delay-2s
sleep 5
k6run mixed --vus 40 --duration 60s || true
sleep 12
e5=$(k6_5xx); p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")
acq=$(promq "histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")
empty=$(promq "sum(increase(db_pool_empty_acquire_total{namespace=\"$NS\"}[5m]))")
inflight=$(promq "max_over_time(sum(http_in_flight_requests{namespace=\"$NS\"})[5m:15s])")
notready=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" --no-headers | grep -vc '1/1' || true)
grafana_hint "05 · Postgres → 'App pool: acquire wait p99' + 'empty acquire/s' · 11 · Resilience → 'in-flight by pod'"
note "p99: $(awk -v v="$p99" 'BEGIN{printf "%.0f", v*1000}') ms · havuz bekleme p99: $(awk -v v="$acq" 'BEGIN{printf "%.0f", v*1000}') ms · boş havuz bekleme: ${empty%%.*}"
note "tepe in-flight istek: ${inflight%%.*} · hazır olmayan pod: $notready · 5xx: $e5"
note "Zincir: yavaş sorgu → bağlantı meşgul → havuz boş → yeni istekler bekler → in-flight birikir → bellek ve p99 patlar."
note "İki ayrı önlem gerekiyor ve biri diğerinin yerini TUTMAZ:"
note "  1) STATEMENT_TIMEOUT (sunucu): sorguyu gerçekten DURDURUR → kubectl -n $NS set env "$(app_workload)" STATEMENT_TIMEOUT=2s"
note "  2) Devre kesici + bulkhead (10): bağımlılık bozukken istek göndermeyi bırak"
{ awk -v a="$acq" 'BEGIN{exit !(a>0.05)}' || (( e5 > 0 )) || awk -v e="${empty%%.*}" 'BEGIN{exit !(e>0)}'; } \
  && reproduced "yavaş DB havuzu tıkadı (bekleme p99 $(awk -v v="$acq" 'BEGIN{printf "%.0f", v*1000}') ms, boş bekleme ${empty%%.*}, 5xx $e5)"
not_reproduced "havuz baskı altında kalmadı — timeout/breaker devrede (10)"
