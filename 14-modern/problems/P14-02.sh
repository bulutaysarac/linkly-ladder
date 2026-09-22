#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P14-02 · Her kopya bir geçersiz kılma kanalı borçlanır
# 03'te L1 vardı ve borç ÖDENMEMİŞTİ: silinen link diğer pod'larda TTL boyunca yaşıyordu (P03-01).
# 14'te L1 geri geldi ve borç pub/sub ile ödeniyor. Bu script iki durumu da ölçüyor — ve kanalın
# EN-İYİ-ÇABA olduğunu, yani kaçan bir mesajın L1 TTL'i kadar bayatlık bıraktığını gösteriyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv \"$(wl redirect)\" TRAP_NO_INVALIDATION_PUBSUB-"
# YEREL SARMALAYICI KENDİ ADINI KULLANAMAZ.
# EN: this line used to read `setenv() { setenv rollout/redirect "$@" ... }` — the inner call is
#     the function itself, so it recursed until the stack blew up (`Segmentation fault: 11`) and
#     the script hung instead of measuring. The bulk rename that introduced `setenv` rewrote both
#     the CALL SITE and this WRAPPER, and the wrapper's whole job was to call the thing it was
#     renamed to. Rename the wrapper, not the callee.
# TR: bu satır `setenv() { setenv rollout/redirect "$@" ... }` idi — içteki çağrı fonksiyonun
#     KENDİSİ, yani yığın taşana kadar özyineledi (`Segmentation fault: 11`) ve script ölçüm
#     yapmak yerine asıldı. `setenv`i getiren toplu değiştirme hem ÇAĞRI YERİNİ hem bu
#     SARMALAYICIYI değiştirdi; sarmalayıcının bütün işi ise yeni adı çağırmaktı.
#     Sarmalayıcıyı yeniden adlandır, çağrılanı değil.
redirect_env() { setenv "$(wl redirect)" "$@" >/dev/null; }
waitrollout() { kubectl -n "$NS" rollout status rollout/redirect --timeout=240s >/dev/null 2>&1 || kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=240s >/dev/null 2>&1 || true; }
# Anahtar KÜMEDEN okunur (platform/lib/apikey.sh): manifest tek kaynak kalsın. Sabit yazarsak
# Secret değiştiği gün script sessizce 401 alır ve "koruma çalışıyor" diye yanlış okunur.
AKEY=${AKEY:-$(ladder_api_key)}
stale_after_delete() {
  waitrollout; for _ in $(seq 1 25); do serving && break; sleep 2; done
  local code alive=0
  # `|| true` ŞART: `set -o pipefail` altında, tuzağı açtıktan sonra rollout yeniden başlarken
  # curl sonlanan bir pod'a denk gelip 52/56 ile düşebiliyor. O zaman ATAMANIN kendisi sıfırdan
  # farklı döner ve `set -e` scripti ÖLÇÜM YAPMADAN öldürür — P14-02 tam olarak burada,
  # 2. fazın ilk satırında öldü. Bir deneyin ortasında geçici bir ağ hatası, deneyin SONUCU
  # değildir; onu yut ve boş kod kontrolüne bırak.
  # EN: mandatory `|| true`: under pipefail a curl that hits a terminating pod during the rollout
  # makes the ASSIGNMENT non-zero and `set -e` kills the script before it measures anything.
  code=$(curl -s -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $AKEY" -d '{"url":"https://example.com/inval"}' | jq -r '.code // empty') || true
  [[ -z "$code" ]] && { echo "-1"; return; }
  # Tüm pod'ların L1'ine girsin
  for i in $(seq 1 40); do status_of "$code" >/dev/null; done
  curl -s -o /dev/null -XDELETE "$BASE_URL/api/links/$code" -H "Authorization: Bearer $AKEY" || true
  sleep 1
  for i in $(seq 1 40); do [[ "$(status_of "$code")" == 30* ]] && alive=$((alive+1)) || true; done
  echo "$alive"
}
step "(1) Pub/sub yayını AÇIK (varsayılan)"
redirect_env TRAP_NO_INVALIDATION_PUBSUB-
on_ok=$(stale_after_delete)
sent=$(promq "sum(increase(cache_invalidation_messages_total{namespace=\"$NS\",direction=\"sent\"}[5m]))")
recv=$(promq "sum(increase(cache_invalidation_messages_total{namespace=\"$NS\",direction=\"received\"}[5m]))")
note "yayın açık: silmeden sonra 40 okumadan $on_ok tanesi hâlâ yönlendiriyor · yayın gönderildi=${sent%%.*} alındı=${recv%%.*}"
step "(2) TRAP_NO_INVALIDATION_PUBSUB: L1 var, yayın YOK (03'ün hâli)"
redirect_env TRAP_NO_INVALIDATION_PUBSUB=true
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
