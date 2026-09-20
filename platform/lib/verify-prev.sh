#!/usr/bin/env bash
# Önceki seviyenin problems/*.sh'sini BU namespace'e koş. SOLVES dosyasındaki ID'ler NOT-REPRODUCED olmalı.
set -uo pipefail
PREV=$1; SOLVES=$2
: "${NS:?}"
fail=0
printf '%-8s %-16s %s\n' "ID" "SONUÇ" "BEKLENEN"
for f in "$PREV"/problems/P*.sh; do
  id=$(basename "${f%.sh}")
  expect=""; grep -qx "$id" "$SOLVES" 2>/dev/null && expect="NOT-REPRODUCED"
  out=$(bash "$f" 2>&1); rc=$?
  case $rc in 0) res=REPRODUCED;; 1) res=NOT-REPRODUCED;; 2) res=SKIPPED;; *) res="ERROR($rc)";; esac
  mark=""; [[ -n "$expect" && "$res" != "$expect" && "$res" != SKIPPED ]] && { mark="  ✘"; fail=1; }
  printf '%-8s %-16s %s%s\n' "$id" "$res" "${expect:-(açık kalabilir)}" "$mark"
done
exit $fail
