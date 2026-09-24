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
  # HER SCRIPT KENDİ SINIRINDA: verify-prev'in toplam sınırı var ama tek bir script asılırsa
  # (ör. takılı bir rollout'u beklerken) o bütçeyi tek başına yer. Süreç AĞACINI öldür;
  # watchdog'un çıktısını kapat, yoksa komut ikamesi EOF bekleyip ASILI KALIR.
  _kt() { local q=$1 c; for c in $(pgrep -P "$q" 2>/dev/null); do _kt "$c"; done; kill -KILL "$q" 2>/dev/null || true; }
  out=$( ( bash "$f" 2>&1 ) & bpid=$!; ( sleep "${SCRIPT_TIMEOUT:-720}"; _kt "$bpid" ) >/dev/null 2>&1 & wd=$!;
         wait "$bpid"; r=$?; kill "$wd" 2>/dev/null; exit "$r" ); rc=$?
  # Kararı ÇIKIŞ KODUNA değil ÇIKTIDAKİ İŞARETE göre ver: çöken bir script de exit 1 döndürür
  # ve çıkış koduna bakan bir karar onu "NOT-REPRODUCED" sayar — kırık bir script, sorunun
  # çözüldüğü yanılsamasını üretir. Yanlış yeşil, kırmızıdan tehlikelidir.
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
