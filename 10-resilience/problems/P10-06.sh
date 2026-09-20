#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-06 · Yük atma: kabul ettiğin istekleri HIZLI tutmak
# Sezgiye aykırı: erken reddetmek sistemi kabul ettiği istekler için HIZLANDIRIR. Yük atmadan
# aşırı yüklü bir sunucu her şeyi kabul eder ve her şeyi yavaş servis eder — herkes zaman aşımına
# uğrar, tekrar dener ve kimse cevap alamaz. Kısmi hizmet, tekdüze başarısızlıktan iyidir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/redirect SHED_ENABLED=true SHED_MAX_INFLIGHT=200"
run_overload() {
  kubectl -n "$NS" rollout status deploy/redirect --timeout=180s >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  k6run stairs >/dev/null 2>&1 || true
  sleep 10
  # Kabul edilen isteklerin p99'u (503'ler hariç) — asıl bakılacak sayı bu.
  local p99 shed
  p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",code!=\"503\"}[2m])) by (le))")
  shed=$(promq "sum(increase(load_shed_total{namespace=\"$NS\"}[4m]))")
  echo "$p99 ${shed%%.*}"
}
step "(1) Yük atma AÇIK (in-flight > 200 → hızlı 503)"
kubectl -n "$NS" set env deploy/redirect SHED_ENABLED=true SHED_MAX_INFLIGHT=60 >/dev/null
read -r p_on s_on <<< "$(run_overload)"
note "shedding açık: kabul edilenlerin p99=$(awk -v v="$p_on" 'BEGIN{printf "%.0f", v*1000}') ms · atılan=$s_on"
step "(2) Yük atma KAPALI: her şey kabul edilir"
kubectl -n "$NS" set env deploy/redirect SHED_ENABLED=false >/dev/null
read -r p_off s_off <<< "$(run_overload)"
note "shedding kapalı: kabul edilenlerin p99=$(awk -v v="$p_off" 'BEGIN{printf "%.0f", v*1000}') ms · atılan=$s_off"
grafana_hint "11 · Resilience → 'load shed/s' + 'kabul edilen isteklerin p99 (503 hariç)'"
note "Doğru metrik KABUL EDİLEN isteklerin p99'udur. Toplam p99'a bakarsan shedding 'kötü' görünür"
note "(çok 503 var); kabul edilenlere bakarsan iyi görünür (hızlı cevap). Hangi soruyu sorduğun,"
note "hangi cevabı alacağını belirler."
note "Yük atma bir KAPASİTE aracı değil, bir KALİTE aracıdır: kapasiteyi artırmaz, mevcut"
note "kapasitenin işe yarar kalmasını sağlar. Kapasite için ölçekleme (07) gerekir."
note "Sağlık uçları asla atılmaz (kodda ayrık): yük altında probe düşerse pod öldürülür (P01-07)."
awk -v a="$p_on" -v b="$p_off" 'BEGIN{exit !(a <= b)}' \
  && reproduced "yük atma, kabul edilen isteklerin p99'unu korudu ($(awk -v v="$p_on" 'BEGIN{printf "%.0f", v*1000}') ms vs $(awk -v v="$p_off" 'BEGIN{printf "%.0f", v*1000}') ms; $s_on istek atıldı)"
not_reproduced "fark ölçülemedi (yük yeterince yüksek değil — stairs PEAK'ini artır)"
