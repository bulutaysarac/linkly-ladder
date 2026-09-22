#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-06 · Yük atma: kabul ettiğin istekleri HIZLI tutmak
# Sezgiye aykırı: erken reddetmek sistemi kabul ettiği istekler için HIZLANDIRIR. Yük atmadan
# aşırı yüklü bir sunucu her şeyi kabul eder ve her şeyi yavaş servis eder — herkes zaman aşımına
# uğrar, tekrar dener ve kimse cevap alamaz. Kısmi hizmet, tekdüze başarısızlıktan iyidir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" SHED_ENABLED=true SHED_MAX_INFLIGHT=200"
# YÜK ATMA ANCAK SİSTEM DOYDUĞUNDA GÖRÜNÜR — VE BU SİSTEM ÇOK HIZLI.
# In-flight ≈ rps × gecikme. Bu kümede redirect p99'u 2 ms; 400 rps'te in-flight ~1 kalıyor ve
# eşik 60'a çekilse bile HİÇ aşılmıyor (ölçüldü: iki fazda da atılan=0). Yani deney, ölçmek
# istediği doygunluk rejimini hiç kurmuyordu. Eşiği indirmek yetmez; isteklerin SÜRMESİ gerekir.
# Bağımlılığa 200 ms gecikme enjekte edilince in-flight ≈ 400 × 0.2 = 80 olur ve eşik anlam kazanır.
# EN: in-flight ≈ rps × latency. At 2 ms p99 the in-flight count stays around 1, so even a
# threshold of 60 is never crossed and nothing is ever shed — the experiment never built the
# saturation regime it wants to measure. Lowering the threshold is not enough; requests must TAKE
# time. A 200 ms dependency delay makes in-flight ≈ 80 and the threshold meaningful.
chaos_apply redis-delay-200ms
run_overload() {
  kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  settle_rollout "$(wl redirect)"
  k6run stairs >/dev/null 2>&1 || true
  sleep 10
  # Kabul edilen isteklerin p99'u (503'ler hariç) — asıl bakılacak sayı bu.
  local p99 shed
  p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",code!=\"503\"}[2m])) by (le))")
  shed=$(promq "sum(increase(load_shed_total{namespace=\"$NS\"}[4m]))")
  echo "$p99 ${shed%%.*}"
}
step "(1) Yük atma AÇIK (in-flight > ${SHED_TEST:-40} → hızlı 503)"
setenv "$(wl redirect)" SHED_ENABLED=true SHED_MAX_INFLIGHT="${SHED_TEST:-40}" >/dev/null
read -r p_on s_on <<< "$(run_overload)"
note "shedding açık: kabul edilenlerin p99=$(awk -v v="$p_on" 'BEGIN{printf "%.0f", v*1000}') ms · atılan=$s_on"
step "(2) Yük atma KAPALI: her şey kabul edilir"
setenv "$(wl redirect)" SHED_ENABLED=false >/dev/null
read -r p_off s_off <<< "$(run_overload)"
note "shedding kapalı: kabul edilenlerin p99=$(awk -v v="$p_off" 'BEGIN{printf "%.0f", v*1000}') ms · atılan=$s_off"
# DOYGUNLUK KURULAMADIYSA HÜKÜM YOK: hiçbir istek atılmadıysa karşılaştırılan iki p99 de yük
# atma hakkında değildir.
if (( ${s_on:-0} == 0 )); then
  warn "ölçüm yapılamadı: hiçbir istek atılmadı (eşik ${SHED_TEST:-40}, in-flight hiç aşılmadı)."
  warn "Sistem doymuyor: SHED_TEST'i düşür ya da gecikmeyi/yükü artır (RATES=... make repro P=P10-06)."
  warn "Bu bir hüküm değil, EKSİK ÖLÇÜMdür."
  exit 2
fi
grafana_hint "11 · Resilience → 'load shed/s' + 'kabul edilen isteklerin p99 (503 hariç)'"
note "Doğru metrik KABUL EDİLEN isteklerin p99'udur. Toplam p99'a bakarsan shedding 'kötü' görünür"
note "(çok 503 var); kabul edilenlere bakarsan iyi görünür (hızlı cevap). Hangi soruyu sorduğun,"
note "hangi cevabı alacağını belirler."
note "Yük atma bir KAPASİTE aracı değil, bir KALİTE aracıdır: kapasiteyi artırmaz, mevcut"
note "kapasitenin işe yarar kalmasını sağlar. Kapasite için ölçekleme (07) gerekir."
note "Sağlık uçları asla atılmaz (kodda ayrık): yük altında probe düşerse pod öldürülür (P01-07)."
# KARAR TUZAĞI: ">=" / "<=" iki taraf da 0 iken GEÇER.
# EN: "b >= a" is true when nothing was measured at all (0 >= 0). That turns a failed measurement
#     into a passing experiment — the loudest possible false positive, because it looks like proof.
#     Guard the comparison with "we actually measured something".
# TR: "b >= a", hiçbir şey ölçülmediğinde de doğrudur (0 >= 0). Yani başarısız bir ölçüm, GEÇEN
#     bir deneye dönüşür — mümkün olan en gürültülü yanlış pozitif, çünkü kanıt gibi görünür.
#     Karşılaştırmayı "gerçekten bir şey ölçtük mü?" koşuluyla koru.
awk -v a="$p_on" -v b="$p_off" -v s="${s_on%%.*}" 'BEGIN{exit !(a > 0 && b > 0 && s > 0 && a <= b)}' \
  && reproduced "yük atma, kabul edilen isteklerin p99'unu korudu ($(awk -v v="$p_on" 'BEGIN{printf "%.0f", v*1000}') ms vs $(awk -v v="$p_off" 'BEGIN{printf "%.0f", v*1000}') ms; $s_on istek atıldı)"
not_reproduced "fark ölçülemedi (yük yeterince yüksek değil — stairs PEAK'ini artır)"
