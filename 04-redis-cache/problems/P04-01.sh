#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-01 · Redis düşünce bütün yük DB'ye iner (P02-01 geri gelir)
# Fail-open doğru karar: önbellek yoksa DB'ye düş, hizmeti kesme. Ama bu bir SÖZ değil bir BAHİS:
# DB'nin, önbelleğin sakladığı yükün tamamını aniden kaldırabileceğine bahse giriyorsun.
ensure_healthy
step "Önbellek çalışırken taban ölç"
k6run redirect --vus 25 --duration 40s >/dev/null 2>&1 || true
sleep 12
db_warm=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[1m]))")
hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\",result=\"hit\"}[1m])) / sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\"}[1m]))")
note "önbellek açık: DB get/s=$(awk -v v="$db_warm" 'BEGIN{printf "%.1f", v}') · hit oranı=$(awk -v v="$hit" 'BEGIN{printf "%.0f%%", v*100}')"
need_confirm "redis pod'u silinecek"
# Deneyden sonra Redis'in GERİ GELDİĞİNDEN emin ol: sonraki deney (P04-06/07) redis pod'unu
# arıyor ve o pencerede boş liste bulursa kendi sorunuyla ilgisiz bir hatayla düşer.
on_cleanup "kubectl -n \"$NS\" rollout status statefulset/redis --timeout=180s"
step "Redis'i öldür, AYNI yükü tekrar ver"
kubectl -n "$NS" delete pod -l app.kubernetes.io/name=redis --wait=false >/dev/null
sleep 3
k6run redirect --vus 25 --duration 40s >/dev/null 2>&1 || true
sleep 12
db_cold=$(promq "max_over_time(sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[30s]))[3m:15s])")
e5=$(k6_5xx); fr=$(k6_failed_rate)
cerr=$(promq "sum(increase(cache_errors_total{namespace=\"$NS\"}[5m]))")
p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
grafana_hint "06 · Redis → 'redis_up' · 04 · Cache → 'cache load error' · 05 · Postgres → 'DB queries by op'"
note "önbellek yokken: DB get/s TEPE=$(awk -v v="$db_cold" 'BEGIN{printf "%.0f", v}') · önbellek hatası=${cerr%%.*} · 5xx=$e5 · p99=$(awk -v v="$p99" 'BEGIN{printf "%.0f", v*1000}') ms"
note "HİZMET DEVAM ETTİ (5xx=$e5) — fail-open çalıştı. Ama DB yükü $(awk -v a="$db_warm" -v b="$db_cold" 'BEGIN{printf "%.0fx", (a>0? b/a : 0)}') arttı."
note "Asıl soru şu: DB bu artışı kaldırabilir mi? Kaldıramazsa fail-open, kesintiyi Redis'ten DB'ye TAŞIR."
note "Çözüm yönü: 10 (bulkhead + shedding: DB'ye giden eşzamanlılığı sınırla, fazlasını hızlıca reddet)"
note "            14 (L1+L2: pod içi küçük bir önbellek, Redis düşse de en sıcak anahtarları tutar)"
awk -v a="$db_warm" -v b="$db_cold" 'BEGIN{exit !(b > a*2 && b > 5)}' \
  && reproduced "Redis kaybı DB okumasını $(awk -v v="$db_warm" 'BEGIN{printf "%.0f", v}')/s → $(awk -v v="$db_cold" 'BEGIN{printf "%.0f", v}')/s'e çıkardı"
not_reproduced "DB yükü belirgin artmadı (önbellek zaten soğuk olabilir; önce make load S=mixed ile ısıt)"
