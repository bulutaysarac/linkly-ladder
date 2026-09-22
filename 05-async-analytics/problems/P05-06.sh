#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P05-06 · TRAP_REDIRECT_301: tarayıcı önbelleği, SAYILAMAYAN tıklama üretir
# 01'de P00-10'u "önbellek kontrolü sende değil" diye çözmüştük. Aynı hata 05'te FARKLI bir zarar
# veriyor: artık tıklamaları ciddi ciddi sayıyoruz ve 301, tıklamaların sunucuya hiç ulaşmamasına
# yol açıyor. Aynı bug, farklı seviyede farklı sonuç — düzeltmelerin neden geri gelmemesi gerektiğinin kanıtı.
ensure_healthy
on_cleanup "setenv "$(app_workload)" TRAP_REDIRECT_301-"
step "Varsayılan (302 + no-store): aynı client'tan N tıklama"
code=$(create_link "https://example.com/counted")
N=${N:-50}
# curl her istekte yeni bağlantı açar ve önbellek tutmaz → sunucu hepsini görür
for i in $(seq 1 $N); do status_of "$code" >/dev/null; done
sleep 5
c302=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0') || true
st302=$(status_of "$code"); cc=$(header_of "$code" Cache-Control)
note "302 modunda: durum=$st302 · Cache-Control='${cc:-<yok>}' · sayılan tıklama=$c302 / $N"
step "Tuzağı aç: 301 (Cache-Control yok)"
setenv "$(app_workload)" TRAP_REDIRECT_301=true >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
code2=$(create_link "https://example.com/uncounted")
st301=$(status_of "$code2"); cc2=$(header_of "$code2" Cache-Control)
note "301 modunda: durum=$st301 · Cache-Control='${cc2:-<yok>}'"
note "curl önbellek tutmadığı için burada sayım düşmez — ama TARAYICI tutar."
warn "Elle doğrula: Chrome'da http://${BASE_URL#http://}/$code2 adresini 5 kez aç,"
warn "sonra stats'a bak: yalnızca 1 tıklama görürsün. Kalan 4'ü '(disk cache)' olarak servis edildi."
note "Zarar zinciri: 301 → tarayıcı önbelleği → sunucuya ulaşmayan istek → sayılamayan tıklama →"
note "yanlış analitik → yanlış iş kararı. Üstelik linki silsen bile yönlendirme devam eder (P00-10)."
# Kanıt "Cache-Control BOŞ" değil, "saklamayı YASAKLAMIYOR" olmalı: araya giren bir katman
# (ingress, CDN) başlık ekleyebilir ve boşluk kontrolü yanlış negatif verir. RFC 7234'e göre 301,
# açık bir yasak yoksa sezgisel olarak ÖNBELLEKLENEBİLİR — ölçtüğümüz şey tam olarak bu.
storable=1
printf '%s' "${cc2:-}" | grep -qiE 'no-store|no-cache|max-age=0' && storable=0
{ [[ "$st301" == 301 ]] && (( storable == 1 )); } \
  && reproduced "301 + saklamayı yasaklamayan Cache-Control ('${cc2:-<yok>}'): tarayıcı önbelleği tıklamaları görünmez kılıyor (302 modunda $c302/$N sayılmıştı)"
not_reproduced "yönlendirme 302 + no-store — tıklamalar sunucuya ulaşıyor"
