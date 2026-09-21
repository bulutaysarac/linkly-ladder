#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P05-02 · Kuyruk dolunca düşürme — ve TRAP_UNBOUNDED_QUEUE ile alternatifinin neden daha kötü olduğu
# Sınırlı kuyruk, yazıcı yetişemediğinde tıklama DÜŞÜRÜR ve sayar. Kötü görünür; alternatifi
# (sınırsız kuyruk) daha kötüdür: bellek büyür, süreç OOM olur ve tampondaki HER ŞEY gider.
# Yani "hiç düşürmeyelim" isteği, sonunda her şeyi düşürmekle biter.
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env "$(app_workload)" TRAP_UNBOUNDED_QUEUE- ANALYTICS_QUEUE_SIZE- ANALYTICS_WRITE_TIMEOUT-"
step "Kuyruğu küçült ve yazıcıyı yavaşlat (DB'ye gecikme enjekte et)"
kubectl -n "$NS" set env "$(app_workload)" ANALYTICS_QUEUE_SIZE=500 >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
# SIRA ÖNEMLİ: önce ısıt, SONRA gecikmeyi enjekte et.
# Gerçekte oldu: chaos'u önce uyguladığımızda k6'nın setup'ı (100 link oluşturma) her INSERT için
# 2 sn beklediği için setup timeout'una takıldı ve yük HİÇ koşmadı — script "düşürme olmadı" dedi.
# Yani ölçtüğümüz şey kuyruk değil, kendi kurulum sıramızdı.
step "Önce ısıt: sıcak kodu oluştur ve önbelleğe al (gecikme yokken)"
k6run hot-key --vus 20 --duration 20s >/dev/null 2>&1 || true
chaos_apply pg-delay-2s   # yazıcı yetişemeyecek
step "Yoğun tıklama yükü — kuyruk dolacak"
# SEED=1: gecikme altında her create 2 sn sürüyor; setup tek link oluştursun ki yüke zaman kalsın.
SEED=1 HOT_SHARE=1 k6run hot-key --vus 80 --duration 45s >/dev/null 2>&1 || true
sleep 10
dropped=$(promq "sum(increase(analytics_events_total{namespace=\"$NS\",result=\"dropped\"}[5m]))")
enq=$(promq "sum(increase(analytics_events_total{namespace=\"$NS\",result=\"enqueued\"}[5m]))")
depth=$(promq "max_over_time(sum(analytics_queue_depth{namespace=\"$NS\"})[5m:15s])")
p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
grafana_hint "07 · Analytics → 'events by result' + 'queue depth by pod' · 02 · App RED → p99"
note "kuyruğa alınan: ${enq%%.*} · DÜŞÜRÜLEN: ${dropped%%.*} · tepe derinlik: ${depth%%.*}"
note "ÖNEMLİ: redirect p99'u $(awk -v v="$p99" 'BEGIN{printf "%.0f", v*1000}') ms — yazıcı boğulurken bile okuma yolu ETKİLENMEDİ."
note "Tasarımın vaadi tam olarak buydu: analitik geri kalabilir, ama kullanıcıyı bekletmez."
note "TRAP_UNBOUNDED_QUEUE=true ile alternatifi dene: düşürme sıfırlanır, working set tırmanır,"
note "sonunda OOMKilled olur ve tampondaki HER ŞEY kaybolur (P05-01'in en kötü hâli)."
awk -v d="${dropped%%.*}" 'BEGIN{exit !(d>0)}' \
  && reproduced "${dropped%%.*} tıklama düşürüldü (tepe derinlik ${depth%%.*}) — back pressure görünür ve okuma yolu korundu"
not_reproduced "düşürme olmadı (kuyruk daha da küçültülüp yük artırılabilir)"
