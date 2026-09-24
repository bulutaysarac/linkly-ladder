#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-05 · Broker düşünce: producer tamponu dolar → BLOKLAMAK mı DÜŞÜRMEK mi?
# Bu, P05-02'deki sorunun bir kat aşağı taşınmış hâli. Kafka istemcisi asenkron ama "hiç
# beklemez" değil: franz-go'nun kendi tamponu 10.000 kayıtta DOLAR ve Produce çağıranı BLOKLAR —
# yani redirect isteğini. Sınırı biz koyup aşanı DÜŞÜRÜYORUZ ve kaydı bekleme yapmayan TryProduce
# ile ekliyoruz: bir broker kesintisi ANALİTİĞİ bozabilir, redirect'i ASLA.
# (10.000'de bloklamanın birim testi: internal/stream/producer_test.go)
ensure_healthy
need_confirm "redpanda durdurulacak"
# SINIRI KÜÇÜLT, YOKSA DÜŞÜRME YOLU HİÇ SINANMAZ. Varsayılan 50.000 kayıt; 40 sn'lik bir kesintide
# pod başına tampon oraya çıkmaz ve "atılan" sayacı sıfırda kalır — deney, iddia ettiği düşürmeyi
# hiç görmeden "izolasyon çalıştı" der. Ölçmek istediğin rejime ulaşamıyorsan rejimi deneye getir
# (kural 7): sınır bu deney boyunca BUF_TEST (varsayılan 500).
# EN: shrink the bound or the drop path is never exercised: at the default 50,000 a 40 s outage
#     never fills a pod's buffer, the drop counter stays at 0 and the verdict never sees a drop.
orig_buf=$(kubectl -n "$NS" get "$(app_workload)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="PRODUCER_MAX_BUFFERED")]}{.value}{end}' 2>/dev/null) || true
if [[ -n "$orig_buf" ]]; then on_cleanup "setenv \"$(app_workload)\" PRODUCER_MAX_BUFFERED=$orig_buf"
else on_cleanup "setenv \"$(app_workload)\" PRODUCER_MAX_BUFFERED-"; fi
BUF=${BUF_TEST:-500}
setenv "$(app_workload)" PRODUCER_MAX_BUFFERED="$BUF" >/dev/null
settle_rollout "$(app_workload)"
note "üretici tampon sınırı bu deney için $BUF (manifest: ${orig_buf:-kod varsayılanı 50000})"
step "Broker ayaktayken taban: redirect p99"
k6run redirect --vus 20 --duration 30s >/dev/null 2>&1 || true
sleep 10
base_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
note "broker ayakta: redirect p99=$(awk -v v="$base_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
step "Broker'ı durdur (replicas=0) ve AYNI yükü ver"
on_cleanup "kubectl -n \"$NS\" rollout status statefulset/redpanda --timeout=180s"
on_cleanup "kubectl -n \"$NS\" scale statefulset redpanda --replicas=1"
kubectl -n "$NS" scale statefulset redpanda --replicas=0 >/dev/null
sleep 10
k6run redirect --vus 20 --duration 40s >/dev/null 2>&1 || true
sleep 8
down_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
e5=$(k6_5xx)
buffered=$(promq "max_over_time(max(producer_buffered_records{namespace=\"$NS\"})[3m:10s])")
dropped=$(promq "sum(increase(producer_records_total{namespace=\"$NS\",result=\"dropped\"}[5m]))")
perr=$(promq "sum(increase(producer_records_total{namespace=\"$NS\",result=\"error\"}[5m]))")
mem=$(peak_working_set_mb 5m)
grafana_hint "08 · Stream → 'Üretici tamponu ve atılanlar' · 02 · App RED → 'Gecikme (p50 / p95 / p99)' · 01 · Pods → 'Bellek kullanımı'"
note "broker YOK: redirect p99=$(awk -v v="$down_p99" 'BEGIN{printf "%.0f", v*1000}') ms · 5xx=$e5"
note "pod başına tampon tepe=${buffered%%.*}/$BUF · düşürülen=${dropped%%.*} · producer hata=${perr%%.*} · tepe bellek=${mem}MB"
note "ASIL SONUÇ: redirect ÇALIŞMAYA DEVAM ETTİ. Analitik durdu, kullanıcı etkilenmedi."
note "Bu bir tasarım tercihidir: Record() bloklasaydı broker kesintisi doğrudan bir SİTE kesintisi olurdu."
note "Kütüphanenin varsayılanı daha da sinsi: 10.000 kayıtta Produce BEKLER — redirect broker'ı beklerdi."
note "Sınırsız tamponlasaydık bellek dolar, pod OOM olur ve yine site çökerdi."
note "Kural: her asenkron sınırın (kuyruk, tampon, retry) bir ÜST SINIRI ve bir DÜŞÜRME politikası olmalı."
kubectl -n "$NS" scale statefulset redpanda --replicas=1 >/dev/null
# "Hiç 5xx olmasın" yanlış eşik: broker'ı replicas=0 yapmak aynı zamanda bir POD KAPANIŞI
# üretiyor ve o pencerede birkaç bağlantı düşüyor. Ölçtüğümüz iddia "üretici istek yolunu
# BLOKLAMIYOR" — bunun karşılığı mutlak sıfır değil, ihmal edilebilir bir hata ORANI.
reqs=$(k6_reqs)
err_pct=$(awk -v e="$e5" -v r="$reqs" 'BEGIN{printf "%.2f", (r>0? e*100/r : 100)}')
note "broker yokken hata oranı: %$err_pct ($e5 / $reqs istek) — eşik %1"
awk -v p="$err_pct" 'BEGIN{exit !(p < 1.0)}' \
  || not_reproduced "broker kesintisi redirect'i etkiledi (%$err_pct hata, $e5/$reqs) — üretici istek yolunu bloklamış olabilir"
# İddianın ikinci yarısı: tampon SINIRDA durdu ve aşan kayıtlar DÜŞÜRÜLDÜ. Düşürme yoksa iki ayrı
# durum var: tampon sınıra hiç ulaşmadı (ölçemedik) ya da ulaştı ve yine de düşürülmedi (iddia yanlış).
if awk -v d="${dropped%%.*}" 'BEGIN{exit !(d > 0)}'; then
  reproduced "broker kesintisinde tampon sınırda durdu (tepe ${buffered%%.*}/$BUF, düşürülen ${dropped%%.*}) ve redirect %$err_pct hata oranıyla sürdü — izolasyon çalıştı"
fi
if awk -v b="${buffered%%.*}" -v l="$BUF" 'BEGIN{exit !(b < l)}'; then
  warn "ölçüm yapılamadı: pod başına tampon sınıra ulaşmadı (tepe ${buffered%%.*}/$BUF) — BUF_TEST'i düşür ya da yükü artır."
  exit 2
fi
not_reproduced "tampon sınıra dayandı (tepe ${buffered%%.*}/$BUF) ama hiçbir kayıt düşürülmedi — sınır uygulanmıyor"
