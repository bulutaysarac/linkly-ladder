#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-09 · Gözlemlenebilirlik sıfır: "kaç 404 döndü?" sorusu cevaplanamaz
ensure_healthy
step "Önce biraz trafik üret (30 redirect + 10 var olmayan kod)"
code=$(create_link "https://example.com/obs")
for i in $(seq 1 30); do status_of "$code" >/dev/null; done
for i in $(seq 1 10); do status_of "yoxxxxx" >/dev/null; done
step "/metrics ucu var mı?"
mcode=$(status_of "metrics")
note "GET /metrics → $mcode (00'da 404 bekleniyor)"
step "Prometheus'ta uygulama serileri var mı?"
absent_http=false; absent_redir=false
prom_absent "http_requests_total{namespace=\"$NS\"}" && absent_http=true
prom_absent "redirect_total{namespace=\"$NS\"}" && absent_redir=true
note "http_requests_total serisi: $([[ $absent_http == true ]] && echo YOK || echo var)"
note "redirect_total serisi:     $([[ $absent_redir == true ]] && echo YOK || echo var)"
note "Demin 10 tane 404 ürettik. Kaç tane olduğunu Prometheus'a soramıyorsun."
grafana_hint "02 · App RED ve 03 · App Business → 00'da tamamen BOŞ (sadece cAdvisor/KSM panelleri dolu)"
{ [[ "$absent_http" == true ]] && [[ "$mcode" == 404 ]]; } && reproduced "uygulama kör: /metrics yok, iş metriği yok — 404/p99/hata oranı ölçülemez"
not_reproduced "metrikler mevcut (01)"
