#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-01 · Eşzamanlı map yazımı → süreç çöker
#
# ÖLÇÜM NOTU: restart sayacına güvenemeyiz. Pod bir kez CrashLoopBackOff'a düşünce kubelet'in geri çekilme
# süresi 5 dk'ya kadar çıkar; o pencerede sayaç DONAR ve "restart arttı mı?" yanlış negatif verir.
# Bu yüzden taze bir pod'la başlıyoruz ve asıl kanıtı Go runtime'ın ölüm mesajından alıyoruz.
ensure_fresh_pod
pod=$(pod_name); before=$(restarts_of "$pod")
step "50 VU ile 15 sn POST yağmuru — mutex'siz map'e eşzamanlı yazım"
note "taze pod: $pod (restart: $before)"
k6run create --vus 50 --duration 15s || true
step "Sonuç"
for _ in $(seq 1 15); do
  fatal_evidence "$pod" "concurrent map" && break
  sleep 2
done
after=$(restarts_of "$pod"); reason=$(last_reason)
serving && live="evet" || live="HAYIR (503)"
note "restart: $before → ${after:-?} ; son sonlanma nedeni: ${reason:-yok} ; uygulama ayakta mı: $live"
grafana_hint "01 · Pods & Resources → 'Restart sayısı' / 'Son sonlanma nedeni'"
if fatal_evidence "$pod" "concurrent map"; then
  note "Go runtime'ın ölüm mesajı:"; fatal_line "$pod" "concurrent map" | sed 's/^/    /'
  note "Bu hata recover() ile yakalanamaz: runtime tüm süreci öldürür, işlenmekte olan tüm istekler ölür."
  reproduced "süreç eşzamanlı map yazımından çöktü (restart ${before}→${after:-?})"
fi
(( ${after:-0} > before )) && reproduced "süreç $(( after - before )) kez yeniden başladı (reason=${reason:-Error})"
not_reproduced "çökme kanıtı yok ve restart artmadı — map korunuyor (01)"
