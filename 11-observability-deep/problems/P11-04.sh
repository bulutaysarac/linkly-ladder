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
# SIÇRAMA, NAIVE EŞİĞİ AŞACAK KADAR HATA ÜRETMELİ.
# Naive kural `slo:sli_error:ratio_rate5m > 0.01` diyor ve `for:` yok — ama 35 sn'lik bir sıçrama
# 5 dakikalık oranı %1'in üstüne çıkarmaya yetmez: yalnızca YAVAŞ burn kuralı pending'e geçer,
# naive alarm hiç ateşlemez ve "naive daha gürültülü" iddiası sınanamaz. Bu yüzden sıçrama 90 sn
# (hâlâ 1s/6s burn pencerelerine göre KISA — anlatı bozulmaz) ve değerlendirme için kayıt
# kuralının birkaç aralığı beklenir.
# EN: the naive rule has no `for:`, but a 35s spike does not push the 5-minute ratio above 1% —
# only the SLOW burn rule goes pending, so the claim cannot be tested. 90s is still short
# relative to the 1h/6h burn windows, so the narrative holds.
step "Kısa bir hata sıçraması üret (~90 sn)"
chaos_apply pg-loss-50
( k6run mixed --vus 20 --duration "${SPIKE:-90}s" >/dev/null 2>&1 || true )
"$LADDER_ROOT/platform/lib/chaos.sh" delete pg-loss-50 >/dev/null 2>&1 || true
note "sıçrama bitti, alarmlar değerlendiriliyor..."
sleep 75
step "Hangi alarm ateşledi?"
curl -sG "$PROM_URL/api/v1/alerts" 2>/dev/null \
  | jq -r --arg ns "$NS" '.data.alerts[]? | select((.labels.alertname|test("Linkly")) and .labels.namespace == $ns) | "    \(.labels.alertname) → \(.state) [\(.labels.severity // "-")]"' 2>/dev/null | sort -u
# Kurallar `namespace` taşır (deploy/slo.yaml): 11-14 aynı adlı kuralları kurar, süzmeden
# sorulan sayı başka bir seviyenin alarmı olabilir.
# EN: rules carry `namespace`; filter on it — 11-14 define identically named rules.
naive=$(promq "count(ALERTS{alertname=\"LinklyNaiveErrorRateThreshold\",alertstate=~\"pending|firing\",namespace=\"$NS\"}) or vector(0)")
fast=$(promq "count(ALERTS{alertname=\"LinklyRedirectErrorBudgetBurnFast\",alertstate=\"firing\",namespace=\"$NS\"}) or vector(0)")
budget=$(promq "slo:period_error_budget_remaining:ratio{sloth_slo=\"redirect-availability\",namespace=\"$NS\"}")
grafana_hint "12 · SLO → 'Hata oranı (son 5 dk)' + 'Bütçe yanma hızı (1 sa / 6 sa)' + 'Kalan hata bütçesi' + 'Çalan alarmlar'"
note "naive eşik alarmı: ${naive%%.*} · hızlı burn-rate alarmı: ${fast%%.*}"
note "kalan hata bütçesi: $(awk -v v="$budget" 'BEGIN{printf "%.2f%%", v*100}')"
note "Okuma: kısa bir sıçrama, 30 GÜNLÜK bütçenin küçük bir kısmını harcar — uyandırmayı hak etmez."
note "Ama bu kümede Prometheus yalnızca 6 SAAT saklıyor: 'kalan bütçe' fiilen son 6 saatin hesabı."
note "Az trafikli bir laboratuvarda aynı sıçrama onu büyük ölçüde yiyebilir, sıfırın altına bile inebilir."
note "Burn-rate alarmının iki penceresi de aynı anda aşılmalı: uzun pencere 'yeterince büyük mü?',"
note "kısa pencere 'HÂLÂ oluyor mu?' diye sorar. Biri olmadan diğeri ya geç çalar ya geç susar."
note "Kural: alarm, EYLEM gerektirmiyorsa alarm değildir. Eylem gerektiren şey bütçenin tükenme"
note "HIZIDIR, anlık hata oranı değil."
# KARAR TUZAĞI: ">=" / "<=" iki taraf da 0 iken GEÇER.
# EN: "b >= a" is true when nothing was measured at all (0 >= 0). That turns a failed measurement
#     into a passing experiment — the loudest possible false positive, because it looks like proof.
#     Guard the comparison with "we actually measured something".
# TR: "b >= a", hiçbir şey ölçülmediğinde de doğrudur (0 >= 0). Yani başarısız bir ölçüm, GEÇEN
#     bir deneye dönüşür — mümkün olan en gürültülü yanlış pozitif, çünkü kanıt gibi görünür.
#     Karşılaştırmayı "gerçekten bir şey ölçtük mü?" koşuluyla koru.
#     Aynı sebeple ">=" de yetmez: naive == burn-rate iken İKİSİ DE AYNI KADAR gürültülüdür,
#     oysa hüküm "naive daha gürültülü" diyor. Farkı iddia ediyorsan farkı ölç.
# EN: ">=" is not enough either: when naive == burn-rate the two are equally noisy, yet the
#     verdict claims naive is noisier. If you assert a difference, measure one.
# HİÇBİR ALARM ATEŞLEMEDİYSE HÜKÜM YOK: karşılaştırılacak iki sayı da yoksa, "naive daha
# gürültülü değilmiş" demek alarm kuralları hakkında değil SIÇRAMA hakkında bir cümledir.
if awk -v n="${naive%%.*}" -v f="${fast%%.*}" 'BEGIN{exit !(n+0==0 && f+0==0)}'; then
  warn "ölçüm yapılamadı: sıçrama hiçbir alarmı tetiklemedi (naive=${naive%%.*}, hızlı=${fast%%.*})."
  warn "Hata oranı naive eşiğin (%1, 5 dk) altında kaldı; SPIKE'ı uzat: SPIKE=180 make repro P=P11-04"
  warn "Bu bir hüküm değil, EKSİK ÖLÇÜMdür."
  exit 2
fi
{ awk -v n="${naive%%.*}" -v f="${fast%%.*}" 'BEGIN{exit !(n > 0 && n > f)}'; } \
  && reproduced "kısa sıçramada naive eşik (${naive%%.*}) burn-rate'ten (${fast%%.*}) daha gürültülü — alarm yorgunluğunun kaynağı"
not_reproduced "alarm farkı ölçülemedi (kurallar yüklendi mi? kubectl -n $NS get prometheusrule)"
