#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-03 · Tek partition = tek tüketici. Replika eklemek hiçbir şey değiştirmez.
# Kafka'da paralelliğin ÜST SINIRI partition sayısıdır: bir partition'ı aynı grupta yalnızca bir
# tüketici okuyabilir. 3 replika açarsan 2'si boşta oturur — ölçekleme yanılsaması.
ensure_healthy
CONSUMER=analytics
on_cleanup "kubectl -n \"$NS\" scale "$(wl $CONSUMER)" --replicas=1"
rp=$(dep_pod app.kubernetes.io/name=redpanda) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
rpk() { kubectl -n "$NS" exec "$rp" -- rpk "$@" 2>/dev/null; }
step "Topic'in partition sayısı"
rpk topic describe clicks 2>/dev/null | head -6 | sed 's/^/    /' || true
parts=$(rpk topic describe clicks -p 2>/dev/null | grep -c '^[0-9]' || echo 1)
note "partition sayısı: ${parts:-1}"
measure() {
  local reps=$1
  kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas="$reps" >/dev/null
  kubectl -n "$NS" rollout status "$(wl $CONSUMER)" --timeout=120s >/dev/null 2>&1 || true
  sleep 8
  local code b t0 t1
  code=$(create_link "https://example.com/part/$reps")
  b=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0') || true
  t0=$(date +%s)
  k6run hot-key --vus 40 --duration 30s >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    local w; w=$(promq "sum(rate(consumer_records_total{namespace=\"$NS\",result=\"ok\"}[30s]))")
    awk -v v="$w" 'BEGIN{exit !(v < 1)}' && break
    sleep 3
  done
  t1=$(date +%s)
  promq "max_over_time(sum(rate(consumer_records_total{namespace=\"$NS\",result=\"ok\"}[30s]))[3m:15s])"
}
step "1 tüketici ile işleme hızı"
one=$(measure 1); note "1 replika → tepe işleme hızı $(awk -v v="$one" 'BEGIN{printf "%.0f", v}') kayıt/s"
step "3 tüketici ile AYNI yük"
three=$(measure 3)
active=$(promq "count(count by (pod) (rate(consumer_records_total{namespace=\"$NS\",result=\"ok\"}[2m]) > 0))")
note "3 replika → tepe işleme hızı $(awk -v v="$three" 'BEGIN{printf "%.0f", v}') kayıt/s · gerçekten iş yapan pod: ${active%%.*}"
grafana_hint "08 · Stream → 'consumer lag by partition' + 'consumer commit/s & pods'"
note "Partition sayısı tüketici paralelliğinin TAVANIDIR. ${parts:-1} partition ile 3 pod açmak,"
note "2 pod'u boşta oturtmak demektir — üstelik onlar da kaynak tüketir ve 'ölçekledik' yanılsaması yaratır."
note "Çözüm: partition sayısını artır (rpk topic add-partitions clicks -n 6)."
note "Bedeli: partition BAŞINA sıra garantisi vardır, GLOBAL sıra yoktur. Anahtarı (kısa kod) doğru"
note "seçmek bu yüzden önemli: aynı linkin olayları aynı partition'a düşer, sırası korunur."
awk -v a="$one" -v b="$three" 'BEGIN{exit !(b < a*1.5)}' \
  && reproduced "tüketiciyi 3 katına çıkarmak işleme hızını artırmadı ($(awk -v v="$one" 'BEGIN{printf "%.0f", v}') → $(awk -v v="$three" 'BEGIN{printf "%.0f", v}') kayıt/s) — ${parts:-1} partition tavanı"
not_reproduced "replika artışı hızı artırdı — partition sayısı yeterli"
