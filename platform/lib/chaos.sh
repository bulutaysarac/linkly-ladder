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
case "$action" in
  apply)  apply_one "$C" ;;
  delete) if [[ -n "$C" ]]; then NS="$NS" envsubst < "$LADDER_ROOT/platform/chaos/$C.yaml" | kubectl delete --ignore-not-found -f -;
          else kubectl -n "$NS" delete networkchaos,podchaos,stresschaos,iochaos --all 2>/dev/null || true; fi ;;
esac
