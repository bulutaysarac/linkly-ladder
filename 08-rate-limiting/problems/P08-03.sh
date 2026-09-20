#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-03 · X-Forwarded-For: iki yanlış yoldan biri limiti ETKİSİZ, diğeri ADALETSİZ yapar
#   (a) TRAP_IGNORE_XFF   → herkes ingress'in IP'sinde tek kovada: bir kötü client herkesi limitler
#   (b) TRAP_TRUST_ANY_XFF → client kendi kovasını seçer: limit isteğe bağlı hâle gelir
# Doğrusu: SAĞDAN, kendi proxy sayın kadar geri say. Bu, kendi topolojini bilmeni gerektirir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/redirect TRAP_IGNORE_XFF- TRAP_TRUST_ANY_XFF-"
apply_and_measure() {
  kubectl -n "$NS" rollout status deploy/redirect --timeout=180s >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  k6run abuser --duration 40s >/dev/null 2>&1 || true
  sleep 10
  local n429 total
  n429=$(k6_429); total=$(k6_reqs)
  echo "$n429 $total"
}
step "(0) DOĞRU yapılandırma: sağdan 1 hop"
read -r d429 dtot <<< "$(apply_and_measure)"
dnorm=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\",key_type=\"ip\"}[3m]))")
note "doğru: $dtot istekten $d429'u 429 · IP bazlı ret=${dnorm%%.*}"
step "(a) TRAP_IGNORE_XFF: XFF yok sayılıyor → herkes tek kovada"
kubectl -n "$NS" set env deploy/redirect TRAP_IGNORE_XFF=true >/dev/null
read -r a429 atot <<< "$(apply_and_measure)"
buckets_a=$(promq "count(count by (key_type) (ratelimit_decisions_total{namespace=\"$NS\"}))")
note "ignore-xff: $atot istekten $a429'u 429 — normal client'lar da abuser ile aynı kovada"
step "(b) TRAP_TRUST_ANY_XFF: client'ın yazdığına güven → kova seçimi client'ta"
kubectl -n "$NS" set env deploy/redirect TRAP_IGNORE_XFF- TRAP_TRUST_ANY_XFF=true >/dev/null
read -r b429 btot <<< "$(apply_and_measure)"
note "trust-any-xff: $btot istekten $b429'u 429 — abuser her istekte farklı IP yazarsa HİÇ limitlenmez"
grafana_hint "10 · Rate limit → 'decisions by key type' + 'normal client p99 vs abuser'"
note "Özet: (a) limiti ADALETSİZ yapar (masumlar cezalanır), (b) limiti ETKİSİZ yapar (suçlu kaçar)."
note "İkisi de 'XFF'i okuduk' diye rapor edilir; fark, HANGİ girdiyi okuduğundadır."
note "Kural: güven sınırını yaz. Kaç proxy'n var? Hangisi senin? Header'ın geri kalanı VERİDİR, kanıt değil."
note "Birim test karşılığı: internal/httpapi/clientip_test.go"
{ (( a429 != d429 )) || (( b429 != d429 )); } \
  && reproduced "XFF yorumu limiti değiştirdi: doğru=$d429/$dtot · ignore=$a429/$atot · trust-any=$b429/$btot (429 sayıları)"
not_reproduced "üç modda da aynı sonuç (yük profili ayırt edici değil — abuser senaryosunu kontrol et)"
