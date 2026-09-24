#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-04 · Sabit pencere sayacı: pencere SINIRINDA limitin iki katı geçer
# Sabit pencere basit ve yanlıştır: 10 sn'lik pencerede 300 limit varsa, 9.9. saniyede 300 ve
# 10.1. saniyede 300 daha geçer — 0.2 saniyede 600. Kayan pencere bunu ağırlıklı toplamla düzeltir.
#
# ÖLÇÜM NOTU: yalnızca kayan pencereyi ölçüp "sabit pencere olsaydı 2x geçerdi" diye bir NOT
# basmak iddiayı sınamaz — script düşemez ve düşemeyen bir deney, deney değildir. Bu yüzden iki
# pencere de GERÇEKTEN koşulur (TRAP_FIXED_WINDOW gerçek Lua betiğini değiştirir) ve tepe kabul
# hızı KARŞILAŞTIRILIR.
limits_enforced   # bu script limiter'ı sınıyor — yük girişi ve muafiyet jetonu KULLANILMAZ
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
# LİMİT, DENEYİN BİR PARAMETRESİDİR. Tek pod bu kümede 400 rps'i servis edemiyor; yük limitin
# (300/10 sn = 30 rps) ÜSTÜNE hiç çıkmıyor ve reddedilen istek 0 kalıyor — yani pencere sınırı
# davranışı gözlenemiyor. Pod'u hızlandıramayız; limiti indirebiliriz. Ölçmek istediğin rejimi
# kuramıyorsan, sistemi o rejime SOK.
# EN: one pod cannot serve 400 rps here, so the offered load never exceeds the limit and nothing
# is ever denied — the boundary behaviour cannot be observed. We cannot make the pod faster; we
# can lower the limit. If you cannot reach the regime you want to measure, move the regime.
on_cleanup "setenv \"$(wl redirect)\" RATE_LIMIT_PER_IP-"
setenv "$(wl redirect)" RATE_LIMIT_PER_IP="${LIM_TEST:-60}" >/dev/null
settle_rollout "$(wl redirect)"
LIM=${LIM_TEST:-60}
note "deney için IP limiti geçici olarak $LIM/${WIN_S}s yapıldı (manifest değeri ${lim:-300})"

# Tepe kabul hızını ÖLÇ: pencere uzunluğu kadar bir aralıkta kaç istek KABUL edildi?
# Prometheus'un çözünürlüğü (uygulama için 10 sn scrape) pencere sınırındaki 0.2 saniyelik sıçramayı yutar,
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
  # Tepenin YANINDA toplamı ve örnek sayısını da döndür: "tepe 216 < limit 300" tek başına iki
  # ZIT şeyi anlatabilir — (a) limiter gerçekten bu kadarına izin verdi, (b) yük hiç o seviyeye
  # gelmedi ya da örnekleme deliklendi. Karar bu ikisini ayırt edemiyorsa hüküm de veremez.
  # EN: return the total and the sample count next to the peak. "peak 216 < limit 300" can mean
  # two OPPOSITE things — the limiter really allowed that much, or the load never got there (or
  # the sampling lost points). A verdict that cannot tell those apart is not a verdict.
  awk -v w="$WIN_S" '{a[NR]=$1; tot+=$1} END{
    best=0
    for(i=1;i<=NR;i++){s=0; for(j=i;j<i+w && j<=NR;j++) s+=a[j]; if(s>best) best=s}
    printf "%d %d %d", best, tot+0, NR
  }' "$out"
  rm -f "$out"
}
# Limiter'ın gerçekten ÇALIŞTIĞINI ve yükün sınıra dayandığını göster: reddedilen istek sayısı.
# allow ~ limit ve deny >> 0 ise bağlayıcı kısıt limiter'dır; deny ≈ 0 ise yük sınıra hiç
# gelmemiştir ve "sabit pencere 2x geçirmedi" demek anlamsızdır.
# ETİKET DEĞERİNİ KODDAN DOĞRULA: sayaç "deny" değil **"reject"** yazıyor
# (internal/ratelimit/redis.go → Decisions.WithLabelValues("reject", keyType)). Var olmayan bir
# etiket değeri sorgusu HATA VERMEZ; sessizce 0 döner ve "hiç reddedilmedi" gibi okunur — yani
# deneyin önkoşul kontrolü, kontrol ettiğini sanarak hep aynı cevabı verir. Bir metriği
# sorgulamadan önce üretildiği satıra bak.
# EN: a query for a label value that does not exist is not an error — it silently returns 0 and
# reads as "nothing was ever rejected", so the precondition check always answers the same way.
# Look at the line that produces the metric before you query it.
denies() { promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\",key_type=\"ip\"}[2m]))"; }

step "(1) KAYAN pencere (varsayılan)"
read -r slide slide_tot slide_n <<< "$(measure_peak)"
slide_deny=$(denies)
note "kayan: ${WIN_S} sn'lik en yoğun aralıkta kabul edilen istek = $slide (limit $LIM)"
note "       koşu boyunca kabul=$slide_tot · reddedilen=${slide_deny%%.*} · örnek=$slide_n/68"

step "(2) TRAP_FIXED_WINDOW: sabit pencere sayacı"
setenv "$(wl redirect)" TRAP_FIXED_WINDOW=true
# `rollout status` YENİ NESLİ BEKLEMEYEBİLİR (bkz. repro.sh → settle_rollout). Beklemezse
# `measure_peak` ESKİ, sonlanmakta olan pod'u seçer, örnekleme "pod not found" ile delik deşik
# olur ve faz, limiter sorunsuz çalışırken bile "0 kabul" raporlar.
# EN: without waiting for the new generation, `measure_peak` picks the OLD terminating pod, the
# sampling fails and the phase reports "0 accepted" while the limiter works fine.
settle_rollout "$(wl redirect)"
read -r fixed fixed_tot fixed_n <<< "$(measure_peak)"
fixed_deny=$(denies)
note "sabit: ${WIN_S} sn'lik en yoğun aralıkta kabul edilen istek = $fixed (limit $LIM)"
note "       koşu boyunca kabul=$fixed_tot · reddedilen=${fixed_deny%%.*} · örnek=$fixed_n/68"

grafana_hint "10 · Rate limit → 'Kararlar (anahtar türüne göre)' + 'Sınırdan geçen istek / sn (10 sn çözünürlük)'"
note "Sabit pencerede iki komşu pencerenin sınırı ÜST ÜSTE binebilir: her kontrol kendi penceresinde"
note "'limit içinde' der ve toplamda limitin iki katına kadar istek geçer. Kayan pencere sayacı,"
note "önceki pencerenin sayımını pencerede ne kadar ilerlediğine göre AĞIRLIKLANDIRARAK bunu kapatır"
note "(internal/ratelimit/redis.go — slidingWindowLua vs fixedWindowLua)."
note "Daha kesin alternatifler: sliding window LOG (her isteğin zaman damgası — pahalı) ve"
note "token bucket (patlamaya izin verir, ortalamayı korur). Seçim, 'burst'e izin var mı?' sorusudur."
note "Not: sabit pencere HER ZAMAN 2x geçirmez — yalnızca yük sınıra denk gelirse. Bu da onu daha"
note "kötü yapar: hata ayıklanması zor, çünkü tekrar üretmek için ZAMANLAMAYI yakalaman gerekir."
# YÜK SINIRA DAYANMADIYSA HÜKÜM VERME: deny ≈ 0 iken "sabit pencere limiti aşmadı" demek,
# limiter hakkında değil YÜK hakkında bir cümledir ve "sabit pencere sorunsuz" diye okunur.
if awk -v d="${slide_deny%%.*}" -v e="${fixed_deny%%.*}" 'BEGIN{exit !(d+0==0 || e+0==0)}'; then
  warn "ölçüm yapılamadı: yük limite dayanmadı (reddedilen: kayan=${slide_deny%%.*} sabit=${fixed_deny%%.*})."
  warn "Pencere sınırındaki taşma ancak yük sınırın ÜSTÜNDEYKEN görünür: PEAK=800 CONFIRM=1 make repro P=P08-04"
  warn "Bu bir "sorun yok" sonucu değil, EKSİK ÖLÇÜMdür."
  exit 2
fi
awk -v f="$fixed" -v s="$slide" -v l="$LIM" 'BEGIN{exit !(f > s && f > l)}' \
  && reproduced "sabit pencere limiti aştı: tepe $fixed > limit $LIM (kayan pencerede $slide)"
not_reproduced "fark ölçülemedi (kayan=$slide · sabit=$fixed · limit=$LIM; reddedilen ${slide_deny%%.*}/${fixed_deny%%.*}) — PEAK'i artır"
