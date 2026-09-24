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
# EN: `setenv() { setenv rollout/redirect "$@" ... }` would call ITSELF, recurse until the stack
#     blows up (`Segmentation fault: 11`) and hang the script instead of measuring. A wrapper
#     whose whole job is to call a function must not take that function's name: rename the
#     wrapper, not the callee.
# TR: `setenv() { setenv rollout/redirect "$@" ... }` KENDİNİ çağırır, yığın taşana kadar
#     özyineler (`Segmentation fault: 11`) ve script ölçüm yapmak yerine asılır. Bütün işi bir
#     fonksiyonu çağırmak olan sarmalayıcı o fonksiyonun adını alamaz: sarmalayıcıyı yeniden
#     adlandır, çağrılanı değil.
redirect_env() { setenv "$(wl redirect)" "$@" >/dev/null; }
# ROLLOUT'UN GERÇEKTEN BİTMESİNİ BEKLE — `make wait` ile aynı ölçüt: Healthy VE stableRS == currentPodHash.
# EN: `kubectl rollout status` does not know Argo Rollouts; a helper that swallows its error with
#     `|| true` returns at once. An env change on a Rollout is a CANARY (analysis steps, ~4 min),
#     so a phase would be measured on the OLD pods (here: the trap phase would run with the
#     broadcast still active). Wait until the
#     controller has seen the new spec (observedGeneration), then until the new revision is stable.
#     An aborted canary (Degraded) means the old pods are serving: that is "could not measure".
# TR: `kubectl rollout status` Argo Rollout'u tanımaz; hatayı `|| true` ile yutan bir yardımcı HEMEN
#     döner. Rollout'ta ortam değişikliği bir CANARY'dir (analiz adımları, ~4 dk); bir faz ESKİ
#     pod'larda ölçülürdü (burada: tuzak fazı yayın hâlâ açıkken koşardı). Önce denetleyicinin yeni spec'i gördüğünü
#     (observedGeneration), sonra yeni sürümün stable olduğunu bekle. İptal edilen canary (Degraded)
#     eski pod'ların hizmet verdiği demektir: bu "ölçemedik"tir.
rollout_field() { kubectl -n "$NS" get "$(wl redirect)" -o jsonpath="{$1}" 2>/dev/null || true; }
wait_rollout_done() {
  local gen ph st cu i
  [[ "$(wl redirect)" == rollout/* ]] || { settle_rollout "$(wl redirect)"; return 0; }
  gen=$(rollout_field .metadata.generation)
  for i in $(seq 1 30); do [[ "$(rollout_field .status.observedGeneration)" == "$gen" ]] && break; sleep 2; done
  for i in $(seq 1 240); do
    ph=$(rollout_field .status.phase); st=$(rollout_field .status.stableRS); cu=$(rollout_field .status.currentPodHash)
    if [[ "$ph" == Healthy && -n "$st" && "$st" == "$cu" ]]; then
      for _ in $(seq 1 25); do serving && break; sleep 2; done
      return 0
    fi
    if [[ "$ph" == Degraded ]]; then
      warn "canary İPTAL edildi: $(rollout_field .status.message | head -c 160) — pod'lar ESKİ sürümde, ölçüm anlamsız"
      exit 2
    fi
    [[ $i == 1 ]] && note "  canary adımları sürüyor ($ph) — yeni sürüm stable olana kadar bekleniyor (analiz ~4 dk)"
    sleep 2
  done
  warn "rollout 8 dk içinde Healthy olmadı ($ph) — ölçüm anlamsız"
  exit 2
}
# Anahtar KÜMEDEN okunur (platform/lib/apikey.sh): manifest tek kaynak kalsın. Sabit yazarsak
# Secret değiştiği gün script sessizce 401 alır ve "koruma çalışıyor" diye yanlış okunur.
AKEY=${AKEY:-$(ladder_api_key)}
# BAYATLIK PENCERESİ, ÖLÇÜM DÖNGÜSÜNDEN UZUN OLMALI.
# L1_TTL bu seviyede 10 sn; oysa L1'i ısıtan 40 okuma + silme + 40 okuma bundan uzun sürüyor.
# Sonuç: yayın KAPALIYKEN bile bayat cevap görünmüyor (ölçüldü: iki fazda da 0/40) — çünkü
# pencere, biz bakmadan kapanıyor. Ölçülecek şey pencerenin VARLIĞIdır, uzunluğu değil; o hâlde
# deney süresince TTL'i uzat ve sonunda geri al. Ayrıca en az iki replika şart: tek pod varsa
# "her kopya bir kanal borçlanır" iddiasının kopyası yoktur.
# EN: the L1 TTL (10s) is shorter than the measurement loop (40 warm reads + delete + 40 reads),
# so the staleness window closes before we look — 0/40 in BOTH phases. What we measure is the
# EXISTENCE of the window, not its length, so widen the TTL for the experiment and restore it.
# At least two replicas are required too: with one pod there is no second copy to go stale.
on_cleanup "setenv \"$(wl redirect)\" L1_TTL-"
redirect_env L1_TTL="${L1_TTL_TEST:-90s}"
orig_reps=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 2)
if (( ${orig_reps:-2} < 2 )); then
  on_cleanup "kubectl -n \"$NS\" scale \"$(wl redirect)\" --replicas=$orig_reps"
  kubectl -n "$NS" scale "$(wl redirect)" --replicas=2 >/dev/null 2>&1 || true
fi
note "deney için L1_TTL=${L1_TTL_TEST:-90s}, redirect replika=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
# stale_after_delete bir `$( )` içinde koşar: rollout beklemesi (ve exit 2'si) DIŞARIDA yapılır.
stale_after_delete() {
  local code alive=0
  # `|| true` ŞART: `set -o pipefail` altında, tuzağı açtıktan sonra rollout yeniden başlarken
  # curl sonlanan bir pod'a denk gelip 52/56 ile düşebiliyor. O zaman ATAMANIN kendisi sıfırdan
  # farklı döner ve `set -e` scripti ÖLÇÜM YAPMADAN öldürür. Bir deneyin ortasında geçici bir ağ
  # hatası, deneyin SONUCU değildir; onu yut ve boş kod kontrolüne bırak.
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
wait_rollout_done
on_ok=$(stale_after_delete)
sent=$(promq "sum(increase(cache_invalidation_messages_total{namespace=\"$NS\",direction=\"sent\"}[5m]))")
recv=$(promq "sum(increase(cache_invalidation_messages_total{namespace=\"$NS\",direction=\"received\"}[5m]))")
note "yayın açık: silmeden sonra 40 okumadan $on_ok tanesi hâlâ yönlendiriyor · yayın gönderildi=${sent%%.*} alındı=${recv%%.*}"
step "(2) TRAP_NO_INVALIDATION_PUBSUB: L1 var, yayın YOK (03'ün hâli)"
redirect_env TRAP_NO_INVALIDATION_PUBSUB=true
wait_rollout_done
off_bad=$(stale_after_delete)
note "yayın kapalı: 40 okumadan $off_bad tanesi hâlâ yönlendiriyor"
l1ttl=${L1_TTL_TEST:-90s}; : $(kubectl -n "$NS" get rollout redirect -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="L1_TTL")]}{.value}{end}' 2>/dev/null) || true
grafana_hint "04 · Cache → 'Önbellekten çıkarılma sebepleri' (invalidate) · 03 · App Business → 'Yönlendirme sonuçları' · Explore: cache_invalidation_messages_total"
note "L1_TTL=${l1ttl:-10s} — yayın kaçarsa bayatlık penceresi TAM OLARAK bu kadar."
note "Pub/sub EN-İYİ-ÇABA'dır: Redis yeniden başlarsa, bir pod abone olamazsa ya da mesaj düşerse"
note "kimse fark etmez. Bu yüzden kısa TTL bir YEDEK MEKANİZMADIR, bir optimizasyon değil."
note "Daha güçlü alternatifler ve bedelleri:"
note "  · sürüm damgalı anahtar (link:v<n>:code) → eski anahtar hiç okunmaz, ama sürüm nerede tutulur?"
note "  · yazma sırasında L1'i atla (write-through yok) → sıcak anahtarda kazancı kaybedersin"
note "  · dayanıklı akış (Kafka) ile yayın → sıra ve teslimat garantisi, karşılığında gecikme"
note "Seçim: en-iyi-çaba yayın + KISA TTL. Pencereyi ÖLÇTÜK ve kabul ettik — 03'teki fark bu."
# `on_ok >= 0` TEK BAŞINA BİR KORUMA DEĞİL: sayaç negatif olamaz (yalnızca -1, "link
# oluşturulamadı" anlamına gelir), yani bu koşul her zaman doğrudur. `off_bad >= on_ok` ise
# EŞİTLİKTE — ikisi de 0 iken, yani hiçbir şey ölçülmemişken — geçerdi; L1 kapalıyken ya da silme
# başarısızken script "borç ödendi" diyebilirdi. Bu yüzden hüküm `off_bad > 0` ve KESİN büyüklük ister.
# EN: `on_ok >= 0` alone guards nothing — the counter cannot be negative (only -1 means "link could
# not be created"), so it is always true. `off_bad >= on_ok` would pass at EQUALITY, i.e. when both
# are 0 and nothing was measured at all; hence `off_bad > 0` and a STRICT comparison.
{ (( on_ok >= 0 )) && (( off_bad > 0 )) && (( off_bad > on_ok )); } \
  && reproduced "yayın açıkken bayat yanıt $on_ok/40, kapalıyken $off_bad/40 (gönderilen yayın ${sent%%.*}) — her kopya bir kanal borçlanır"
not_reproduced "fark ölçülemedi (L1 açık mı? pub/sub kanalı doğru mu?)"
