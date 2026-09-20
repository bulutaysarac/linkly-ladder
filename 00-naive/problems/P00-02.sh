#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-02 · Restart = tüm linkler kaybolur (bellek içi store)
ensure_healthy
step "Link oluştur, pod'u sil, aynı kodu iste"
code=$(create_link "https://example.com/persist-test")
# Ön koşulu KANITLA: silmeden önce link gerçekten çalışıyor olmalı, yoksa "kayboldu" iddiası boş.
for _ in $(seq 1 10); do pre=$(status_of "$code"); [[ "$pre" == 30* ]] && break; sleep 2; done
note "oluşturulan kod: $code → silmeden önce GET: $pre"
[[ "$pre" == 30* ]] || { warn "ön koşul sağlanamadı (link baştan çalışmıyor) — deney geçersiz"; exit 2; }
need_confirm "pod silinecek"
kubectl -n "$NS" delete pod -l app.kubernetes.io/name=linkly --wait=true >/dev/null
wait_ready
for _ in $(seq 1 20); do serving && break; sleep 2; done
wait_endpoints "$(replicas_of)"
st=$(status_of "$code")
grafana_hint "03 · App Business → 'links_total' (restart'ta sıfırlanır)"
note "restart sonrası GET /$code → $st"
[[ "$st" == 404 ]] && reproduced "link kayboldu (404) — durum süreç belleğinde"
not_reproduced "link hayatta kaldı ($st) — kalıcı store var (02)"
