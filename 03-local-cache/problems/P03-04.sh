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
measure() {
  local reps=$1 h0 a0 h1 a1
  scale "$reps"; wait_endpoints "$reps"
  kubectl -n "$NS" rollout restart deploy/linkly >/dev/null
  kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null 2>&1 || true
  wait_endpoints "$reps"; sleep 5
  h0=$(hits); a0=$(allops)
  SEED=$SEEDN k6run redirect --vus 20 --duration 60s >/dev/null 2>&1 || true
  sleep 20   # son scrape gelsin: sayaç farkı yükün tamamını kapsamalı
  h1=$(hits); a1=$(allops)
  awk -v h0="${h0:-0}" -v a0="${a0:-0}" -v h1="${h1:-0}" -v a1="${a1:-0}" \
      'BEGIN{d=a1-a0; if (d<=0) {print 0; exit} printf "%.4f", (h1-h0)/d}'
}
pct() { awk -v v="${1:-0}" 'BEGIN{printf "%.1f%%", v*100}'; }
step "1 replika ile hit oranı ($SEEDN kodluk çalışma kümesi)"
h1=$(measure 1); note "1 pod → hit oranı $(pct "$h1")"
many=$(( orig > 3 ? orig : 6 ))
step "$many replika ile aynı yük, aynı çalışma kümesi"
h6=$(measure "$many"); note "$many pod → hit oranı $(pct "$h6")"
grafana_hint "04 · Cache → 'hit ratio by pod' · 'cache miss vs DB qps'"
note "Aynı çalışma kümesi, aynı yük, farklı hit oranı: pod başına örneklem küçüldü."
note "Isınma maliyeti pod sayısıyla ÇARPILIR: her pod aynı $SEEDN kaydı kendisi için ayrı ayrı çeker."
note "Bir çözüm consistent hashing'dir (aynı anahtar hep aynı pod'a) — ama o da sıcak anahtarı tek"
note "pod'a bağlar ve ölçekleme sırasında anahtarları taşır. 04 sorunu tamamen ortadan kaldırıyor."
awk -v a="${h1:-0}" -v b="${h6:-0}" 'BEGIN{exit !(a > b + 0.05)}' \
  && reproduced "hit oranı $(pct "$h1") → $(pct "$h6") düştü (replika 1 → $many)"
not_reproduced "hit oranı replika sayısından etkilenmedi — önbellek paylaşımlı (04)"
