#!/usr/bin/env bash
# Seviye iskeleti şablonla aynı mı? Sapma = hata. Kullanım: tools/lint-skeleton.sh 03-local-cache
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
L=${1:?seviye klasörü}; L=${L%/}; D="$ROOT/$(basename "$L")"; [[ -d "$D" ]] || D="$L"
name=$(basename "$D"); lvl=${name%%-*}; nm=${name#*-}
fail=0; err() { echo "  ✘ $name: $*"; fail=1; }

# 1. Zorunlu dosyalar
for f in README.md Makefile go.mod Dockerfile deploy/kustomization.yaml problems/SOLVES; do
  [[ -e "$D/$f" ]] || err "eksik: $f"
done
[[ -n "$(ls "$D"/cmd 2>/dev/null)" ]] || err "cmd/ boş"
[[ -n "$(ls "$D"/problems/P*.sh 2>/dev/null)" ]] || err "problems/ içinde P*.sh yok"

# 2. Makefile tam olarak 3 satır (LEVEL, NAME, include)
exp=$(printf 'LEVEL := %s\nNAME  := %s\ninclude ../ladder.mk\n' "$lvl" "$nm")
[[ "$(cat "$D/Makefile")" == "$exp" ]] || err "Makefile şablondan sapmış (LEVEL/NAME/include dışında satır olamaz)"

# 3. Dockerfile şablonla birebir aynı
diff -q "$ROOT/docs/skeleton/Dockerfile" "$D/Dockerfile" >/dev/null || err "Dockerfile docs/skeleton/Dockerfile ile aynı değil"

# 4. Yasaklı klasörler (seviyede olmaması gerekenler)
for x in dashboards load chaos charts helm; do [[ -e "$D/$x" ]] && err "seviyede olmamalı: $x/ (platform/'da tek kopya)"; done

# 5. go.mod modül yolu
grep -q "^module github.com/bulutaysarac/linkly-ladder/$name\$" "$D/go.mod" || err "go.mod modül adı: github.com/bulutaysarac/linkly-ladder/$name olmalı"

# 6. README: 10 başlık sırayla + sabit metinler
heads=("## 1. Bu seviye ne?" "## 2. Mimari" "## 3. Önceki seviyeden çözülenler" "## 4. Ayağa kaldırma" "## 5. API" \
       "## 6. Reproduce edilebilir sorunlar" "## 7. Seviye içi alıştırmalar" "## 8. Gözlemlenebilirlik" "## 9. Bilerek bırakılanlar" "## 10. \`make diff-prev\`")
prev=0
for h in "${heads[@]}"; do
  n=$(grep -n -F "$h" "$D/README.md" | head -1 | cut -d: -f1 || true)
  [[ -n "$n" ]] || { err "README başlık eksik: $h"; continue; }
  (( n > prev )) || err "README başlık sırası bozuk: $h"; prev=$n
done
grep -q 'make up            # build → push → deploy → rollout wait → smoke' "$D/README.md" || err "README §4 sabit metin değişmiş"
grep -q 'Her seviyede aynı: \[docs/API.md\]' "$D/README.md" || err "README §5 sabit metin değişmiş"

# 7. Her problems/P*.sh README'de "### PNN-XX" bölümüne sahip mi, ve tersi
for f in "$D"/problems/P*.sh; do id=$(basename "${f%.sh}"); grep -q "^### $id" "$D/README.md" || err "README'de bölüm yok: ### $id"; done
for id in $(grep -o '^### P[0-9][0-9]-[0-9][0-9]' "$D/README.md" | cut -c5-); do [[ -f "$D/problems/$id.sh" ]] || err "script yok: problems/$id.sh"; done
# 7b. SOLVES: ilk seviye dışında BOŞ OLAMAZ. Boş bir SOLVES, `make verify-prev`'i sessizce
#     etkisiz kılar: her sonuç "açık kalabilir" sayılır ve regresyon yakalanmaz. Gerçekte oldu —
#     bir zsh glob hatası (`rm -f P0X-*.sh &&` boş eşleşmede zinciri kırar) dosyayı hiç yazmadı.
if [[ "$lvl" != "00" ]]; then
  [[ -s "$D/problems/SOLVES" ]] || err "problems/SOLVES boş — verify-prev hiçbir şey doğrulamaz"
  while read -r id; do
    [[ -z "$id" ]] && continue
    [[ "$id" =~ ^P[0-9][0-9]-[0-9][0-9]$ ]] || err "SOLVES'ta geçersiz satır: '$id'"
    [[ "$id" == P$lvl-* ]] && err "SOLVES kendi seviyesinin sorununu içeremez: $id"
  done < "$D/problems/SOLVES"
fi

# 8. Sorun ID'leri bu seviyenin numarasını taşımalı
for f in "$D"/problems/P*.sh; do id=$(basename "${f%.sh}"); [[ "$id" == P$lvl-* ]] || err "yabancı sorun ID'si: $id (P$lvl-XX olmalı)"; done

[[ $fail == 0 ]] && echo "  ✔ $name iskelet OK"
exit $fail
