#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P14-03 · Partition sayısı arttı: tüketici paralelliği ARTIK gerçek
# P06-03'te tek partition, tüketici replikalarını anlamsız kılıyordu. 14'te 3 partition var.
# Bu script tavanın kalktığını doğruluyor — ve yeni sınırın ne olduğunu söylüyor.
ensure_healthy
rp=$(dep_pod app.kubernetes.io/name=redpanda) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
step "Topic yapılandırması"
parts=$(kubectl -n "$NS" exec "$rp" -- rpk topic describe clicks -p 2>/dev/null | grep -c '^[0-9]' || echo "?")
note "clicks partition sayısı: ${parts:-?}"
kedamax=$(kubectl -n "$NS" get scaledobject analytics -o jsonpath='{.spec.maxReplicaCount}' 2>/dev/null) || true
note "KEDA maxReplicaCount: ${kedamax:-?} (partition sayısını AŞMAMALI — fazlası boşta oturur)"
step "Yoğun tıklama yükü ver, tüketicinin ölçeklenmesini izle"
( k6run hot-key --vus 60 --duration 60s >/dev/null 2>&1 || true ) &
kpid=$!
maxreps=0
for i in $(seq 1 25); do
  r=$(kubectl -n "$NS" get deploy analytics -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || true
  (( ${r:-0} > maxreps )) && maxreps=${r:-0}
  sleep 3
done
wait $kpid || true
sleep 15
active=$(promq "count(count by (pod) (rate(consumer_records_total{namespace=\"$NS\",result=\"ok\"}[3m]) > 0))")
rate=$(promq "max_over_time(sum(rate(consumer_records_total{namespace=\"$NS\",result=\"ok\"}[30s]))[5m:15s])")
lag=$(promq "max_over_time(sum(redpanda_kafka_max_offset{namespace=\"$NS\"} - on(redpanda_topic, redpanda_partition) group_left redpanda_kafka_consumer_group_committed_offset{namespace=\"$NS\"})[5m:15s])")
grafana_hint "08 · Stream → 'consumer lag by partition' + 'commit/s & pods' · 09 · Autoscaling → KEDA"
note "tepe tüketici replikası: $maxreps · gerçekten iş yapan pod: ${active%%.*} · tepe işleme hızı: $(awk -v v="$rate" 'BEGIN{printf "%.0f", v}') kayıt/s · tepe lag: ${lag%%.*}"
note "P06-03 ile fark: orada 3 replika açmak hiçbir şey değiştirmiyordu (1 partition tavanı)."
note "Yeni sınır: partition sayısı. Onu artırmak da bedava değil —"
note "  · partition başına sıra garantisi var, GLOBAL sıra yok"
note "  · partition sayısı AZALTILAMAZ (yalnızca artırılır)"
note "  · anahtar dağılımı değişir: mevcut anahtarlar yeni partition'lara taşınır ve"
note "    o an için SIRA GARANTİSİ kırılır (aynı kodun eski ve yeni olayları farklı partition'larda)"
note "Yani 'partition artır' bir ölçekleme düğmesi değil, planlanması gereken bir DEĞİŞİKLİKTİR."
awk -v p="${parts:-1}" 'BEGIN{exit !(p>1)}' \
  && reproduced "partition sayısı ${parts} → tüketici paralelliği gerçek (tepe $maxreps replika, ${active%%.*} aktif, $(awk -v v="$rate" 'BEGIN{printf "%.0f", v}') kayıt/s)"
not_reproduced "hâlâ tek partition (rpk topic add-partitions clicks -n 3)"
