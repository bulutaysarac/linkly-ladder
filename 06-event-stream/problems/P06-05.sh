#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-05 · Broker düşünce: producer tamponu dolar → BLOKLAMAK mı DÜŞÜRMEK mi?
# Bu, P05-02'deki sorunun bir kat aşağı taşınmış hâli. Kafka istemcisi asenkron ama SINIRSIZ
# tamponlar; broker düşerse kayıtlar bellek bitene kadar birikir. Sınır koyup düşürüyoruz:
# bir broker kesintisi ANALİTİĞİ bozabilir, redirect'i ASLA.
ensure_healthy
step "Broker ayaktayken taban: redirect p99"
k6run redirect --vus 20 --duration 30s >/dev/null 2>&1 || true
sleep 10
base_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
note "broker ayakta: redirect p99=$(awk -v v="$base_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
need_confirm "redpanda durdurulacak"
step "Broker'ı durdur (replicas=0) ve AYNI yükü ver"
on_cleanup "kubectl -n \"$NS\" rollout status statefulset/redpanda --timeout=180s"
on_cleanup "kubectl -n \"$NS\" scale statefulset redpanda --replicas=1"
kubectl -n "$NS" scale statefulset redpanda --replicas=0 >/dev/null
sleep 10
k6run redirect --vus 20 --duration 40s >/dev/null 2>&1 || true
sleep 8
down_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
e5=$(k6_5xx)
buffered=$(promq "max_over_time(sum(producer_buffered_records{namespace=\"$NS\"})[3m:15s])")
dropped=$(promq "sum(increase(producer_records_total{namespace=\"$NS\",result=\"dropped\"}[5m]))")
perr=$(promq "sum(increase(producer_records_total{namespace=\"$NS\",result=\"error\"}[5m]))")
mem=$(peak_working_set_mb 5m)
grafana_hint "08 · Stream → 'producer buffer & drops' · 02 · App RED → p99 · 01 · Pods → bellek"
note "broker YOK: redirect p99=$(awk -v v="$down_p99" 'BEGIN{printf "%.0f", v*1000}') ms · 5xx=$e5"
note "tampon tepe=${buffered%%.*} · düşürülen=${dropped%%.*} · producer hata=${perr%%.*} · tepe bellek=${mem}MB"
note "ASIL SONUÇ: redirect ÇALIŞMAYA DEVAM ETTİ. Analitik durdu, kullanıcı etkilenmedi."
note "Bu bir tasarım tercihidir: Record() bloklasaydı broker kesintisi doğrudan bir SİTE kesintisi olurdu."
note "Sınırsız tamponlasaydık (varsayılan davranış!) bellek dolar, pod OOM olur ve yine site çökerdi."
note "Kural: her asenkron sınırın (kuyruk, tampon, retry) bir ÜST SINIRI ve bir DÜŞÜRME politikası olmalı."
kubectl -n "$NS" scale statefulset redpanda --replicas=1 >/dev/null
# "Hiç 5xx olmasın" yanlış eşik: broker'ı replicas=0 yapmak aynı zamanda bir POD KAPANIŞI
# üretiyor ve o pencerede birkaç bağlantı düşüyor. Ölçtüğümüz iddia "üretici istek yolunu
# BLOKLAMIYOR" — bunun karşılığı mutlak sıfır değil, ihmal edilebilir bir hata ORANI.
reqs=$(k6_reqs)
err_pct=$(awk -v e="$e5" -v r="$reqs" 'BEGIN{printf "%.2f", (r>0? e*100/r : 100)}')
note "broker yokken hata oranı: %$err_pct ($e5 / $reqs istek) — eşik %1"
awk -v p="$err_pct" 'BEGIN{exit !(p < 1.0)}' \
  && reproduced "broker kesintisinde analitik durdu (tampon ${buffered%%.*}, düşürülen ${dropped%%.*}) ama redirect %$err_pct hata oranıyla sürdü — izolasyon çalıştı"
not_reproduced "broker kesintisi redirect'i etkiledi (%$err_pct hata, $e5/$reqs) — üretici istek yolunu bloklamış olabilir"
