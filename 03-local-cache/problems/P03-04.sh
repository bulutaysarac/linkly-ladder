#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-04 · Hit oranı replika sayısıyla DÜŞER
# Load balancer istekleri rastgele dağıtıyor; aynı anahtar N farklı pod'a düşebiliyor. Sabit bir
# çalışma kümesi için her pod'un gördüğü örneklem küçülüyor → ısınma N kat uzuyor, hit oranı düşüyor.
#
# ÖLÇÜM NOTU (iki kez yanıldık, ikisi de öğretici):
#  1) Çalışma kümesi küçükken (200 kod) etki ölçülemez: 6 pod × 200 ıska, 60 sn'lik yükün toplam
#     istek sayısının yanında gürültü kalır. Etkinin büyüklüğü N×K/(istek sayısı) — K'yi büyüt.
#  2) `increase(...[3m])` iki ölçümü birbirine karıştırıyordu: ölçekleme + restart + yük, iki ölçüm
#     arasında 3 dakikadan kısa sürüyor. Artık sayacın KENDİSİNİ yükten önce ve sonra okuyup fark
#     alıyoruz — pencere hizalama derdi yok.
SEEDN=${SEEDN:-4000}
ensure_healthy
need_confirm "replika sayısı değişecek (deney sonunda geri alınır)"
orig=$(replicas_of)
on_cleanup "kubectl -n \"$NS\" scale deploy -l \"$APP_SELECTOR\" --replicas=$orig"
hits()   { promq "sum(cache_ops_total{namespace=\"$NS\",result=~\"hit|negative_hit\"})"; }
allops() { promq "sum(cache_ops_total{namespace=\"$NS\"})"; }
misses() { promq "sum(cache_ops_total{namespace=\"$NS\",result=\"miss\"})"; }
# ASIL ÖLÇÜ: ISKA SAYISI, hit oranı değil.
# Hit oranı paydası (toplam istek) ve payı (ısınma maliyeti) aynı anda oynadığı için kırılgan:
# seed sayısı ya da throughput biraz değişince oran da değişir ve deney yanlış sonuç verir
# (gerçekte oldu: 04'te paylaşılan önbellek olmasına rağmen "oran düştü" dedi — çünkü iki koşuda
# oluşturulan link sayısı farklıydı). Iska sayısı doğrudan şunu ölçer: kaç (pod, anahtar) çifti
# ısıtıldı? Pod içi önbellekte bu sayı pod sayısıyla ÇARPILIR; paylaşılan önbellekte SABİT kalır.
measure() {
  local reps=$1 h0 a0 m0 h1 a1 m1
  scale "$reps"; wait_endpoints "$reps"
  kubectl -n "$NS" rollout restart "$(app_workload)" >/dev/null
  kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null 2>&1 || true
  wait_endpoints "$reps"; sleep 5
  h0=$(hits); a0=$(allops); m0=$(misses)
  # SEED_BUDGET_MS yüksek: iki koşu AYNI sayıda kod görmeli, yoksa karşılaştırma anlamsız.
  SEED=$SEEDN SEED_BUDGET_MS=240000 k6run redirect --vus 20 --duration 60s >/dev/null 2>&1 || true
  sleep 20   # son scrape gelsin: sayaç farkı yükün tamamını kapsamalı
  h1=$(hits); a1=$(allops); m1=$(misses)
  awk -v h0="${h0:-0}" -v a0="${a0:-0}" -v m0="${m0:-0}" -v h1="${h1:-0}" -v a1="${a1:-0}" -v m1="${m1:-0}" \
      'BEGIN{d=a1-a0; r=(d>0 ? (h1-h0)/d : 0); printf "%.4f %d", r, m1-m0}'
}
pct() { awk -v v="${1:-0}" 'BEGIN{printf "%.1f%%", v*100}'; }
step "1 replika: ısınma maliyeti ($SEEDN kodluk çalışma kümesi)"
read -r h1 miss1 <<< "$(measure 1)"
note "1 pod → ıska $miss1 · hit oranı $(pct "$h1")"
many=$(( orig > 3 ? orig : 6 ))
step "$many replika ile aynı yük, aynı çalışma kümesi"
read -r h6 miss6 <<< "$(measure "$many")"
note "$many pod → ıska $miss6 · hit oranı $(pct "$h6")"
note "Beklenti: pod içi önbellekte ıska ≈ pod sayısı × anahtar; paylaşılanda ≈ anahtar (sabit)."
note "ıska oranı: $(awk -v a="${miss1:-0}" -v b="${miss6:-0}" 'BEGIN{printf "%.1fx", (a>0? b/a : 0)}') (paylaşılan önbellekte ~1.0x olmalı)"
grafana_hint "04 · Cache → 'hit ratio by pod' · 'cache miss vs DB qps'"
note "Aynı çalışma kümesi, aynı yük, farklı hit oranı: pod başına örneklem küçüldü."
note "Isınma maliyeti pod sayısıyla ÇARPILIR: her pod aynı $SEEDN kaydı kendisi için ayrı ayrı çeker."
note "Bir çözüm consistent hashing'dir (aynı anahtar hep aynı pod'a) — ama o da sıcak anahtarı tek"
note "pod'a bağlar ve ölçekleme sırasında anahtarları taşır. 04 sorunu tamamen ortadan kaldırıyor."
awk -v a="${miss1:-0}" -v b="${miss6:-0}" 'BEGIN{exit !(a > 0 && b > a*1.8)}' \
  && reproduced "ısınma maliyeti pod sayısıyla çarpıldı: ıska $miss1 → $miss6 ($(awk -v a="$miss1" -v b="$miss6" 'BEGIN{printf "%.1fx", b/a}')), hit oranı $(pct "$h1") → $(pct "$h6")"
not_reproduced "ıska sayısı replika sayısından etkilenmedi ($miss1 → $miss6) — önbellek paylaşımlı (04)"
