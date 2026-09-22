#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-02 · Uygulamayı ölçeklemek darboğazı TAŞIR, yok etmez
# HPA redirect'i 12 replikaya çıkarabiliyor. Ama Postgres hâlâ TEK ve max_connections=100.
# Her yeni pod kendi havuzunu açıyor: ölçeklendikçe uygulama rahatlıyor, veritabanı boğuluyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
need_metric pg_settings_max_connections "postgres ServiceMonitor deploy/servicemonitor.yaml'da mı?"
maxconn=$(promq "max(pg_settings_max_connections{namespace=\"$NS\"})")
step "Aritmetik önce"
rpool=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="DB_MAX_CONNS")]}{.value}{end}') || true
apool=$(kubectl -n "$NS" get "$(wl api)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="DB_MAX_CONNS")]}{.value}{end}') || true
hpamax=$(kubectl -n "$NS" get hpa redirect -o jsonpath='{.spec.maxReplicas}') || true
note "max_connections=${maxconn%%.*} · redirect havuzu=$rpool × HPA max $hpamax = $(( ${rpool:-6} * ${hpamax:-12} ))"
note "+ api ($apool × 2 = $(( ${apool:-15} * 2 ))) + tüketici (10) = $(( ${rpool:-6} * ${hpamax:-12} + ${apool:-15} * 2 + 10 )) > ${maxconn%%.*}"
step "Merdiven yükü: rps kademeli artıyor, HPA ölçekliyor"
# YÜK DB'YE ULAŞMALI, yoksa "darboğaz DB'ye taşındı" iddiası ÖLÇÜLEMEZ.
# `stairs` 200 tohumlanmış kodu döndürür ve 04'ten beri önbellek PAYLAŞIMLI: isabet oranı ~%100,
# yani Postgres neredeyse hiç sorgulanmaz. Ölçüldü: havuz beklemesi 0 ms, 0 DB hatası,
# 38/100 bağlantı — ve script "DB baskısı yok" dedi. Oysa DB'ye hiç gitmemiştik.
# Rastgele kodlar (scan) her istekte bir DB okuması üretir: deneyin ölçmek istediği durumu
# deneyin KENDİSİ yaratmalıdır. (Aynı ders P06-01'de: pencereyi yanlış süreç besliyordu.)
# EN: the load has to REACH the database or the claim cannot be measured. `stairs` replays 200
# seeded codes and the cache has been SHARED since level 04, so the hit ratio is ~100% and
# Postgres is barely queried — measured: 0 ms pool wait, 0 DB errors, 38/100 connections, and the
# script concluded "no DB pressure" when we had simply never gone to the DB. Random codes (scan)
# force one DB read per request. An experiment must produce the state it wants to measure.
( k6run scan --vus 30 --duration 150s >/dev/null 2>&1 || true ) & scanpid=$!
k6run stairs >/dev/null 2>&1 || true
wait_pid_quiet "$scanpid"
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
# ÖLÇÜ SEÇİMİ: iddia "darboğaz DB'ye taşındı", ölçüsü ise bağlantı sayısı DEĞİL.
# İlk hâl `bağlantı > max*0.6` istiyordu; HPA hedefe ulaşmadığı için pod sayısı artmayınca
# bağlantı da artmıyor ve script "DB baskısı yok" diyordu — oysa aynı koşuda havuz beklemesi
# 333 ms ve 2020 DB hatası vardı, yani darboğaz zaten DB'ydi. Bağlantı sayısı bu sorunun
# BİR belirtisi; asıl belirti uygulamanın DB'yi BEKLİYOR olması. Aritmetik (112 > 100) ise
# zaten tahtada duruyor: ölçek büyüdükçe duvara çarpacağını göstermek için duvara çarpmak gerekmez.
{ awk -v a="$acq" 'BEGIN{exit !(a > 0.05)}' || awk -v e="${dberr%%.*}" 'BEGIN{exit !(e > 0)}'; } \
  && reproduced "uygulama CPU'su rahat ($(awk -v v="$appcpu" 'BEGIN{printf "%.2f", v}') çekirdek) ama DB bekletiyor: havuz bekleme p99 $(awk -v v="$acq" 'BEGIN{printf "%.0f", v*1000}') ms, ${dberr%%.*} DB hatası, ${conns%%.*}/${maxconn%%.*} bağlantı — darboğaz DB'ye taşındı"
not_reproduced "DB baskısı ölçülemedi (havuz bekleme $(awk -v v="$acq" 'BEGIN{printf "%.0f", v*1000}') ms, ${dberr%%.*} hata) — stairs yükünü artır"
