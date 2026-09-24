#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P12-05 · Canary + önbellek anahtarı değişimi: iki sürüm AYNI paylaşılan duruma yazıyor
# Canary'nin sessiz varsayımı: iki sürüm yan yana çalışabilir. Paylaşılan durum söz konusu
# olduğunda bu varsayım kırılır. Yeni sürüm önbellek anahtar formatını değiştirirse, canary
# (1 pod, ~%25) ile stable (3 pod) AYNI Redis'e farklı formatlarda yazar: iki taraf da sürekli ıska alır ve
# "önbellekli" bir sistem aniden önbelleksiz davranır.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Mevcut önbellek anahtar formatı"
rpod=$(dep_pod app.kubernetes.io/name=redis) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
keys=$(kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli --scan --pattern 'linkly:link:*' 2>/dev/null | head -3) || true
note "örnek anahtarlar:"; echo "${keys:-<yok>}" | sed 's/^/      /'
prefixes=$(kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli --scan --pattern 'linkly:*' 2>/dev/null | sed 's/:[^:]*$//' | sort -u | head -5) || true
note "farklı önek sayısı: $(echo "$prefixes" | grep -c . )"
step "Senaryo: canary anahtar önekini 'linkly:link:v2:' yapsaydı ne olurdu?"
k6run redirect --vus 20 --duration 30s >/dev/null 2>&1 || true
sleep 10
hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\",result=\"hit\"}[2m])) / clamp_min(sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\"}[2m])),0.001)")
note "şu anki hit oranı: $(awk -v v="$hit" 'BEGIN{printf "%.0f%%", v*100}')"
note "İki format bir arada olsaydı: canary'nin yazdığını stable okuyamaz, stable'ınkini canary"
note "okuyamazdı. Hit oranı canary payıyla (burada pod sayısı: ~1/4) orantılı düşerdi ve DB yükü aynı oranda artardı."
note "Dahası: canary geri alınırsa v2 anahtarları TTL dolana kadar çöp olarak kalır (bellek)."
note "Kurallar (paylaşılan durumu olan her canary için):"
note "  1. Anahtar/şema formatı değişimi GERİYE UYUMLU olmalı (expand/contract'ın önbellek hâli)"
note "  2. Ya da yeni format yalnızca YAZILIR, okumada iki formata da bakılır (geçiş dönemi)"
note "  3. Ya da canary kendi önbelleğini kullanır (izole ama soğuk — P03-02'nin bedeli)"
note "Aynı akıl yürütme kuyruk mesaj formatı (P06-07) ve DB şeması (P12-02) için de geçerli:"
note "CANARY, PAYLAŞILAN HER DURUM İÇİN BİR UYUMLULUK SÖZLEŞMESİ GEREKTİRİR."
grafana_hint "04 · Cache → 'İsabet oranı (pod'a göre)' · 13 · Rollout → 'İstek / sn (sürüme göre)'"
awk -v v="$hit" 'BEGIN{exit !(v > 0)}' \
  && reproduced "tek anahtar formatıyla hit oranı $(awk -v v="$hit" 'BEGIN{printf "%.0f%%", v*100}'); format değişimi canary sırasında bunu canary payı kadar düşürürdü"
not_reproduced "önbellek metriği okunamadı"
