#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-01 · (devralınan P00-02) restart = tüm linkler gider — ama ARTIK GÖRÜNÜR
# 00'da bu kaybı ölçemiyordun bile (P00-09). 01'de links_total sayacı var: kaybı GRAFİKTE görüyorsun.
ensure_healthy
step "Bir avuç link oluştur ve links_total sayacını oku"
for i in $(seq 1 25); do create_link "https://example.com/persist/$i" >/dev/null; done
sleep 12   # Prometheus 10 sn'de bir topluyor
before_metric=$(promq "max(links_total{namespace=\"$NS\"})")
code=$(create_link "https://example.com/persist-canary")
note "links_total (restart öncesi): ${before_metric%%.*} · kanarya kodu: $code → $(status_of "$code")"
need_confirm "pod silinecek"
kubectl -n "$NS" delete pod -l "$APP_SELECTOR" --wait=true >/dev/null
wait_ready
for _ in $(seq 1 20); do serving && break; sleep 2; done
sleep 12
after_metric=$(promq "max(links_total{namespace=\"$NS\"})")
st=$(status_of "$code")
grafana_hint "03 · App Business → 'links_total' (restart'ta dikey düşüş) + 'redirect sonuçları' → not_found"
note "links_total: ${before_metric%%.*} → ${after_metric%%.*} · kanarya GET: $st"
note "01'in kazancı: kaybı ÖLÇEBİLİYORSUN. Ama kaybın kendisi duruyor — durum hâlâ süreç belleğinde."
[[ "$st" == 404 ]] && reproduced "restart tüm linkleri sildi (links_total ${before_metric%%.*} → ${after_metric%%.*}); mutex çökmeyi durdurdu ama kalıcılık getirmedi"
not_reproduced "link restart'tan sağ çıktı — kalıcı store var (02)"
