#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-08 · Tıklama sayacı hâlâ istek yolunda ve bellekte
# Her redirect, yanıtı döndürmeden ÖNCE paylaşılan bir sayacı kilit altında artırıyor. Bugün ucuz
# (bellek + mutex), yarın değil: 02'de bu bir DB satır kilidine dönüşecek (P02-08) ve hot link'te
# redirect gecikmesini sayaç belirleyecek. Ayrıca sayaç, süreçle birlikte ölüyor.
ensure_healthy
code=$(create_link "https://example.com/counter")
step "Aynı koda 300 tıklama, sonra sayacı oku"
for i in $(seq 1 300); do status_of "$code" >/dev/null; done
clicks=$(curl -s "$BASE_URL/api/links/$code" | jq -r .clicks) || true
note "kaydedilen tıklama: $clicks / 300"
step "Yazma, okuma yolunun İÇİNDE mi? Hot key ile p99'a bak"
k6run hot-key --vus 50 --duration 30s >/dev/null 2>&1 || true
sleep 12
p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
note "hot-key yükünde redirect p99: $(awk -v v="$p99" 'BEGIN{printf "%.1f", v*1000}') ms"
step "Pod'u yeniden başlat: sayaç hayatta kalıyor mu?"
need_confirm "pod yeniden başlatılacak"
kubectl -n "$NS" delete pod -l "$APP_SELECTOR" --wait=true >/dev/null; wait_ready
for _ in $(seq 1 20); do serving && break; sleep 2; done
after=$(curl -s "$BASE_URL/api/links/$code" | jq -r '.clicks // "link yok"') || true
grafana_hint "02 · App RED → 'p99 by route' (/{code}) · 03 · App Business → 'redirect ok/s'"
note "restart sonrası tıklama: $after"
note "Çözüm yönü: tıklamayı istek yolundan ÇIKAR (05: bounded kuyruk + batch) ve dayanıklı yaz (06: olay akışı)."
[[ "$after" == "link yok" || "$after" == "0" ]] && reproduced "300 tıklamanın tamamı kayboldu; sayaç istek yolunda ve süreç belleğinde"
not_reproduced "tıklamalar kalıcı — analitik süreç dışına taşınmış (05/06)"
