#!/usr/bin/env bash
# Doğrulama turu: profil → make up → verify-prev → kendi sorunları → make down.
# Kullanım: tools/verify-sweep.sh 08-rate-limiting 09-database-scaling ...
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
run_level() {
  local L=$1 lvl=${1%%-*}
  "$R/platform/lib/profile.sh" "$lvl"
  cd "$R/$L" || return 1
  echo "═══ $L · make up"
  local upout; upout=$(make up 2>&1) || {
    echo "✘ $L ayağa kalkmadı"
    echo "$upout" | tail -12 | sed 's/^/         ! /'
    return 1
  }
  echo "═══ $L · verify-prev"
  CONFIRM=1 make verify-prev 2>&1 | grep -E '^(ID|P[0-9]{2}-)' || echo "(önceki seviye yok)"
  echo "═══ $L · kendi sorunları"
  for f in problems/P${lvl}-*.sh; do
    [[ -e "$f" ]] || continue
    p=$(basename "${f%.sh}")
    out=$(CONFIRM=1 make repro P="$p" 2>&1)
    r=$(echo "$out" | grep -oE 'NOT-REPRODUCED|REPRODUCED' | tail -1)
    printf '%-8s %s\n' "$p" "${r:-HATA}"
    if [[ -z "$r" ]]; then echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -8 | sed 's/^/         ! /'
    else echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^(  |▶)' | tail -10 | sed 's/^/         · /'; fi
  done
  echo "═══ $L · make down"; make down >/dev/null 2>&1
  echo "═══ $L · bitti"
}
for L in "$@"; do run_level "$L"; done
