#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-03 · X-Forwarded-For: iki yanlış yoldan biri limiti ETKİSİZ, diğeri ADALETSİZ yapar
#   (a) TRAP_IGNORE_XFF   → herkes ingress'in IP'sinde tek kovada: bir kötü client herkesi limitler
#   (b) TRAP_TRUST_ANY_XFF → client kendi kovasını seçer: limit isteğe bağlı hâle gelir
# Doğrusu: SAĞDAN, kendi proxy sayın kadar geri say. Bu, kendi topolojini bilmeni gerektirir.
limits_enforced   # bu script limiter'ı sınıyor — yük girişi ve muafiyet jetonu KULLANILMAZ
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
need_metric ratelimit_decisions_total "limiter Redis'e bağlı mı? (08 deploy/redirect-svc.yaml)"
rpod=$(dep_pod app.kubernetes.io/name=redis) || exit 2

# TOPOLOJİ: k6 = güvenilir yük dengeleyici, uygulamaya "önümde İKİ proxy var" denir.
# EN: every k6 virtual user comes from ONE machine, so with the deployed TRUSTED_PROXY_HOPS=1 the
#     app correctly sees one client and the correct mode and TRAP_IGNORE_XFF are indistinguishable
#     (one bucket either way). abuser.js therefore plays the load balancer in front of the ingress:
#     it writes each simulated client's address as the last entry it controls (abuser 203.0.113.66
#     with a fresh fake in front, normal 198.51.100.<n>) and the app is told there are two proxies of
#     ours (the LB and ingress-nginx). Real traffic from real addresses behaves exactly like this.
#     Comparing raw 429 counts between modes (`a429 != d429`) proves nothing, since any run-to-run
#     noise satisfies it; the verdict rests on WHICH buckets the limiter created and on who got
#     limited.
# TR: k6'nın her sanal kullanıcısı TEK bir makineden gelir; yayındaki TRUSTED_PROXY_HOPS=1 ile
#     uygulama doğru olarak tek bir client görür ve doğru mod ile TRAP_IGNORE_XFF ayırt edilemez
#     (ikisinde de tek kova). Bu yüzden abuser.js ingress'in önündeki yük dengeleyiciyi oynar: her
#     sanal client'ın adresini kendi yazdığı son girdi olarak koyar (kötü 203.0.113.66 ve önünde her
#     seferinde yeni bir sahte; normal 198.51.100.<n>) ve uygulamaya iki proxy'miz olduğu söylenir
#     (yük dengeleyici ve ingress-nginx). Gerçek adreslerden gelen gerçek trafik de tam böyle davranır.
#     Modlar arasında ham 429 sayılarını karşılaştırmak (`a429 != d429`) hiçbir şey kanıtlamaz;
#     koşudan koşuya her gürültü bunu sağlar. Hüküm limiter'ın HANGİ kovaları açtığına ve KİMİN
#     sınırlandığına dayanır.
orig_hops=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="TRUSTED_PROXY_HOPS")]}{.value}{end}' 2>/dev/null) || true
if [[ -n "$orig_hops" ]]; then on_cleanup "setenv "$(wl redirect)" TRAP_IGNORE_XFF- TRAP_TRUST_ANY_XFF- TRUSTED_PROXY_HOPS=$orig_hops"
else on_cleanup "setenv "$(wl redirect)" TRAP_IGNORE_XFF- TRAP_TRUST_ANY_XFF- TRUSTED_PROXY_HOPS-"; fi
win=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_WINDOW")]}{.value}{end}' 2>/dev/null) || true
WIN_S=${win:-10s}; WIN_S=${WIN_S%s}
proxy_ips=$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}' 2>/dev/null) || true

# IP limiter'ının ret sayısı — redirect pod'larının KENDİ sayacı (her faz yeni pod'larla başlar).
ip_rejects() {
  local p s=0 v
  for p in $(kubectl -n "$NS" get pods -l "$APP_SELECTOR" --field-selector=status.phase=Running \
               -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true); do
    v=$({ kubectl --request-timeout=5s -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$p:8080/proxy/metrics" 2>/dev/null || true; } \
          | awk '/^ratelimit_decisions_total\{/ && /decision="reject"/ && /key_type="ip"/ {s += $2} END {print s + 0}')
    s=$(awk -v a="$s" -v b="$v" 'BEGIN{print a + b}')
  done
  echo "$s"
}
# Limiter'ın bu fazda AÇTIĞI IP kovaları: Redis'teki `rl:ip:<adres>:<pencere>` anahtarları.
# Kova, limiter'ın "bu client kim?" sorusuna verdiği cevabın ta kendisidir.
ip_buckets() {   # ip_buckets <faz başlangıcı (epoch)> → tekil adres listesi
  # Başlangıç penceresini ATLA: önceki fazın son anahtarları aynı pencereye düşmüş olabilir.
  local b0=$(( $1 / WIN_S + 1 ))
  { kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli --scan --pattern 'rl:ip:*' 2>/dev/null || true; } \
    | awk -F: -v b0="$b0" '$NF + 0 >= b0 {ip = $0; sub(/^rl:ip:/, "", ip); sub(/:[0-9]+$/, "", ip); print ip}' | sort -u
}
# Kovaları sınıfla: kötü client'ın gerçek adresi, normal client'lar, sahte adresler, ingress'in adresi.
classify() {   # classify <adres listesi> → "kötü normal sahte ingress"
  printf '%s\n' "$1" | awk -v px=" $proxy_ips " '
    $0 == "203.0.113.66" {ab++; next}
    /^198\.51\.100\./ {nm++; next}
    /^198\.1[89]\./ {fk++; next}
    $0 != "" && index(px, " " $0 " ") {pr++}
    END {printf "%d %d %d %d", ab, nm, fk, pr}'
}
phase() {   # phase <ad> → "normal_sınırlanan_oranı ip_ret kötü normal sahte ingress"
  settle_rollout "$(wl redirect)"
  local t0 r0 r1 nl b
  t0=$(date +%s); r0=$(ip_rejects)
  k6run abuser --duration 40s >/dev/null 2>&1 || true
  r1=$(ip_rejects); b=$(ip_buckets "$t0")
  nl=$(_k6q '.metrics.normal_client_limited.value // 0')
  echo "$nl $(awk -v a="$r0" -v b="$r1" 'BEGIN{printf "%d", b - a}') $(classify "$b")"
}
pct() { awk -v v="$1" 'BEGIN{printf "%.0f", v * 100}'; }

step "(0) DOĞRU: sağdan 2 hop (yük dengeleyici + ingress)"
setenv "$(wl redirect)" TRUSTED_PROXY_HOPS=2 >/dev/null
read -r d_nl d_rej d_ab d_nm d_fk d_pr <<< "$(phase dogru)"
note "doğru: normal client'ın sınırlanan payı %$(pct "$d_nl") · IP reddi $d_rej · kovalar: kötü=$d_ab normal=$d_nm sahte=$d_fk ingress=$d_pr"
step "(a) TRAP_IGNORE_XFF: soket adresi → herkes ingress'in adresinde"
setenv "$(wl redirect)" TRAP_IGNORE_XFF=true >/dev/null
read -r a_nl a_rej a_ab a_nm a_fk a_pr <<< "$(phase ignore)"
note "ignore-xff: normal client'ın sınırlanan payı %$(pct "$a_nl") · IP reddi $a_rej · kovalar: kötü=$a_ab normal=$a_nm sahte=$a_fk ingress=$a_pr"
step "(b) TRAP_TRUST_ANY_XFF: ilk girdiye güven → kovayı client seçer"
setenv "$(wl redirect)" TRAP_IGNORE_XFF- TRAP_TRUST_ANY_XFF=true >/dev/null
read -r b_nl b_rej b_ab b_nm b_fk b_pr <<< "$(phase trust)"
note "trust-any-xff: normal client'ın sınırlanan payı %$(pct "$b_nl") · IP reddi $b_rej · kovalar: kötü=$b_ab normal=$b_nm sahte=$b_fk ingress=$b_pr"
grafana_hint "10 · Rate limit → 'Kararlar (anahtar türüne göre)' + 'Normal ve kötü niyetli kullanıcının gecikmesi (k6)' · 15 · k6 → 'Dönen durum kodları'"
note "Özet: (a) limiti ADALETSİZ yapar (masumlar cezalanır), (b) limiti ETKİSİZ yapar (suçlu kaçar)."
note "İkisi de 'XFF'i okuduk' diye rapor edilir; fark, HANGİ girdiyi okuduğundadır."
note "Kural: güven sınırını yaz. Kaç proxy'n var? Hangisi senin? Header'ın geri kalanı VERİDİR, kanıt değil."
note "Birim test karşılığı: internal/httpapi/clientip_test.go · kovalar: redis-cli --scan --pattern 'rl:ip:*'"
# ÖLÇÜM ÖN KOŞULU: doğru modda kötü ve normal client AYRI kovalarda olmalı. Değilse XFF uygulamaya
# ulaşmıyor (ingress ConfigMap'i uygulanmamış) ve üç mod aynı tek kovayı ölçer — hüküm verilemez.
if (( d_ab < 1 || d_nm < 1 )); then
  warn "ölçüm yapılamadı: doğru modda client'lar ayrı kovalara düşmedi (kötü=$d_ab normal=$d_nm) — X-Forwarded-For uygulamaya ulaşmıyor."
  warn "ingress ayarı: make -C \"$LADDER_ROOT/platform\" core (platform/manifests/ingress-nginx-config.yaml)"
  exit 2
fi
if (( d_rej <= 0 )); then
  warn "ölçüm yapılamadı: doğru modda bile kötü client IP limitine takılmadı — yük limiti aşmıyor."
  exit 2
fi
# (a) ADALETSİZ: herkes ingress'in adresinde tek kovada VE normal client belirgin biçimde cezalanıyor.
unfair=0; ineffective=0
if (( a_pr >= 1 && a_ab == 0 && a_nm == 0 )) && awk -v a="$a_nl" -v d="$d_nl" 'BEGIN{exit !(a >= 0.2 && a >= d + 0.15)}'; then unfair=1; fi
# (b) ETKİSİZ: kötü client her istekte yeni bir kova açtı VE IP limiti neredeyse hiç reddetmedi.
if (( b_fk >= 20 && b_ab == 0 && b_rej * 10 <= d_rej )); then ineffective=1; fi
if (( unfair && ineffective )); then
  reproduced "ignore-xff: tek kova (ingress'in adresi), normal client'ın %$(pct "$a_nl")'i sınırlandı (doğru modda %$(pct "$d_nl")) · trust-any-xff: kötü client $b_fk sahte kova açtı, IP reddi $d_rej → $b_rej"
fi
(( unfair )) || note "(a) görülmedi: ingress kovası=$a_pr, normal client sınırlanan %$(pct "$a_nl") (doğru modda %$(pct "$d_nl"))"
(( ineffective )) || note "(b) görülmedi: sahte kova=$b_fk, IP reddi $d_rej → $b_rej"
not_reproduced "XFF yorumu limiter'ın kovalarını ya da kimin sınırlandığını beklendiği gibi değiştirmedi"
