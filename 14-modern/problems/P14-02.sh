#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P14-02 · Her kopya bir geçersiz kılma kanalı borçlanır
# 03'te L1 vardı ve borç ÖDENMEMİŞTİ: silinen link diğer pod'larda TTL boyunca yaşıyordu (P03-01).
# 14'te L1 geri geldi ve borç pub/sub ile ödeniyor. Bu script iki durumu da ölçüyor — ve kanalın
# EN-İYİ-ÇABA olduğunu, yani kaçan bir mesajın L1 TTL'i kadar bayatlık bıraktığını gösteriyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env rollout/redirect TRAP_NO_INVALIDATION_PUBSUB- 2>/dev/null || kubectl -n \"$NS\" set env deploy/redirect TRAP_NO_INVALIDATION_PUBSUB-"
setenv() { kubectl -n "$NS" set env rollout/redirect "$@" >/dev/null 2>&1 || kubectl -n "$NS" set env deploy/redirect "$@" >/dev/null; }
waitrollout() { kubectl -n "$NS" rollout status rollout/redirect --timeout=240s >/dev/null 2>&1 || kubectl -n "$NS" rollout status deploy/redirect --timeout=240s >/dev/null 2>&1 || true; }
AKEY=${AKEY:-acme-key-9f2c}
stale_after_delete() {
  waitrollout; for _ in $(seq 1 25); do serving && break; sleep 2; done
  local code alive=0
  code=$(curl -s -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $AKEY" -d '{"url":"https://example.com/inval"}' | jq -r '.code // empty')
  [[ -z "$code" ]] && { echo "-1"; return; }
  # Tüm pod'ların L1'ine girsin
  for i in $(seq 1 40); do status_of "$code" >/dev/null; done
  curl -s -o /dev/null -XDELETE "$BASE_URL/api/links/$code" -H "Authorization: Bearer $AKEY"
  sleep 1
  for i in $(seq 1 40); do [[ "$(status_of "$code")" == 30* ]] && alive=$((alive+1)) || true; done
  echo "$alive"
}
step "(1) Pub/sub yayını AÇIK (varsayılan)"
setenv TRAP_NO_INVALIDATION_PUBSUB-
on_ok=$(stale_after_delete)
sent=$(promq "sum(increase(cache_invalidation_messages_total{namespace=\"$NS\",direction=\"sent\"}[5m]))")
recv=$(promq "sum(increase(cache_invalidation_messages_total{namespace=\"$NS\",direction=\"received\"}[5m]))")
note "yayın açık: silmeden sonra 40 okumadan $on_ok tanesi hâlâ yönlendiriyor · yayın gönderildi=${sent%%.*} alındı=${recv%%.*}"
step "(2) TRAP_NO_INVALIDATION_PUBSUB: L1 var, yayın YOK (03'ün hâli)"
setenv TRAP_NO_INVALIDATION_PUBSUB=true
off_bad=$(stale_after_delete)
note "yayın kapalı: 40 okumadan $off_bad tanesi hâlâ yönlendiriyor"
l1ttl=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="L1_TTL")]}{.value}{end}' 2>/dev/null) || true
grafana_hint "04 · Cache → 'hit ratio by pod' · yeni metrik: cache_invalidation_messages_total"
note "L1_TTL=${l1ttl:-10s} — yayın kaçarsa bayatlık penceresi TAM OLARAK bu kadar."
note "Pub/sub EN-İYİ-ÇABA'dır: Redis yeniden başlarsa, bir pod abone olamazsa ya da mesaj düşerse"
note "kimse fark etmez. Bu yüzden kısa TTL bir YEDEK MEKANİZMADIR, bir optimizasyon değil."
note "Daha güçlü alternatifler ve bedelleri:"
note "  · sürüm damgalı anahtar (link:v<n>:code) → eski anahtar hiç okunmaz, ama sürüm nerede tutulur?"
note "  · yazma sırasında L1'i atla (write-through yok) → sıcak anahtarda kazancı kaybedersin"
note "  · dayanıklı akış (Kafka) ile yayın → sıra ve teslimat garantisi, karşılığında gecikme"
note "Seçim: en-iyi-çaba yayın + KISA TTL. Pencereyi ÖLÇTÜK ve kabul ettik — 03'teki fark bu."
{ (( off_bad >= on_ok )) && (( on_ok >= 0 )); } \
  && reproduced "yayın açıkken bayat yanıt $on_ok/40, kapalıyken $off_bad/40 (gönderilen yayın ${sent%%.*}) — her kopya bir kanal borçlanır"
not_reproduced "fark ölçülemedi (L1 açık mı? pub/sub kanalı doğru mu?)"
