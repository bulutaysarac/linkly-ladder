#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-08 · Bellek sınırsız büyür → OOMKilled
#
# ÖLÇÜM NOTU: yükü TEK VU ile veriyoruz (P00-01 maskelemesi). Paralel istekte süreç önce eşzamanlı
# map yazımından çöker; o zaman "OOM mu oldu, crash mi?" ayırt edilemez — nitekim ilk denemede
# reason=Error (crash) görünürken working set 3 MB'taydı. Tek VU'da yarış yok: yalnızca bellek büyür.
# Ayrım: reason=OOMKilled → bu sorun · reason=Error → P00-01.
ensure_healthy
ensure_fresh_pod
pod=$(pod_name)
lim=$(kubectl -n "$NS" get deploy linkly -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
step "Uzun URL'lerle sürekli link üret (tek akış), working set'i limite doğru izle"
note "konteyner bellek limiti: $lim — store'da eviction yok, TTL yok, üst sınır yok"
note "başlangıç working set: $(working_set_mb) MB"
URL_SIZE=${URL_SIZE:-4000} k6run create --vus 1 --duration "${DURATION:-120s}" || true
sleep 10
ws=$(working_set_mb); peak=$(peak_working_set_mb 10m); reason=$(last_reason); after=$(restarts_of "$pod"); oom=false
[[ "$reason" == *OOMKilled* ]] && oom=true
# lastState boşsa (pod yeniden yaratıldıysa) deployment olaylarına da bak
kubectl -n "$NS" get events --field-selector reason=OOMKilling -o name 2>/dev/null | grep -q . && oom=true
grafana_hint "01 · Pods & Resources → 'Bellek working set' (limit çizgisi) + 'Son sonlanma nedeni'"
note "örneklenen tepe: ${peak} MB (limit $lim) · şu an: ${ws} MB · restart: 0 → ${after:-?} · son sonlanma: ${reason:-yok} (exit $(exit_code_of "$pod"))"
note "Örneklenen tepe limitin ALTINDA görünebilir: Prometheus 15 sn'de bir bakıyor, konteyner iki örnek arasında dolup ölüyor. Asıl kanıt OOMKilled + exit 137'dir."
if [[ "$oom" == true ]]; then
  reproduced "bellek limiti ($lim) aşıldı → OOMKilled; konteyner öldü ve P00-02 gereği TÜM linkler gitti"
fi
if [[ "$reason" == *Error* ]]; then
  warn "reason=Error → bu bir OOM değil, P00-01 çökmesi. Ölçüm kirlendi; DURATION'ı artırıp tekrar dene."
  not_reproduced "OOM yerine crash gözlendi (P00-01). Bu turda P00-08 kanıtlanamadı"
fi
note "Store hiç küçülmüyor: tepe ${peak} MB'ın tamamı geri alınamaz — sadece süreç ölünce 'temizlenir'."
not_reproduced "bu sürede OOM olmadı (working set ${ws} MB / $lim). DURATION=240s URL_SIZE=8000 ile tekrar dene"
