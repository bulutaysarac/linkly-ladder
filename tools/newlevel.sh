#!/usr/bin/env bash
# Yeni seviye: bir öncekini kopyala, LEVEL/NAME/modül/namespace/host'u değiştir, README'yi şablona sıfırla.
# Kullanım: tools/newlevel.sh 03 local-cache
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
lvl=${1:?NN}; nm=${2:?isim}; new="$lvl-$nm"
prev=$(ls -d "$ROOT"/[0-9][0-9]-* | sort | awk -v l="$lvl" '{b=$0; sub(".*/","",b); if (substr(b,1,2) < l) p=$0} END{print p}')
[[ -n "$prev" ]] || { echo "önceki seviye bulunamadı"; exit 1; }
[[ -e "$ROOT/$new" ]] && { echo "$new zaten var"; exit 1; }
pl=$(basename "$prev"); plvl=${pl%%-*}
# go.sum KOPYALANIR. Dışlanırsa yerel derleme go.work sayesinde çalışır ama Docker derlemesi
# (go.work yok, yalnızca go.mod+go.sum) "missing go.sum entry" ile patlar — ve bunu ancak
# deploy anında fark edersin. Gerçekte oldu: 03 ve 04 sessizce hiç ayağa kalkmadı.
rsync -a --exclude bin --exclude 'problems/P*.sh' --exclude problems/SOLVES "$prev/" "$ROOT/$new/"
printf 'LEVEL := %s\nNAME  := %s\ninclude ../ladder.mk\n' "$lvl" "$nm" > "$ROOT/$new/Makefile"
sed -i '' "s|linkly-ladder/$pl|linkly-ladder/$new|" "$ROOT/$new/go.mod"
grep -rl "linkly-ladder/$pl" "$ROOT/$new" --include='*.go' | xargs -I{} sed -i '' "s|linkly-ladder/$pl|linkly-ladder/$new|g" {} 2>/dev/null || true
grep -rl "lvl$plvl" "$ROOT/$new/deploy" | xargs -I{} sed -i '' "s|lvl$plvl|lvl$lvl|g" {}
grep -rl "$plvl-linkly\|$plvl-redirect\|$plvl-api\|$plvl-analytics" "$ROOT/$new/deploy" | xargs -I{} sed -i '' "s|/$plvl-|/$lvl-|g" {} 2>/dev/null || true
: > "$ROOT/$new/problems/SOLVES"
sed "s/NN/$lvl/g; s/<ad>/$nm/g" "$ROOT/docs/LEVEL-TEMPLATE.md" > "$ROOT/$new/README.md"
# go.work'e ekle
grep -q "./$new" "$ROOT/go.work" || sed -i '' "s|^)|\t./$new\n)|" "$ROOT/go.work"
(cd "$ROOT/$new" && go mod tidy >/dev/null 2>&1 && GOWORK=off go build ./... >/dev/null 2>&1) \
  || echo "⚠ $new: GOWORK=off derlemesi başarısız — go mod tidy çalıştır"
echo "✔ $new oluşturuldu ($pl kopyası). Sırada: README'yi doldur, problems/P$lvl-XX.sh yaz, SOLVES'a çözülenleri ekle."
