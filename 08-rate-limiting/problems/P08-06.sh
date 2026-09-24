#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-06 · Gürültülü komşu: kötü client, normal client'ın p99'unu bozuyor mu?
# Hız sınırının ASIL AMACI bu: kapasiteyi korumak değil, ADALETİ korumak. Sınır işe yarıyorsa,
# bir client'ın kötü davranışı diğerlerinin gecikmesine yansımamalı.
limits_enforced   # bu script limiter'ı sınıyor — yük girişi ve muafiyet jetonu KULLANILMAZ
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
rpod=$(dep_pod app.kubernetes.io/name=redis) || exit 2
# İZOLASYONU GÖSTERMEK İÇİN İKİ AYRI CLIENT GEREKİR — tek makineden koşan k6'da ikisi de aynı adrestir.
# EN: "any IP rejection happened" is not isolation. If every k6 client sits in ONE per-IP bucket
#     (ingress rewriting X-Forwarded-For, or one source address), the normal client is rejected
#     together with the abuser and such a verdict would still say "noisy neighbour isolated". As in
#     P08-03, abuser.js plays the trusted load balancer (each simulated client's address is the last
#     entry it writes) and the app is told there are two proxies of ours; the verdict requires the
#     abuser to be limited AND the normal client not to be.
# TR: "herhangi bir IP reddi oldu" izolasyon değildir. Bütün k6 client'ları TEK bir IP kovasındaysa
#     (ingress X-Forwarded-For'u eziyorsa ya da hepsi tek adresten geliyorsa) normal client da kötü
#     client'la birlikte reddedilir ve böyle bir hüküm yine "gürültülü komşu izole edildi" der.
#     P08-03'teki gibi abuser.js güvenilir yük dengeleyiciyi oynar (her sanal client'ın adresi
#     yazdığı son girdidir) ve uygulamaya iki proxy'miz olduğu söylenir; hüküm kötü client'ın
#     sınırlanmasını VE normal client'ın sınırlanMAMASINI birlikte ister.
orig_hops=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="TRUSTED_PROXY_HOPS")]}{.value}{end}' 2>/dev/null) || true
if [[ -n "$orig_hops" ]]; then on_cleanup "setenv "$(wl redirect)" TRUSTED_PROXY_HOPS=$orig_hops"
else on_cleanup "setenv "$(wl redirect)" TRUSTED_PROXY_HOPS-"; fi
win=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_WINDOW")]}{.value}{end}' 2>/dev/null) || true
WIN_S=${win:-10s}; WIN_S=${WIN_S%s}
step "Topoloji: k6 = güvenilir yük dengeleyici → TRUSTED_PROXY_HOPS=2"
setenv "$(wl redirect)" TRUSTED_PROXY_HOPS=2 >/dev/null
settle_rollout "$(wl redirect)"
step "Kötü client (açgözlü, sahte adres yazar) + normal client'lar (her biri kendi adresi) aynı anda"
t0=$(date +%s)
k6run abuser --duration 60s || true
# Limiter'ın açtığı IP kovaları (Redis'te rl:ip:<adres>:<pencere>): client'lar gerçekten ayrı mı?
buckets=$({ kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli --scan --pattern 'rl:ip:*' 2>/dev/null || true; } \
  | awk -F: -v b0=$(( t0 / WIN_S + 1 )) '$NF + 0 >= b0 {ip = $0; sub(/^rl:ip:/, "", ip); sub(/:[0-9]+$/, "", ip); print ip}' | sort -u)
has_ab=$(printf '%s\n' "$buckets" | count_lines '^203\.0\.113\.66$')
n_norm=$(printf '%s\n' "$buckets" | count_lines '^198\.51\.100\.')
normal_lim=$(_k6q '.metrics.normal_client_limited.value // 0')
abuser_lim=$(_k6q '.metrics.abuser_limited.value // 0')
normal_p99=$(_k6q '.metrics.normal_client_latency["p(99)"] // 0')
n429=$(k6_429); total=$(k6_reqs)
sleep 12
rej_ip=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\",key_type=\"ip\"}[2m]))")
rej_tn=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\",key_type=\"tenant\"}[2m]))")
grafana_hint "10 · Rate limit → 'Normal ve kötü niyetli kullanıcının gecikmesi (k6)' + 'Kararlar (anahtar türüne göre)'"
note "toplam istek=$total · 429=$n429 · IP bazlı ret=${rej_ip%%.*} · kiracı bazlı ret=${rej_tn%%.*}"
note "sınırlanan (429 ya da ingress 503): kötü client %$(awk -v v="$abuser_lim" 'BEGIN{printf "%.0f", v*100}') · normal client %$(awk -v v="$normal_lim" 'BEGIN{printf "%.1f", v*100}')"
note "normal client p99=$(awk -v v="$normal_p99" 'BEGIN{printf "%.1f", v}') ms · IP kovaları: kötü=$has_ab normal=$n_norm"
note "Okuma: kötü client 429 yiyor, normal client'ın istekleri geçiyorsa sınır İŞİNİ YAPIYOR."
note "İki anahtarın rolü farklı: IP limiti tek bir saldırganı, kiracı limiti bir müşterinin TÜM"
note "altyapısını (birçok IP) sınırlar. Yalnızca IP'ye bakmak, dağıtık bir client'ı görmez."
note "Eksik kalan: farklı müşterilere farklı kotalar (tier). Onun için önce KİMLİK gerekir — 13."
if (( has_ab < 1 || n_norm < 1 )); then
  warn "ölçüm yapılamadı: kötü ve normal client ayrı IP kovalarına düşmedi (kötü=$has_ab normal=$n_norm) — X-Forwarded-For uygulamaya ulaşmıyor."
  warn "ingress ayarı: make -C \"$LADDER_ROOT/platform\" core (platform/manifests/ingress-nginx-config.yaml)"
  exit 2
fi
if awk -v v="$normal_lim" 'BEGIN{exit !(v > 0.05)}'; then
  not_reproduced "normal client da sınırlandı (%$(awk -v v="$normal_lim" 'BEGIN{printf "%.1f", v*100}')) — kötü client'ın bedelini masumlar ödüyor, izolasyon yok"
fi
awk -v v="$abuser_lim" 'BEGIN{exit !(v >= 0.3)}' \
  && reproduced "gürültülü komşu izole edildi: kötü client'ın isteklerinin %$(awk -v v="$abuser_lim" 'BEGIN{printf "%.0f", v*100}')'i sınırlandı, normal client'ınkilerin %$(awk -v v="$normal_lim" 'BEGIN{printf "%.1f", v*100}')'i (p99 $(awk -v v="$normal_p99" 'BEGIN{printf "%.1f", v}') ms)"
not_reproduced "kötü client sınırlanmadı (%$(awk -v v="$abuser_lim" 'BEGIN{printf "%.0f", v*100}')) — limit çok gevşek (RATE_LIMIT_PER_IP'yi düşürüp tekrar dene)"
