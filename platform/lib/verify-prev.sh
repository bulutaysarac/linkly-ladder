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
  # Kararı ÇIKIŞ KODUNA değil ÇIKTIDAKİ İŞARETE göre ver. Sebebi ölçüldü: çöken bir script de
  # exit 1 döndürüyor ve "NOT-REPRODUCED" sayılıyordu — yani kırık bir script, sorunun çözüldüğü
  # yanılsamasını üretiyordu. Yanlış yeşil, kırmızıdan tehlikelidir.
  # ANSI renk kodlarını temizle: işaret satırı "\033[1;32mNOT-REPRODUCED" diye başlıyor,
  # düz "^NOT-REPRODUCED" eşleşmez.
  clean=$(printf '%s' "$out" | sed $'s/\033\[[0-9;]*m//g')
  if   grep -q '^NOT-REPRODUCED' <<<"$clean"; then res=NOT-REPRODUCED
  elif grep -q '^REPRODUCED'     <<<"$clean"; then res=REPRODUCED
  elif [[ $rc == 2 ]];                      then res=SKIPPED
  else res="ERROR($rc)"; fi
  mark=""
  [[ "$res" == ERROR* ]] && { mark="  ✘ script hata verdi"; fail=1; }
  [[ -n "$expect" && "$res" != "$expect" && "$res" != SKIPPED && "$res" != ERROR* ]] && { mark="  ✘"; fail=1; }
  printf '%-8s %-16s %s%s\n' "$id" "$res" "${expect:-(açık kalabilir)}" "$mark"
done
exit $fail
