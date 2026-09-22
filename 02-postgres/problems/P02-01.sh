#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-01 · Her redirect bir DB sorgusu — okuma yolu artık ağda
# 01'de redirect bir map aramasıydı (nanosaniye). Şimdi ağ üzerinden iki sorgu: SELECT + UPDATE.
# Okuma ağırlıklı bir sistemde (1 yazma : 100-1000 okuma) bu, yükün TAMAMINI DB'ye taşımak demek.
ensure_healthy
step "Yük öncesi taban"
db0=$(promq "sum(rate(db_queries_total{namespace=\"$NS\"}[1m]))")
note "DB sorgu/s (boşta): ${db0%%.*}"
step "60 sn redirect yükü — her istek DB'ye gidiyor"
k6run redirect --vus 30 --duration 60s || true
sleep 15
# OKUMA sorgularını ayrı ölç. Toplam sorguya bakmak yanıltır: bir sonraki seviye (03) okumayı
# önbelleğe alır ama tıklama UPDATE'i istek yolunda kalır (o P02-08, 05'te çözülüyor). Toplam
# oran hâlâ ~1 çıkar ve "önbellek işe yaramadı" gibi YANLIŞ bir sonuç verirdi.
dbqps=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[2m]))")
dball=$(promq "sum(rate(db_queries_total{namespace=\"$NS\"}[2m]))")
httprps=$(promq "sum(rate(http_requests_total{namespace=\"$NS\",route=\"/{code}\"}[2m]))")
ratio=$(awk -v a="$dbqps" -v b="$httprps" 'BEGIN{printf "%.1f", (b>0? a/b : 0)}')
pgcpu=$(promq "sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"postgres.*\",image!=\"\",image!~\".*pause.*\"}[2m]))")
p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
getp99=$(promq "histogram_quantile(0.99, sum(rate(db_query_duration_seconds_bucket{namespace=\"$NS\",op=\"get\"}[2m])) by (le))")
grafana_hint "05 · Postgres → 'DB queries by op' + 'DB CPU' · 02 · App RED → 'p99 by route'"
note "HTTP redirect/s: ${httprps%%.*} · DB OKUMA/s: ${dbqps%%.*} → istek başına ~${ratio} okuma"
note "(tüm DB sorguları: ${dball%%.*}/s — okuma + tıklama UPDATE'i; UPDATE 05'te kalkacak)"
note "Postgres CPU: $(awk -v v="$pgcpu" 'BEGIN{printf "%.2f", v}') çekirdek · redirect p99: $(awk -v v="$p99" 'BEGIN{printf "%.1f", v*1000}') ms (DB get p99: $(awk -v v="$getp99" 'BEGIN{printf "%.1f", v*1000}') ms)"
note "İstek başına ~2 sorgu: SELECT (link) + UPDATE (tıklama). UPDATE'i 05, SELECT'i 03/04 kaldıracak."
note "Ölçek hesabı: 10k rps redirect = 20k sorgu/s. Tek Postgres bunu taşımaz; önbellek MİMARİNİN KENDİSİ olur."
# Eşik: istek başına 0.5 OKUMA. Önbellek devredeyse bu oran 0.1'in altına iner.
awk -v r="$ratio" 'BEGIN{exit !(r >= 0.5)}' \
  && reproduced "her redirect DB'den OKUYOR (istek başına ~${ratio} okuma, PG CPU $(awk -v v="$pgcpu" 'BEGIN{printf "%.2f", v}') çekirdek)"
not_reproduced "okumalar DB'ye gitmiyor (istek başına ~${ratio}) — önbellek devrede (03/04)"
