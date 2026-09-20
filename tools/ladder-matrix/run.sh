#!/usr/bin/env bash
# Tüm problems/*.sh'yi tüm seviyelere koş → out/matrix.md (kök README'ye yapıştırılır).
# Uzun sürer: her seviyeyi sırayla ayağa kaldırır. Yıkıcı scriptler CONFIRM=1 ile.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/tools/ladder-matrix/out"; mkdir -p "$OUT"
LEVELS=$(ls -d "$ROOT"/[0-9][0-9]-* | sort)
ONLY=${ONLY:-}   # ONLY="00 01" ile alt küme
declare -A R
ids=()
for L in $LEVELS; do for f in "$L"/problems/P*.sh; do ids+=("$(basename "${f%.sh}")|$f"); done; done
for L in $LEVELS; do
  lvl=$(basename "$L"); n=${lvl%%-*}
  [[ -n "$ONLY" && " $ONLY " != *" $n "* ]] && continue
  echo "==== $lvl"
  (cd "$L" && make --no-print-directory up) || { echo "$lvl ayağa kalkmadı"; continue; }
  for e in "${ids[@]}"; do
    id=${e%%|*}; f=${e#*|}
    (cd "$L" && NS=lvl$n BASE_URL=http://lvl$n.localtest.me LADDER_ROOT=$ROOT CONFIRM=${CONFIRM:-} bash "$f" >/dev/null 2>&1); rc=$?
    case $rc in 0) R["$id,$n"]="🔴";; 1) R["$id,$n"]="🟢";; 2) R["$id,$n"]="⏭";; *) R["$id,$n"]="⚠";; esac
    echo "  $id → ${R["$id,$n"]}"
  done
  (cd "$L" && make --no-print-directory down)
done
{
  printf '| Sorun |'; for L in $LEVELS; do printf ' %s |' "$(basename "$L" | cut -c1-2)"; done; echo
  printf '|---|'; for L in $LEVELS; do printf '---|'; done; echo
  for e in "${ids[@]}"; do id=${e%%|*}; printf '| %s |' "$id"; for L in $LEVELS; do n=$(basename "$L" | cut -c1-2); printf ' %s |' "${R["$id,$n"]:-·}"; done; echo; done
  echo; echo "🔴 REPRODUCED · 🟢 NOT-REPRODUCED · ⏭ atlandı (CONFIRM/ön koşul) · ⚠ hata · · koşulmadı"
} > "$OUT/matrix.md"
echo "→ $OUT/matrix.md"
