#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-03 · Aynı veri N pod'da N kez: bellek çarpanı
# 100 bin sıcak link × 3 pod = 3 kopya. Ölçek büyüdükçe bu çarpan ödediğin RAM olur.
#
# ÖLÇÜM NOTU — "toplam kayıt ÷ en dolu pod" çoğalmayı KANITLAMAZ.
# Linkleri ingress üzerinden iki tur okuyup bu orana bakmak ~3 verir. Ama pod'lar anahtarları
# PAYLAŞSAYDI (her pod ayrı üçte bir) da oran 3 çıkardı: bu ölçü, iddia yanlışken de aynı sayıyı
# verir. Üstelik iki rastgele turdan sonra her pod anahtarların ancak ~yarısını tutar, "hepsini"
# değil. Daha sinsi bir tuzak: ingress-nginx round robin dağıtır; sıralı okunan N kod pod sayısına
# tam bölünüyorsa her tur AYNI kodu AYNI pod'a götürür ve her pod tam üçte birini tutar — gerçek
# bir çoğalma, ölçümde hiç görünmez.
# Bu yüzden: AYNI N kodu HER POD'A DOĞRUDAN (port-forward, ingress'i atlayarak) okutuyoruz ve her
# pod'un önbellek kaydını kendi /metrics ucundan, okumadan hemen önce ve hemen sonra okuyoruz
# (Prometheus'un kazıma gecikmesi yok). Ölçü: pod'lara eklenen kayıtların toplamı ÷ FARKLI kod sayısı. Paylaşılan
# bir önbellekte (04) bu 0'dır (pod'da kopya yok), paylaşılmış ayrık dilimlerde 1'dir, pod başına
# kopyada replika sayısıdır.
# EN: the ratio total entries ÷ fullest pod (≈ 3) would also be 3 if each pod held a disjoint
#     third of the keys, and round-robin routing can make exactly that happen. So the same N codes
#     are read through EVERY pod directly and each pod's cache_entries is read from its own
#     /metrics before and after; the measure is added entries ÷ DISTINCT keys.
ensure_healthy
N=${N:-3000}
PF_PORT=${PF_PORT:-18093}
# Yalnızca UYGULAMA pod'ları: APP_SELECTOR (part-of) postgres'i de seçer ve orada 8080 yoktur.
pods=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$(app_name)" -o json 2>/dev/null \
         | jq -r '.items[] | select(.metadata.deletionTimestamp == null)
                  | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name' || true)
reps=$(printf '%s\n' "$pods" | count_lines .)
(( reps > 0 )) || { warn "hazır uygulama pod'u yok"; exit 2; }

step "$N farklı link oluştur"
codes=$(mktemp); on_cleanup "rm -f $codes"
for i in $(seq 1 "$N"); do create_link "https://example.com/mem/$i" >> "$codes"; done
distinct=$(sort -u "$codes" | count_lines .)
(( distinct > 0 )) || { warn "link oluşturulamadı"; exit 2; }
note "farklı kod: $distinct"

# Pod'un KENDİ önbellek kayıt sayısı. Metrik yoksa (süreç içi önbellek yok) 0.
entries() { curl -s --max-time 5 "http://127.0.0.1:$PF_PORT/metrics" 2>/dev/null | awk '$1 == "cache_entries" {v = $2} END {printf "%d", v + 0}'; }
step "AYNI $distinct kodu her pod'a doğrudan okut ($reps pod, ingress'siz)"
added=0; readok=0
on_cleanup "port_forward_stop"
for pod in $pods; do
  port_forward "$pod" "$PF_PORT"
  before=$(entries)
  # `|| true`: tek bir curl zaman aşımına uğrarsa xargs 123 döner ve pipefail atamayı düşürürdü.
  ok=$( { xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://127.0.0.1:$PF_PORT/{}" < "$codes" 2>/dev/null || true; } | count_lines '^30[0-9]$')
  after=$(entries)
  port_forward_stop
  note "$pod: $ok/$distinct yönlendirme · önbellek kaydı $before → $after (+$(( after - before )))"
  added=$(( added + after - before )); readok=$(( readok + ok ))
done
(( readok > 0 )) || { warn "hiçbir pod'a doğrudan okunamadı (port-forward?) — ölçüm yok"; exit 2; }

sleep 12
grafana_hint "04 · Cache → 'Önbellekteki kayıt (pod'a göre)' · 01 · Pods & Resources → 'Heap bellek (Go)'"
factor=$(awk -v a="$added" -v d="$distinct" 'BEGIN{printf "%.1f", (d > 0 ? a / d : 0)}')
note "pod'lara eklenen kayıt toplamı: $added · farklı kod: $distinct → her kod ortalama $factor kez tutuluyor (replika: $reps)"
note "Ölçek hesabı: 1M sıcak link × 200 byte × 10 pod = 2 GB — aynı veri için 10 kez."
note "Çözüm 04: tek paylaşılan önbellek → bellek bir kez ödenir, ama ağ RTT'si eklenir (P04-02)."
awk -v f="$factor" 'BEGIN{exit !(f > 1.5)}' \
  && reproduced "aynı $distinct kod $factor kopya hâlinde tutuluyor ($reps pod'un her biri kendi kopyasını tuttu)"
not_reproduced "pod'larda kopya çoğalması yok (kod başına $factor kayıt) — paylaşılan önbellek (04)"
