#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-05 · Gözlemlenebilirliğin de bir kapasitesi vardır: debug log Loki'yi limitler
# "Sorun yaşıyoruz, log seviyesini debug yapalım" — ve tam o anda log boru hattı doluyor,
# Loki 429 dönmeye başlıyor ve SORUNU ARAŞTIRDIĞIN LOGLAR KAYBOLUYOR. Gözlemlenebilirlik,
# gözlemlediği sistemden bağımsız değildir; onunla birlikte ölçeklenmesi gerekir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" LOG_LEVEL=info"
loki_rejects() {
  promq 'sum(increase(loki_discarded_samples_total[3m])) or sum(increase(loki_request_duration_seconds_count{status_code="429"}[3m])) or vector(0)'
}
# İSTEK BAŞINA BAYT. Faz ortalaması (bayt/s) iki fazın TRAFİĞİNİ de karşılaştırır: ikinci fazın pod'ları
# yeni kalktığı için ilk saniyelerde az istek alır ve debug fazı daha az log üretmiş görünür. Soru
# "aynı istek ne kadar log üretiyor?" — o hâlde ölçü, pencerede Loki'ye giren bayt / uygulamanın
# cevapladığı istek.
# EN: bytes/s compares the phases' traffic too (fresh pods warm up slowly); the question is how
#     much log one request produces, so divide by the requests served in the same window.
per_req() {  # $1 = pencere (sn) → "bayt_per_istek istek"
  local b q
  b=$(promq "sum(increase(loki_distributor_bytes_received_total[${1}s])) or vector(0)")
  q=$(promq "sum(increase(http_requests_total{namespace=\"$NS\"}[${1}s])) or vector(0)")
  awk -v b="$b" -v q="$q" 'BEGIN{printf "%.0f %.0f", (q>0? b/q : 0), q}'
}
step "(1) LOG_LEVEL=info (varsayılan) altında yük"
# FAZ BAŞINA PENCERE. Sabit bir `rate(...[2m])` her iki fazda da KOMŞU fazın trafiğini içerir:
# ikinci ölçüm, yeni pod'lar daha yeni ayağa kalkmışken birinci fazın kuyruğunu okur ve sonuç
# ters çıkar — debug seviyesinde bayt/s DAHA DÜŞÜK görünür, ki bu fiziksel olarak saçmadır.
# Her faz kendi süresi kadar bir pencere okur.
# EN: a fixed [2m] window straddles both phases; the second reading is dominated by the first
# phase's tail while the new pods have barely started, so debug appears to log LESS than info.
T0=$(date +%s)
k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 15
W1=$(( $(date +%s) - T0 ))
r1=$(loki_rejects)
ingest1=$(promq "sum(increase(loki_distributor_bytes_received_total[${W1}s]) ) / ${W1} or vector(0)")
read -r bpr1 q1 <<< "$(per_req "$W1")"
note "info: Loki reddi=${r1%%.*} · alınan bayt/s=$(awk -v v="$ingest1" 'BEGIN{printf "%.0f", v}') · istek=$q1 · istek başına log=$bpr1 bayt"
step "(2) LOG_LEVEL=debug ile AYNI yük"
setenv "$(wl redirect)" LOG_LEVEL=debug >/dev/null
settle_rollout "$(wl redirect)"
T0=$(date +%s)
k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 15
W2=$(( $(date +%s) - T0 ))
r2=$(loki_rejects)
ingest2=$(promq "sum(increase(loki_distributor_bytes_received_total[${W2}s]) ) / ${W2} or vector(0)")
read -r bpr2 q2 <<< "$(per_req "$W2")"
note "debug: Loki reddi=${r2%%.*} · alınan bayt/s=$(awk -v v="$ingest2" 'BEGIN{printf "%.0f", v}') · istek=$q2 · istek başına log=$bpr2 bayt"
grafana_hint "Explore → Loki: {namespace=\"$NS\"} sorgusunda boşluk var mı? · platform/helm/loki.values.yaml → ingestion_rate_mb"
note "Loki'nin limiti platform/helm/loki.values.yaml'da: ingestion_rate_mb=8. Aşınca kayıtlar DÜŞER."
note "Araçlar: (a) log seviyesini ÇALIŞIRKEN değiştirebilmek (burada env + rollout; daha iyisi"
note "runtime endpoint), (b) log SAMPLING (her N'inci satır), (c) yüksek hacimli alanları trace'e"
note "taşımak — tek istek detayı log'un değil trace'in işi."
note "Asıl ders: teşhis araçların, teşhis ettiğin olay sırasında ÇALIŞMAYA DEVAM ETMELİ."
note "Gözlemlenebilirliği kapasite planlamasının dışında tutmak, onu tam gerektiği anda kaybetmektir."
# Yük üreteci koşmadıysa oran 0'dır ve "fark yok" sanılır: istek sayısı hüküm önkoşulu.
if [[ "$q1" == 0 || "$q2" == 0 || "$bpr1" == 0 ]]; then
  warn "ölçüm yok: fazlardan birinde istek ya da Loki baytı sayılmadı (istek $q1/$q2, bayt/istek $bpr1/$bpr2) — Loki metrikleri Prometheus'ta mı?"
  exit 2
fi
# %5 pay: arka plan logları (diğer namespace'ler) iki fazda aynı değil; debug satırı istek başına
# erişim logunun yanına bir satır daha ekler, fark bunun çok üstünde olmalı.
awk -v a="$bpr1" -v b="$bpr2" 'BEGIN{exit !(b > a * 1.05)}' \
  && reproduced "debug seviyesi istek başına log hacmini $bpr1 → $bpr2 bayt'a çıkardı ($(awk -v a="$bpr1" -v b="$bpr2" 'BEGIN{printf "%+.0f%%", (b/a-1)*100}'); toplam $(awk -v v="$ingest1" 'BEGIN{printf "%.0f", v}') → $(awk -v v="$ingest2" 'BEGIN{printf "%.0f", v}') bayt/s, Loki reddi ${r1%%.*} → ${r2%%.*})"
not_reproduced "istek başına log hacmi değişmedi ($bpr1 → $bpr2 bayt) — LOG_LEVEL=debug yeni pod'lara ulaştı mı?"
