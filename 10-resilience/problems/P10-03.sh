#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-03 · Timeout hizasızlığı: client vazgeçti, sunucu çalışmaya devam ediyor
# Client 1 sn sonra bağlantıyı kapatır; sunucu bunu bilmiyorsa 30 sn daha çalışır, bağlantı tutar,
# CPU yakar ve CEVABI KİMSEYE TESLİM EDEMEZ. Yük altında bu, tamamen boşa harcanan kapasitedir.
# Timeout bütçesi bir zincirdir: her katman, kendisini çağıranın kalan süresinden AZ beklemeli.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "$LADDER_ROOT/platform/lib/chaos.sh delete pg-delay-2s"
step "Bütçe zinciri"
ht=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="HANDLER_TIMEOUT")]}{.value}{end}') || true
dt=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="DEP_TIMEOUT")]}{.value}{end}') || true
qt=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="DB_QUERY_TIMEOUT")]}{.value}{end}') || true
note "handler=${ht:-5s} · bağımlılık=${dt:-2s} · sorgu=${qt:-3s}"
note "Doğru sıra: handler > bağımlılık ≥ sorgu. Sorgu timeout'u handler'dan BÜYÜKSE, handler"
note "vazgeçtikten sonra sorgu çalışmaya devam eder — tam olarak bu sorunun kaynağı."
step "Postgres'e 2 sn gecikme + client tarafı 1 sn timeout ile yük"
chaos_apply pg-delay-2s
sleep 5
k6run mixed --vus 30 --duration 45s -e K6_TIMEOUT=1s >/dev/null 2>&1 || true
sleep 10
inflight=$(promq "max_over_time(sum(http_in_flight_requests{namespace=\"$NS\"})[3m:15s])")
goroutines=$(promq "max_over_time(sum(go_goroutines{namespace=\"$NS\",pod=~\"redirect.*\"})[3m:15s])")
dep_p99=$(promq "histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace=\"$NS\",dep=\"postgres\"}[2m])) by (le))")
timeouts=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"postgres\",result=\"timeout\"}[3m]))")
bulk=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"postgres\",result=\"bulkhead\"}[3m]))")
grafana_hint "11 · Resilience → 'in-flight by pod' + 'dependency p99 by dep' · 01 · Pods → Goroutine"
note "tepe in-flight=${inflight%%.*} · tepe goroutine=${goroutines%%.*} · bağımlılık p99=$(awk -v v="$dep_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
note "bağımlılık timeout=${timeouts%%.*} · bulkhead reddi=${bulk%%.*}"
note "Bulkhead reddi GÖRÜNÜYORSA koruma çalışıyor demektir: yavaş bağımlılık, kendisine ayrılan"
note "eşzamanlılıkla sınırlı kaldı ve geri kalan kapasiteyi yemedi."
note "Eksik kalan halka: sunucu tarafı statement_timeout (P02-06). Client vazgeçse bile Postgres"
note "sorguyu durdurmaz — bunu yalnızca DB'nin kendisi yapabilir."
awk -v t="${timeouts%%.*}" -v b="${bulk%%.*}" 'BEGIN{exit !(t>0 || b>0)}' \
  && reproduced "yavaş bağımlılık timeout (${timeouts%%.*}) ve bulkhead (${bulk%%.*}) ile sınırlandı; tepe in-flight ${inflight%%.*}"
not_reproduced "timeout/bulkhead tetiklenmedi (chaos uygulandı mı?)"
