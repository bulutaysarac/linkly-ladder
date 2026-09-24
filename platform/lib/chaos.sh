#!/usr/bin/env bash
# platform/chaos/<C>.yaml şablonunu NS'e uygula/sil. Şablonun 1. satırı "# target: <label selector>" —
# o selector bu namespace'te pod bulmuyorsa "bu seviyede yok" der.
set -euo pipefail
: "${NS:?}"
LADDER_ROOT=${LADDER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
action=$1; C=${2:-}
kubectl get crd networkchaos.chaos-mesh.org >/dev/null 2>&1 || { echo "Chaos Mesh kurulu değil: cd platform && make chaos"; exit 2; }
apply_one() {
  local f="$LADDER_ROOT/platform/chaos/$1.yaml"
  [[ -f "$f" ]] || { echo "şablon yok: $1"; exit 2; }
  local target; target=$(head -1 "$f" | sed -n 's/^# target: *//p')
  if [[ -n "$target" ]] && [[ -z "$(kubectl -n "$NS" get pods -l "$target" -o name 2>/dev/null)" ]]; then
    echo "bu seviyede hedef yok ($target) — $1 uygulanmadı"; exit 3
  fi
  NS="$NS" envsubst < "$f" | kubectl apply -f -
}
# Chaos nesnesini silerken FINALIZER'A TAKILMA.
# EN: Chaos Mesh puts a finalizer on every chaos object; deleting it makes the controller ask the
#     chaos-daemon on each target pod to undo the injection. If that daemon is unhealthy, the
#     finalizer never completes and `kubectl delete` blocks FOREVER — the cleanup step hangs
#     without printing anything and everything queued behind it stalls.
#     Delete without waiting, then verify; if the object is still there, drop the finalizer by hand
#     and say so. A cleanup that can hang is worse than a cleanup that can fail loudly.
# TR: Chaos Mesh her chaos nesnesine bir finalizer koyar; silmek, controller'ın her hedef pod'daki
#     chaos-daemon'dan enjeksiyonu geri almasını istemesi demektir. Daemon sağlıksızsa finalizer
#     asla tamamlanmaz ve `kubectl delete` SONSUZA KADAR bekler — temizlik adımı hiçbir şey
#     basmadan asılı kalır, arkasında sıradaki her şey durur. Beklemeden sil,
#     sonra DOĞRULA; nesne hâlâ duruyorsa finalizer'ı elle düşür ve bunu söyle.
#     Asılı kalabilen bir temizlik, yüksek sesle başarısız olan bir temizlikten kötüdür.
delete_one() {
  local f="$LADDER_ROOT/platform/chaos/$1.yaml" kind name
  [[ -f "$f" ]] || return 0
  kind=$(awk '/^kind:/{print tolower($2); exit}' "$f")
  # NOT: BSD awk'ta `match(s,re,arr)` (gawk uzantısı) YOK — sed ile al.
  name=$(sed -n 's/.*name: *\([a-z0-9-]*\).*/\1/p' "$f" | head -1)
  [[ -z "$name" ]] && name=$1
  NS="$NS" envsubst < "$f" | kubectl delete --ignore-not-found --wait=false -f - >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    kubectl -n "$NS" get "$kind" "$name" >/dev/null 2>&1 || return 0
    sleep 2
  done
  echo "chaos $name 40 sn'de silinmedi (finalizer takılı) — finalizer düşürülüyor"
  kubectl -n "$NS" patch "$kind" "$name" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl -n "$NS" delete "$kind" "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
force_unstick() {
  local k n
  for k in networkchaos podchaos stresschaos iochaos; do
    for n in $(kubectl -n "$NS" get "$k" -o name 2>/dev/null); do
      kubectl -n "$NS" patch "$n" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done
  done
}

case "$action" in
  apply)  apply_one "$C" ;;
  delete) if [[ -n "$C" ]]; then delete_one "$C";
          else kubectl -n "$NS" delete networkchaos,podchaos,stresschaos,iochaos --all --wait=false 2>/dev/null || true;
               force_unstick; fi ;;
esac
