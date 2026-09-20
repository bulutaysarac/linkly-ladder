#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-02 · Uygulamayı ölçeklemek darboğazı TAŞIR, yok etmez
# HPA redirect'i 12 replikaya çıkarabiliyor. Ama Postgres hâlâ TEK ve max_connections=100.
# Her yeni pod kendi havuzunu açıyor: ölçeklendikçe uygulama rahatlıyor, veritabanı boğuluyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
maxconn=$(promq "max(pg_settings_max_connections{namespace=\"$NS\"})")
step "Aritmetik önce"
rpool=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="DB_MAX_CONNS")]}{.value}{end}')
apool=$(kubectl -n "$NS" get deploy api -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="DB_MAX_CONNS")]}{.value}{end}')
hpamax=$(kubectl -n "$NS" get hpa redirect -o jsonpath='{.spec.maxReplicas}')
note "max_connections=${maxconn%%.*} · redirect havuzu=$rpool × HPA max $hpamax = $(( ${rpool:-6} * ${hpamax:-12} ))"
note "+ api ($apool × 2 = $(( ${apool:-15} * 2 ))) + tüketici (10) = $(( ${rpool:-6} * ${hpamax:-12} + ${apool:-15} * 2 + 10 )) > ${maxconn%%.*}"
step "Merdiven yükü: rps kademeli artıyor, HPA ölçekliyor"
k6run stairs >/dev/null 2>&1 || true
sleep 12
pods=$(promq "max_over_time(kube_deployment_status_replicas_available{namespace=\"$NS\",deployment=\"redirect\"}[6m:15s])")
conns=$(promq "max_over_time(sum(pg_stat_activity_count{namespace=\"$NS\"})[6m:15s])")
pgcpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"postgres.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[6m:15s])")
appcpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[6m:15s])")
dberr=$(promq "sum(increase(db_queries_total{namespace=\"$NS\",result=\"error\"}[6m]))")
acq=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{namespace=\"$NS\"}[1m])) by (le))[6m:15s])")
grafana_hint "09 · Autoscaling → 'rps vs pod sayısı' · 05 · Postgres → 'connections vs max' + 'DB CPU'"
note "tepe redirect pod=${pods%%.*} · tepe PG bağlantı=${conns%%.*}/${maxconn%%.*} · PG CPU=$(awk -v v="$pgcpu" 'BEGIN{printf "%.2f", v}') · app CPU=$(awk -v v="$appcpu" 'BEGIN{printf "%.2f", v}')"
note "havuz bekleme p99=$(awk -v v="$acq" 'BEGIN{printf "%.0f", v*1000}') ms · DB hatası=${dberr%%.*}"
note "Okuma: uygulama CPU'su rahat, veritabanı tıkanıyor. Otomatik ölçekleme darboğazı GÖRÜNMEZ"
note "yapmaz, TAŞIR — ve taşıdığı yer genelde ölçeklenemeyen yerdir."
note "09: CNPG + PgBouncer (yüzlerce uygulama bağlantısı → onlarca DB bağlantısı) + okuma replikaları."
awk -v c="${conns%%.*}" -v m="${maxconn%%.*}" 'BEGIN{exit !(c > m*0.6)}' \
  && reproduced "ölçeklenen uygulama DB bağlantılarını ${conns%%.*}/${maxconn%%.*}'e çıkardı (havuz bekleme $(awk -v v="$acq" 'BEGIN{printf "%.0f", v*1000}') ms) — darboğaz DB'ye taşındı"
not_reproduced "DB baskısı ölçülemedi (stairs yükünü artır ya da HPA max'ı yükselt)"
