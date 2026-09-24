#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-01 · HPA gecikir: burst geldiğinde pod'lar ANINDA gelmez
# Ölçekleme reaktiftir ve bir zincir vardır: metrics-server CPU'yu örnekler (15 sn) → HPA değerlendirir (15 sn) →
# pod planlanır → imaj çekilir → süreç başlar → readiness geçer. Bu zincir bir burst'ten YAVAŞTIR.
# Otomatik ölçekleme kapasite planlamasının yerini TUTMAZ; onu daha ucuz hâle getirir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Başlangıç durumu"
kubectl -n "$NS" get hpa redirect -o custom-columns=HEDEF:.spec.metrics[0].resource.target.averageUtilization,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,ŞİMDİ:.status.currentReplicas --no-headers 2>/dev/null | sed 's/^/    /'
r0=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.status.readyReplicas}') || true
note "hazır replika: ${r0:-0}"
step "Ani yük (burst senaryosu: 5 rps → ${PEAK:-400} rps, tepe 20 sn; daha sertini PEAK=1000 ile iste)"
( k6run burst >/tmp/p0701.k6 2>&1 ) & kpid=$!
best=0; worst=0
for i in $(seq 1 30); do
  cur=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || true
  des=$(kubectl -n "$NS" get hpa redirect -o jsonpath='{.status.desiredReplicas}' 2>/dev/null) || true
  (( ${cur:-0} > best )) && best=${cur:-0}
  sleep 2
done
wait $kpid || true
sleep 10
fr=$(k6_failed_rate); e5=$(k6_5xx)
peak_p99=$(promq "max_over_time(histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[30s])) by (le))[5m:15s])")
peak_desired=$(promq "max_over_time(kube_horizontalpodautoscaler_status_desired_replicas{namespace=\"$NS\",horizontalpodautoscaler=\"redirect\"}[5m:15s])")
now_ready=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.status.readyReplicas}') || true
grafana_hint "09 · Autoscaling → 'Otomatik ölçekleyici: istenen / mevcut pod' + 'İstek / sn ve pod sayısı' · 02 · App RED → 'p99 süre (uç noktaya göre)'"
note "burst sırasında: tepe hazır replika=$best · HPA tepe istek=${peak_desired%%.*} · şimdi=${now_ready:-?}"
note "tepe p99=$(awk -v v="$peak_p99" 'BEGIN{printf "%.0f", v*1000}') ms · 5xx=$e5 · k6 failed=$fr"
note "Zincir: metrics-server (15 sn) → HPA döngüsü (15 sn) → schedule → imaj → başlangıç → readiness."
note "Bu zincir 5 saniyede tepeye çıkıp 20 saniye süren bir burst'ten yavaştır: pod'lar yük BİTTİKTEN sonra gelir."
note "Doğru araçlar: (a) minReplicas'ı tabanı karşılayacak kadar yüksek tut, (b) scaleUp'ı hızlandır,"
note "(c) asıl önemlisi: burst'ü YUTACAK bir tampon bırak — otomatik ölçekleme burst için değil,"
note "TREND için tasarlanmıştır. Ani yük bir kapasite sorunudur, bir otomasyon sorunu değil."
# NaN KORUMASI: histogram_quantile boş pencerede NaN döner ve awk'ta her karşılaştırma yanlış
# çıkar — script "burst etkisiz" der. Tepe ~25 sn sürüyor, uygulama metrikleri 10 sn'de bir
# kazınıyor: `[30s]`lık pencere tepeyi ancak birkaç örnekle görür, boş da kalabilir. O yüzden karar yalnızca p99'a değil, k6'nın KENDİ gördüğü hata oranına
# da bakar: yükün kendisi de bir ölçüm kaynağıdır.
[[ "$peak_p99" == "NaN" || -z "$peak_p99" ]] && peak_p99=0
awk -v p="$peak_p99" -v f="$fr" -v e="$e5" 'BEGIN{exit !(p > 0.05 || f > 0.02 || e > 0)}' \
  && reproduced "burst sırasında p99 $(awk -v v="$peak_p99" 'BEGIN{printf "%.0f", v*1000}') ms'e çıktı; HPA ${peak_desired%%.*} replika istedi ama zamanında yetişemedi"
not_reproduced "burst latency'yi bozmadı (tepe p99 $(awk -v v="$peak_p99" 'BEGIN{printf "%.0f", v*1000}') ms, 5xx=$e5, failed=$fr) — PEAK'i artırıp tekrar dene"
