#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P14-03 · Partition sayısı arttı: tüketici paralelliği ARTIK gerçek
# P06-03'te tek partition, tüketici replikalarını anlamsız kılıyordu. 14'te 3 partition var.
# Bu script tavanın kalktığını doğruluyor — ve yeni sınırın ne olduğunu söylüyor.
ensure_healthy
rp=$(dep_pod app.kubernetes.io/name=redpanda) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
step "Topic yapılandırması"
parts=$(kubectl -n "$NS" exec "$rp" -- rpk topic describe clicks -p 2>/dev/null | grep -c '^[0-9]' || echo "?") || true
note "clicks partition sayısı: ${parts:-?}"
kedamax=$(kubectl -n "$NS" get scaledobject analytics -o jsonpath='{.spec.maxReplicaCount}' 2>/dev/null) || true
note "KEDA maxReplicaCount: ${kedamax:-?} (partition sayısını AŞMAMALI — fazlası boşta oturur)"
# ÖLÇÜ DEĞİŞİKLİĞİ: "partition sayısı > 1" bir YAPILANDIRMA olgusudur, DAVRANIŞ değil.
# EN: the first version generated hot-key load and watched for KEDA to scale up. It never did —
#     the lag peaked at 14 against a threshold of 500, so the consumer stayed at ONE pod and the
#     script still said REPRODUCED, because its verdict only checked the partition count. The
#     claim is "consumer parallelism is now real"; a partition count does not demonstrate that.
#     Now we FORCE the replica count (KEDA's paused-replicas annotation — the supported way to
#     pin a ScaledObject) and count how many pods actually commit records. At one partition two
#     of the three sit idle no matter what; at three they all work. That is the claim, measured.
# TR: ilk hâl hot-key yükü üretip KEDA'nın ölçeklenmesini izliyordu. Hiç ölçeklenmedi — lag 14'te
#     tepe yaptı, eşik ise 500; tüketici TEK pod'da kaldı ve script yine REPRODUCED dedi, çünkü
#     kararı yalnızca partition sayısına bakıyordu. İddia "tüketici paralelliği ARTIK gerçek";
#     bir partition sayısı bunu göstermez.
#     Artık replika sayısını ZORLUYORUZ (KEDA'nın paused-replicas anotasyonu — bir ScaledObject'i
#     sabitlemenin desteklenen yolu) ve kaç pod'un gerçekten kayıt işlediğini sayıyoruz. Tek
#     partition'da üçün ikisi ne yaparsan yap boşta oturur; üç partition'da üçü de çalışır.
step "Tüketiciyi 3 replikaya SABİTLE (KEDA duraklatılır) ve yük ver"
on_cleanup "kubectl -n \"$NS\" annotate scaledobject analytics autoscaling.keda.sh/paused-replicas- --overwrite >/dev/null 2>&1 || true"
kubectl -n "$NS" annotate scaledobject analytics autoscaling.keda.sh/paused-replicas=3 --overwrite >/dev/null 2>&1 || true
kubectl -n "$NS" rollout status "$(wl analytics)" --timeout=180s >/dev/null 2>&1 || true
( k6run hot-key --vus 60 --duration 60s >/dev/null 2>&1 || true ) &
kpid=$!
maxreps=0
for i in $(seq 1 25); do
  r=$(kubectl -n "$NS" get "$(wl analytics)" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || true
  (( ${r:-0} > maxreps )) && maxreps=${r:-0}
  sleep 3
done
wait_pid_quiet "$kpid"
sleep 20
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
# KARAR: kaç pod GERÇEKTEN kayıt işledi? Partition sayısı değil, ÇALIŞAN pod sayısı.
awk -v p="${parts:-1}" -v a="${active%%.*}" 'BEGIN{exit !(p>1 && a>1)}' \
  && reproduced "${parts} partition · ${maxreps} replika ayakta · ${active%%.*} pod GERÇEKTEN kayıt işledi ($(awk -v v="$rate" 'BEGIN{printf "%.0f", v}') kayıt/s, tepe lag ${lag%%.*}) — paralellik artık gerçek"
not_reproduced "paralellik gösterilemedi (partition=${parts:-?} · ayakta=$maxreps · iş yapan=${active%%.*}) — tek partition mı, yoksa yük tüm partition'lara dağılmadı mı?"
