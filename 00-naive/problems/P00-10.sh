#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-10 · 301 + Cache-Control yok → tarayıcı kalıcı önbellekler; silinen link bile yönlendirir
ensure_healthy
step "Redirect yanıtının durum kodu ve önbellek başlıkları"
code=$(create_link "https://example.com/cacheable")
st=$(status_of "$code"); cc=$(header_of "$code" Cache-Control)
note "GET /$code → HTTP $st ; Cache-Control: '${cc:-<yok>}'"
step "Linki sil, sunucu ne diyor?"
curl -s -o /dev/null -XDELETE "$BASE_URL/api/links/$code"
after=$(status_of "$code")
note "DELETE sonrası curl (önbelleksiz client): $after"
warn "Tarayıcıda dene: http://${BASE_URL#http://}/$code adresini Chrome'da aç → DELETE et → tekrar aç."
warn "301 kalıcı önbelleklendiği için Chrome sunucuya HİÇ sormadan yönlendirmeye devam eder."
note "Sonuç: yönlendirmeyi geri alamazsın ve tıklamalar sayılmaz (P05-06 ile aynı kök)."
grafana_hint "03 · App Business → 'redirect ok/s' gerçek tıklamanın altında kalır"
{ [[ "$st" == 301 ]] && [[ -z "$cc" ]]; } && reproduced "301 + Cache-Control yok → önbellek kontrolü sende değil, silme etkisiz"
not_reproduced "302 + no-store (01)"
