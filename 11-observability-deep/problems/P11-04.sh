#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-04 · Eşik alarmı vs burn-rate alarmı: aynı olay, iki farklı tepki
# 30 saniyelik bir hata sıçraması: eşik alarmı çalar (ve sen uyanırsın), burn-rate alarmı SUSAR
# (çünkü 30 günlük bütçenin anlamlı bir kısmı harcanmadı). Tersine, günlerce süren %0.2'lik bir
# kanama: eşik alarmı hiç çalmaz, burn-rate ticket açar. Alarm yorgunluğu bir insan sorunu değil,
# bir MATEMATİK seçimi sorunudur.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Tanımlı alarmlar"
curl -sG "$PROM_URL/api/v1/rules" 2>/dev/null \
  | jq -r '.data.groups[]?.rules[]? | select(.type=="alerting") | select(.name|test("Linkly")) | "    \(.name) [\(.labels.severity // "-")]"' 2>/dev/null | sort -u
step "Kısa bir hata sıçraması üret (~30 sn)"
chaos_apply pg-loss-50
( k6run mixed --vus 20 --duration 35s >/dev/null 2>&1 || true )
"$LADDER_ROOT/platform/lib/chaos.sh" delete pg-loss-50 >/dev/null 2>&1 || true
note "sıçrama bitti, alarmlar değerlendiriliyor..."
sleep 45
step "Hangi alarm ateşledi?"
curl -sG "$PROM_URL/api/v1/alerts" 2>/dev/null \
  | jq -r '.data.alerts[]? | select(.labels.alertname|test("Linkly")) | "    \(.labels.alertname) → \(.state) [\(.labels.severity // "-")]"' 2>/dev/null | sort -u
naive=$(promq 'count(ALERTS{alertname="LinklyNaiveErrorRateThreshold",alertstate=~"pending|firing"}) or vector(0)')
fast=$(promq 'count(ALERTS{alertname="LinklyRedirectErrorBudgetBurnFast",alertstate="firing"}) or vector(0)')
budget=$(promq 'slo:period_error_budget_remaining:ratio{sloth_slo="redirect-availability"}')
grafana_hint "12 · SLO → 'burn rate 1h / 6h' + 'error budget remaining' + 'Alarmlar (firing)'"
note "naive eşik alarmı: ${naive%%.*} · hızlı burn-rate alarmı: ${fast%%.*}"
note "kalan hata bütçesi: $(awk -v v="$budget" 'BEGIN{printf "%.2f%%", v*100}')"
note "Okuma: kısa bir sıçrama, 30 GÜNLÜK bütçenin küçük bir kısmını harcar — uyandırmayı hak etmez."
note "Burn-rate alarmının iki penceresi de aynı anda aşılmalı: uzun pencere 'yeterince büyük mü?',"
note "kısa pencere 'HÂLÂ oluyor mu?' diye sorar. Biri olmadan diğeri ya geç çalar ya geç susar."
note "Kural: alarm, EYLEM gerektirmiyorsa alarm değildir. Eylem gerektiren şey bütçenin tükenme"
note "HIZIDIR, anlık hata oranı değil."
{ awk -v n="${naive%%.*}" -v f="${fast%%.*}" 'BEGIN{exit !(n >= f)}'; } \
  && reproduced "kısa sıçramada naive eşik (${naive%%.*}) burn-rate'ten (${fast%%.*}) daha gürültülü — alarm yorgunluğunun kaynağı"
not_reproduced "alarm farkı ölçülemedi (kurallar yüklendi mi? kubectl -n $NS get prometheusrule)"
