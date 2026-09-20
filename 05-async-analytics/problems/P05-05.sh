#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P05-05 · terminationGracePeriodSeconds kısa → drain yarıda kalır
# Drain kodu doğru yazılmış olabilir; kubelet süreci bitirmesine izin vermezse hiçbir anlamı yok.
# "Kod doğru" ile "sistem doğru" aynı şey değildir — aradaki fark bir YAML satırı.
ensure_healthy
orig_grace=$(kubectl -n "$NS" get deploy linkly -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')
on_cleanup "kubectl -n \"$NS\" patch deploy linkly --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/terminationGracePeriodSeconds\",\"value\":$orig_grace}]'"
measure_loss() {
  local label=$1
  local code b a
  code=$(create_link "https://example.com/grace/$label")
  b=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  for i in $(seq 1 ${N:-400}); do status_of "$code" >/dev/null; done
  kubectl -n "$NS" rollout restart deploy/linkly >/dev/null
  kubectl -n "$NS" rollout status deploy/linkly --timeout=200s >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do serving && break; sleep 2; done
  sleep 8
  a=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  echo $(( b + ${N:-400} - a ))
}
step "Mevcut ayar (grace=${orig_grace}s, SHUTDOWN_GRACE=20s): drain'e zaman VAR"
loss_ok=$(measure_loss ok)
note "kayıp: $loss_ok tıklama"
step "grace=2s yap: kubelet süreci drain'in ORTASINDA öldürecek"
kubectl -n "$NS" patch deploy linkly --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/terminationGracePeriodSeconds","value":2}]' >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=200s >/dev/null 2>&1 || true
for _ in $(seq 1 25); do serving && break; sleep 2; done
loss_short=$(measure_loss short)
note "kayıp: $loss_short tıklama"
grafana_hint "07 · Analytics → 'events by result' (written) · 01 · Pods → 'Son sonlanma nedeni'"
note "Aynı kod, aynı drain mantığı, farklı YAML → farklı veri kaybı."
note "Kural: terminationGracePeriodSeconds > (preStop beklemesi + SHUTDOWN_GRACE + drain süresi)."
note "Bu üç sayı birbirini tanımıyorsa, hangisinin kazandığını kubelet'in SIGKILL'i belirler."
(( loss_short > loss_ok )) \
  && reproduced "grace 2s'de kayıp $loss_ok → $loss_short'a çıktı — drain'e zaman verilmezse drain yoktur"
not_reproduced "kısa grace'te ek kayıp ölçülemedi (N'i artırıp tekrar dene)"
