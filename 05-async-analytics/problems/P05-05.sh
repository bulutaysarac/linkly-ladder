#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P05-05 · terminationGracePeriodSeconds kısa → drain yarıda kalır
# Drain kodu doğru yazılmış olabilir; kubelet süreci bitirmesine izin vermezse hiçbir anlamı yok.
# "Kod doğru" ile "sistem doğru" aynı şey değildir — aradaki fark bir YAML satırı.
ensure_healthy
orig_grace=$(kubectl -n "$NS" get deploy linkly -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}') || true
orig_prestop=$(kubectl -n "$NS" get deploy linkly -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.sleep.seconds}') || true
# İkisini TEK patch'te geri al: API sunucusu preStop.sleep < grace şartını nesnenin SON hâlinde
# doğruluyor; ayrı ayrı göndermek geçersiz bir ara hâl üretir ve reddedilir.
on_cleanup "kubectl -n \"$NS\" patch deploy linkly --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/terminationGracePeriodSeconds\",\"value\":$orig_grace},{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds\",\"value\":$orig_prestop}]'"
# P05-01 ile aynı ölçüm notu: kaybedebileceğin şey o an TAMPONDA olandır. Varsayılan 1 sn'lik
# flush aralığında tampon neredeyse hep boş yakalanır ve "drain'e zaman verilmedi" senaryosu bile
# kayıpsız görünür. Pencereyi 15 sn'ye açıyoruz ki grace ayarının etkisi ölçülebilsin.
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly ANALYTICS_FLUSH_INTERVAL- ANALYTICS_BATCH_SIZE-"
kubectl -n "$NS" set env deploy/linkly ANALYTICS_FLUSH_INTERVAL=15s ANALYTICS_BATCH_SIZE=5000 >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 30); do serving && break; sleep 2; done
measure_loss() {
  local label=$1
  local code b a
  code=$(create_link "https://example.com/grace/$label")
  b=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  clicks "$code" "${N:-2000}" 20
  kubectl -n "$NS" rollout restart deploy/linkly >/dev/null
  kubectl -n "$NS" rollout status deploy/linkly --timeout=200s >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do serving && break; sleep 2; done
  sleep 8
  a=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  echo $(( b + ${N:-2000} - a ))
}
step "Mevcut ayar (grace=${orig_grace}s, preStop=${orig_prestop}s, SHUTDOWN_GRACE=20s): drain'e zaman VAR"
loss_ok=$(measure_loss ok)
note "kayıp: $loss_ok tıklama"
step "grace=3s yap: kubelet süreci drain'in ORTASINDA öldürecek (SHUTDOWN_GRACE hâlâ 20s)"
# preStop beklemesi de küçültülmek ZORUNDA: Kubernetes preStop.sleep < grace şartını doğruluyor
# ve ikisi ayrı patch'lerde gönderilirse ara hâl geçersiz olduğu için istek reddediliyor
# (gerçekte oldu: "Invalid value: 5: must be ... less than terminationGracePeriodSeconds (2)").
# Ders küçülmüyor: grace (3s) hâlâ preStop(1s) + SHUTDOWN_GRACE(20s) toplamının ÇOK altında.
kubectl -n "$NS" patch deploy linkly --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/terminationGracePeriodSeconds","value":3},
  {"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":1}]' >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=200s >/dev/null 2>&1 || true
for _ in $(seq 1 25); do serving && break; sleep 2; done
loss_short=$(measure_loss short)
note "kayıp: $loss_short tıklama"
grafana_hint "07 · Analytics → 'events by result' (written) · 01 · Pods → 'Son sonlanma nedeni'"
note "Aynı kod, aynı drain mantığı, farklı YAML → farklı veri kaybı."
note "Kural: terminationGracePeriodSeconds > (preStop beklemesi + SHUTDOWN_GRACE + drain süresi)."
note "Bu üç sayı birbirini tanımıyorsa, hangisinin kazandığını kubelet'in SIGKILL'i belirler."
(( loss_short > loss_ok )) \
  && reproduced "grace 3s'de kayıp $loss_ok → $loss_short'a çıktı — drain'e zaman verilmezse drain yoktur"
not_reproduced "kısa grace'te ek kayıp ölçülemedi (N'i artırıp tekrar dene)"
