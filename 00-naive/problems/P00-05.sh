#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-05 · 4 karakterlik kod + çakışma kontrolü yok → sessiz üzerine yazma
#
# Matematik: 62^4 = 14.774.336 kod. Beklenen çakışma ≈ n²/(2N):
#   n=800    → 0.02   (pratikte hiç)
#   n=10000  → 3.4    (en az bir çakışma olasılığı ~%96)
#
# NEDEN SIRALI (PAR=1): paralel istek P00-01'i (eşzamanlı map yazımı → çökme) tetikler; süreç ölünce
# hem üretim durur hem map sıfırlanır ve çakışmayı ÖLÇEMEZSİN. Sorunlar birbirini maskeler — bu da
# merdivenin bir dersi: bir katmandaki hata, alttaki hatayı görünmez yapar.
ensure_healthy
N=${N:-10000}
PAR=${PAR:-1}
step "$N link oluştur (paralellik=$PAR), kodların benzersizliğini say"
note "62^4 = 14.774.336 · beklenen çakışma ≈ n²/2N = $(awk -v n="$N" 'BEGIN{printf "%.1f", n*n/(2*14774336)}') · sıralı hız ~80/s, tahmini süre ~$(( N / 80 ))s"
before=$(restarts)
tmp=$(mktemp)
if (( PAR > 1 )); then
  seq 1 "$N" | xargs -P "$PAR" -I{} sh -c \
    'curl -sf -XPOST "$0/api/links" -H "Content-Type: application/json" -d "{\"url\":\"https://example.com/u/{}\"}" | sed -n "s/.*\"code\":\"\([^\"]*\)\".*/\1/p"' \
    "$BASE_URL" >> "$tmp" 2>/dev/null
else
  for i in $(seq 1 "$N"); do
    curl -sf -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' \
      -d "{\"url\":\"https://example.com/u/$i\"}" 2>/dev/null \
      | sed -n 's/.*"code":"\([^"]*\)".*/\1/p' >> "$tmp" || true
  done
fi
after=$(restarts)
total=$(grep -c . "$tmp" | tr -d ' '); uniq=$(sort -u "$tmp" | grep -c . | tr -d ' ')
collisions=$(( total - uniq ))
dupe=$(sort "$tmp" | uniq -d | head -1)
rm -f "$tmp"
(( after > before )) && warn "bu tur sırasında süreç $((after-before)) kez çöktü (P00-01) — ölçüm bozulmuş olabilir, tekrar dene"
note "$total üretim, $uniq benzersiz kod → $collisions çakışma"
if [[ -n "$dupe" ]]; then
  step "Çakışan kod '$dupe' şu an kime ait?"
  { curl -s "$BASE_URL/api/links/$dupe" | head -c 200; } || true; echo
  note "Bu kodu İKİ kullanıcı aldı; kayıtta yalnızca sonuncusu var. İlkinin linki hata vermeden yok oldu."
fi
grafana_hint "03 · App Business → 'create sonuçları' (collision serisi 00'da YOK — ölçemiyor olman da bir kanıt)"
(( collisions > 0 )) && reproduced "$collisions kod çakıştı; kullanıcının linki sessizce başkasınınkiyle değişti"
not_reproduced "bu turda çakışma çıkmadı (N=$N, olasılık ~%$(awk -v n="$N" 'BEGIN{printf "%d", (1-exp(-n*n/(2*14774336)))*100}')). N=20000 ile tekrar dene ya da kod üretimi düzeltilmiş (01)"
