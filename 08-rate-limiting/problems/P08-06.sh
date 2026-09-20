#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-06 · Gürültülü komşu: kötü client, normal client'ın p99'unu bozuyor mu?
# Hız sınırının ASIL AMACI bu: kapasiteyi korumak değil, ADALETİ korumak. Sınır işe yarıyorsa,
# bir client'ın kötü davranışı diğerlerinin gecikmesine yansımamalı.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Kötü client (tek IP, açgözlü) + normal client'lar (dağıtık IP) aynı anda"
k6run abuser --duration 60s || true
sleep 12
normal_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
rej_ip=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\",key_type=\"ip\"}[3m]))")
rej_tn=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\",key_type=\"tenant\"}[3m]))")
allow=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"allow\"}[3m]))")
n429=$(k6_429); total=$(k6_reqs)
grafana_hint "10 · Rate limit → 'normal client p99 vs abuser' + 'decisions by key type'"
note "toplam istek=$total · 429=$n429 · izin=${allow%%.*}"
note "IP bazlı ret=${rej_ip%%.*} · kiracı bazlı ret=${rej_tn%%.*}"
note "genel redirect p99=$(awk -v v="$normal_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
note "k6 özeti 'normal client p99' satırını ayrıca basar (platform/k6/scenarios/abuser.js)."
note "Okuma: kötü client 429 yiyor, normal client'ın p99'u bozulmuyorsa sınır İŞİNİ YAPIYOR."
note "İki anahtarın rolü farklı: IP limiti tek bir saldırganı, kiracı limiti bir müşterinin TÜM"
note "altyapısını (birçok IP) sınırlar. Yalnızca IP'ye bakmak, dağıtık bir client'ı görmez."
note "Eksik kalan: farklı müşterilere farklı kotalar (tier). Onun için önce KİMLİK gerekir — 13."
awk -v r="${rej_ip%%.*}" 'BEGIN{exit !(r>0)}' \
  && reproduced "kötü client sınırlandı (IP bazlı ${rej_ip%%.*} ret, $n429/$total istek 429) — gürültülü komşu izole edildi"
not_reproduced "hiç ret olmadı — limit çok gevşek (RATE_LIMIT_PER_IP'yi düşürüp tekrar dene)"
