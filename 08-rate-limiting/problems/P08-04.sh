#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-04 · Sabit pencere sayacı: pencere SINIRINDA limitin iki katı geçer
# Sabit pencere basit ve yanlıştır: 10 sn'lik pencerede 300 limit varsa, 9.9. saniyede 300 ve
# 10.1. saniyede 300 daha geçer — 0.2 saniyede 600. Kayan pencere bunu ağırlıklı toplamla düzeltir.
#
# ÖLÇÜM NOTU (bu scriptin kendi tarihi):
# İlk hâli tuzağı HİÇ AÇMIYORDU: yalnızca kayan pencereyi ölçüp "sabit pencere olsaydı 2x geçerdi"
# diye bir NOT basıyordu. Tuzak da config'de tanımlı ama kodda okunmuyordu — yani iddia iki
# taraftan birden sınanamaz durumdaydı ve script düşemezdi. Düşemeyen bir deney, deney değildir.
# Artık iki pencere de GERÇEKTEN koşuluyor ve tepe kabul hızı KARŞILAŞTIRILIYOR.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
need_metric ratelimit_decisions_total "limiter Redis'e bağlı mı? (08 deploy/redirect-svc.yaml)"
on_cleanup "setenv "$(wl redirect)" TRAP_FIXED_WINDOW-"
win=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_WINDOW")]}{.value}{end}') || true
lim=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_PER_IP")]}{.value}{end}') || true
WIN_S=${win:-10s}; WIN_S=${WIN_S%s}; LIM=${lim:-300}
note "pencere=${win:-10s} · IP başına limit=$LIM"

# TEK POD: limiter PAYLAŞILAN (Redis) ama `ratelimit_decisions_total` sayacı POD BAŞINA tutulur.
# Üç replikayla tek pod'un /metrics'ini örneklemek, kabul edilen isteklerin yalnızca üçte birini
# görmek demektir — ve "limit aşıldı mı?" sorusu tam olarak TOPLAM sayı üzerinedir.
# Ölçtüğün şey paylaşılan bir toplamsa, onu parçalara bölen bir topolojide ölçme.
# EN: the limiter is shared (Redis) but the decision counter is per-pod. Sampling one pod out of
# three measures a third of the accepted requests, while the question is about the TOTAL.
on_cleanup "scale 2"   # manifest 2 replika ilan ediyor
kubectl -n "$NS" scale "$(wl redirect)" --replicas=1 >/dev/null; wait_endpoints 1; sleep 3

# Tepe kabul hızını ÖLÇ: pencere uzunluğu kadar bir aralıkta kaç istek KABUL edildi?
# Prometheus'un çözünürlüğü (30 sn scrape) pencere sınırındaki 0.2 saniyelik sıçramayı yutar,
# bu yüzden sayaç farkını doğrudan pod'un /metrics ucundan, saniyede bir örnekleyerek alıyoruz.
measure_peak() {
  local pod out
  pod=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
  [[ -z "$pod" ]] && { echo 0; return; }
  out=$(mktemp)
  ( k6run burst >/dev/null 2>&1 || true ) &
  local kpid=$!
  # allow sayacının saniyelik artışını topla; pencere uzunluğu kadar KAYAN TOPLAMın tepesi
  sample_series "$pod" 70 "$out" 'ratelimit_decisions_total.*decision="allow".*key_type="ip"' 2 || true
  wait_pid_quiet "$kpid"
  awk -v w="$WIN_S" '{a[NR]=$1} END{
    best=0
    for(i=1;i<=NR;i++){s=0; for(j=i;j<i+w && j<=NR;j++) s+=a[j]; if(s>best) best=s}
    printf "%d", best
  }' "$out"
  rm -f "$out"
}

step "(1) KAYAN pencere (varsayılan)"
slide=$(measure_peak)
note "kayan: ${WIN_S} sn'lik en yoğun aralıkta kabul edilen istek = $slide (limit $LIM)"

step "(2) TRAP_FIXED_WINDOW: sabit pencere sayacı"
setenv "$(wl redirect)" TRAP_FIXED_WINDOW=true
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
fixed=$(measure_peak)
note "sabit: ${WIN_S} sn'lik en yoğun aralıkta kabul edilen istek = $fixed (limit $LIM)"

grafana_hint "10 · Rate limit → 'Kabul edilen rps (sınır testi)' + 'decisions by key type'"
note "Sabit pencerede iki komşu pencerenin sınırı ÜST ÜSTE binebilir: her kontrol kendi penceresinde"
note "'limit içinde' der ve toplamda limitin iki katına kadar istek geçer. Kayan pencere sayacı,"
note "önceki pencerenin sayımını pencerede ne kadar ilerlediğine göre AĞIRLIKLANDIRARAK bunu kapatır"
note "(internal/ratelimit/redis.go — slidingWindowLua vs fixedWindowLua)."
note "Daha kesin alternatifler: sliding window LOG (her isteğin zaman damgası — pahalı) ve"
note "token bucket (patlamaya izin verir, ortalamayı korur). Seçim, 'burst'e izin var mı?' sorusudur."
note "Not: sabit pencere HER ZAMAN 2x geçirmez — yalnızca yük sınıra denk gelirse. Bu da onu daha"
note "kötü yapar: hata ayıklanması zor, çünkü tekrar üretmek için ZAMANLAMAYI yakalaman gerekir."
awk -v f="$fixed" -v s="$slide" -v l="$LIM" 'BEGIN{exit !(f > s && f > l)}' \
  && reproduced "sabit pencere limiti aştı: tepe $fixed > limit $LIM (kayan pencerede $slide)"
not_reproduced "fark ölçülemedi (kayan=$slide · sabit=$fixed · limit=$LIM) — yük sınıra denk gelmemiş olabilir, PEAK'i artır"
