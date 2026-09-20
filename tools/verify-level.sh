#!/usr/bin/env bash
# Bir seviyeyi ayağa kaldır, verify-prev koş, kendi sorunlarını koş, sonucu özetle, indir.
# Kullanım: tools/verify-level.sh 03-local-cache [--keep]
# Amaç: uzun doğrulama turlarını tek komuta indirmek ve her adımı hata toleranslı yapmak —
# bir script patlarsa zincir durmasın, sonuç tablosunda HATA olarak görünsün.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
L=${1:?seviye klasörü}; KEEP=${2:-}
cd "$ROOT/$L" || exit 1
lvl=${L%%-*}

echo "═══ $L · make up"
if ! make up 2>&1 | tail -6; then
  echo "✘ $L ayağa kalkmadı — doğrulama atlanıyor"; exit 1
fi

echo "═══ $L · verify-prev"
CONFIRM=1 make verify-prev 2>&1 | grep -E '^(ID|P[0-9]{2}-)' || echo "(önceki seviye yok)"

echo "═══ $L · kendi sorunları"
for f in problems/P${lvl}-*.sh; do
  [[ -e "$f" ]] || continue
  p=$(basename "${f%.sh}")
  out=$(CONFIRM=1 make repro P="$p" 2>&1)
  # NOT- önce: alternasyonda uzun olanı öne koymak, yanlış eşleşmeyi imkânsız kılar.
  r=$(echo "$out" | grep -oE 'NOT-REPRODUCED|REPRODUCED' | tail -1)
  printf '%-8s %s\n' "$p" "${r:-HATA}"
  [[ -z "$r" ]] && echo "$out" | tail -4 | sed 's/^/         | /'
done

if [[ "$KEEP" != "--keep" ]]; then
  echo "═══ $L · make down"
  make down >/dev/null 2>&1
fi
echo "═══ $L · bitti"
