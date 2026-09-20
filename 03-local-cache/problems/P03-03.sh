#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-03 · Aynı veri N pod'da N kez: bellek çarpanı
# 100 bin sıcak link × 3 pod = 3 kopya. Ölçek büyüdükçe bu çarpan ödediğin RAM olur.
ensure_healthy
reps=$(replicas_of)
N=${N:-3000}
step "$N farklı linke eşit dağılımlı okuma — hepsi her pod'un önbelleğine girsin"
codes=$(mktemp)
for i in $(seq 1 "$N"); do create_link "https://example.com/mem/$i" >> "$codes"; done
for round in 1 2; do while read -r c; do [[ -n "$c" ]] && status_of "$c" >/dev/null; done < "$codes"; done
rm -f "$codes"
sleep 12
step "Pod başına önbellek kayıt sayısı ve heap"
curl -sG "$PROM_URL/api/v1/query" --data-urlencode "query=cache_entries{namespace=\"$NS\"}" \
  | jq -r '.data.result[] | "    \(.metric.pod): \(.value[1]) kayıt"'
total=$(promq "sum(cache_entries{namespace=\"$NS\"})")
uniq=$(promq "max(cache_entries{namespace=\"$NS\"})")
heap=$(promq "sum(go_memstats_heap_alloc_bytes{namespace=\"$NS\"})")
grafana_hint "04 · Cache → 'entries by pod' · 01 · Pods & Resources → 'Heap alloc'"
note "toplam kayıt (tüm pod'lar): ${total%%.*} · en dolu pod: ${uniq%%.*} · toplam heap: $(( ${heap%%.*} / 1024 / 1024 )) MB"
note "Aynı $N link için ~$(awk -v t="$total" -v u="$uniq" 'BEGIN{printf "%.1f", (u>0? t/u : 0)}')× bellek ödüyorsun (replika sayısı: $reps)."
note "Ölçek hesabı: 1M sıcak link × 200 byte × 10 pod = 2 GB — aynı veri için 10 kez."
note "Çözüm 04: tek paylaşılan önbellek → bellek bir kez ödenir, ama ağ RTT'si eklenir (P04-02)."
awk -v t="${total%%.*}" -v u="${uniq%%.*}" 'BEGIN{exit !(u>0 && t > u*1.5)}' \
  && reproduced "aynı veri $(awk -v t="$total" -v u="$uniq" 'BEGIN{printf "%.1f", t/u}') kopya halinde tutuluyor (${total%%.*} toplam kayıt)"
not_reproduced "kopya çoğalması yok — paylaşılan önbellek (04)"
