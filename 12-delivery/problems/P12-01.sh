#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P12-01 · Kötü sürüm: rolling update %100'e taşır, analizli canary canary payında durdurur
# Rolling update "pod'ları değiştir ve umut et"tir. Analizli canary "bir kısmını değiştir, ÖLÇ,
# sonra karar ver"dir. Fark trafik dağılımında değil: kararı bir dashboard'a bakan İNSANIN değil,
# saniyeler içinde bir MAKİNENİN vermesinde.
# PAY %10 DEĞİL. Rollout'ta trafik yönlendirici yok; Argo `setWeight: 10`u POD SAYISIYLA yaklaşık
# tutuyor: 3 stable + 1 canary → Service trafiği 4'e böler, canary ~%25 alır. Script bu yüzden
# payı ve toplam oranı TAHMİN ETMİYOR, sürüm etiketinden (rollouts_pod_template_hash) ÖLÇÜYOR.
# EN: there is no traffic router, so the 10% weight is approximated by pod count: 1 canary next to
# 3 stable pods gets ~25% of the traffic. The script measures the share instead of assuming it.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv rollout/redirect BAD_VERSION_ERROR_PCT=0 2>/dev/null || true"
has_rollout=$(kubectl -n "$NS" get rollout redirect -o name 2>/dev/null) || true
[[ -z "$has_rollout" ]] && { warn "Rollout bulunamadı (Argo Rollouts kurulu mu? cd platform && make argo)"; exit 2; }
step "Mevcut sürüm sağlıklı mı?"
kubectl -n "$NS" get rollout redirect -o custom-columns=AŞAMA:.status.phase,HAZIR:.status.readyReplicas,GÜNCEL:.status.updatedReplicas --no-headers 2>/dev/null | sed 's/^/    /'
stable=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.status.stableRS}' 2>/dev/null) || true
note "stable sürümün pod şablonu hash'i: ${stable:-?} (Grafana'daki rollouts_pod_template_hash)"
step "KÖTÜ sürümü dağıt: kötü sürümün redirect'lerinin %25'i 500 dönecek"
( k6run redirect --vus 15 --duration 180s >/tmp/p1201.k6 2>&1 ) & kpid=$!
sleep 15
setenv rollout/redirect BAD_VERSION_ERROR_PCT=25 >/dev/null
note "canary başladı: 1 canary pod'u 3 stable'ın yanına ekleniyor → trafiğin ~1/4'ü kötü sürüme gidiyor"
note "(trafik yönlendirici yok: setWeight 10 pod sayısıyla yaklaşık tutulur). Analiz 30 sn sonra ilk ölçümü alır."
# "HEALTHY" ANCAK CANARY GÖRÜLDÜKTEN SONRA BİR SONUÇTUR. Ayar yazıldıktan hemen sonra kontrolcü durumu
# henüz güncellemedi: ilk okumalar ESKİ sürümün "Healthy"sidir. Onu "rollout tamamlandı" saymak, analiz
# daha başlamadan "kötü sürüm geçti" demektir. Durdurma da iki yerden okunur: faz Degraded ya da
# mesaj RolloutAborted (abort sonrası faz, stable'a dönüldüğü için yeniden Healthy görünebilir).
# EN: right after the change the controller still reports the OLD revision's Healthy; only a Healthy
#     seen after the canary appeared means "promoted". An abort shows as Degraded or RolloutAborted.
phase=""; aborted=0; canary=""
for i in $(seq 1 45); do
  cur=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.status.currentPodHash}' 2>/dev/null) || true
  [[ -n "$cur" && "$cur" != "${stable:-}" ]] && canary=$cur
  phase=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.status.phase}' 2>/dev/null) || true
  rmsg=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.status.message}' 2>/dev/null) || true
  if [[ "$phase" == "Degraded" || "$rmsg" == *RolloutAborted* ]]; then
    aborted=1; note "  → analiz BAŞARISIZ: rollout ~$((i*4)) sn içinde durduruldu"; break
  fi
  [[ "$phase" == "Healthy" && -n "$canary" ]] && { note "  → rollout tamamlandı: yeni sürüm stable oldu (analiz geçti)"; break; }
  sleep 4
done
wait $kpid || true
e5=$(k6_5xx); reqs=$(k6_reqs)
err_ratio=$(awk -v a="$e5" -v b="$reqs" 'BEGIN{printf "%.2f", (b>0? a*100/b : 0)}')
analysis=$(kubectl -n "$NS" get analysisrun -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.status.phase}{"\n"}{end}' 2>/dev/null | tail -3) || true
# PAY VE TOPLAM ORAN, sürüm etiketiyle ÖLÇÜLÜR (redirect ServiceMonitor'ündeki podTargetLabels).
# Pencere 30 sn: canary abort'a kadar ~1 dk yaşar; 1 dk'lık rate tepeyi yarıya indirirdi.
sel="namespace=\"$NS\",route=\"/{code}\""
share=0; canary_err=0
if [[ -n "$canary" ]]; then
  share=$(promq "max_over_time((sum(rate(http_requests_total{$sel,rollouts_pod_template_hash=\"$canary\"}[30s])) / sum(rate(http_requests_total{$sel}[30s])))[5m:10s])")
  canary_err=$(promq "max_over_time((sum(rate(http_requests_total{$sel,rollouts_pod_template_hash=\"$canary\",code=~\"5..\"}[30s])) / sum(rate(http_requests_total{$sel,rollouts_pod_template_hash=\"$canary\"}[30s])))[5m:10s])")
fi
peak_err=$(promq "max_over_time((sum(rate(http_requests_total{$sel,code=~\"5..\"}[30s])) / sum(rate(http_requests_total{$sel}[30s])))[5m:10s])")
pct() { awk -v v="$1" 'BEGIN{printf "%.1f", v*100}'; }
grafana_hint "13 · Rollout → 'Hata oranı (sürüme göre)' + 'İstek / sn (sürüme göre)' · 02 · App RED → 'Sunucu hatası oranı (5xx)'"
note "stable hash: ${stable:-?} · canary hash: ${canary:-?}  (sonradan: kubectl -n $NS get rollout redirect -o jsonpath='{.status.stableRS}')"
note "rollout durumu: ${phase:-?} · k6: $reqs istek, $e5 tanesi 5xx (3 dk'lık koşunun ortalaması %$err_ratio)"
[[ -n "$analysis" ]] && { note "analiz koşuları:"; echo "$analysis" | sed 's/^/      /'; }
if awk -v v="$share" 'BEGIN{exit !(v > 0)}'; then
  note "ölçülen canary payı: tepe %$(pct "$share") · canary'nin kendi hata oranı: tepe %$(pct "$canary_err") · TOPLAM 5xx oranı: tepe %$(pct "$peak_err")"
else
  warn "canary payı ölçülemedi: rollouts_pod_template_hash etiketi yok (redirect ServiceMonitor'ünde podTargetLabels uygulandı mı?)"
  note "toplam 5xx oranı: tepe %$(pct "$peak_err")"
fi
note "Kötü sürüm %25 hata üretir. Trafik yönlendirici olmadığı için canary payı setWeight'in %10'u"
note "değil pod sayısıdır (1 canary + 3 stable ≈ %25); toplam oran bu yüzden ~%25 × %25 ≈ %6 olur."
note "Analiz canary'yi AYRI ölçmüyor: namespace'in bütün /{code} trafiğinin oranını (%6) %2 eşiğiyle"
note "karşılaştırıyor ve 30-60 sn içinde durduruyor. Payı küçültmek (daha çok replika ya da gerçek bir"
note "trafik yönlendirici) toplam etkiyi küçültür — ama aynı toplam-oran eşiği o zaman GEÇ tetiklenir."
note "Rolling update olsaydı (maxSurge/maxUnavailable ile) hata oranı kademeli olarak %25'e"
note "çıkardı ve durduracak bir mekanizma OLMAZDI — yalnızca birinin fark etmesi."
note "Canary'nin bedeli: dağıtım 30 sn yerine birkaç dakika sürer. Bu, sigorta primidir."
# ANALİZ NEDEN DURDURDU? Bunu SORMAK zorundayız.
# EN: an analysis that cannot RUN and an analysis that fails a THRESHOLD produce the same rollout
#     status (Degraded / RolloutAborted). If the AnalysisTemplate points at a Prometheus service
#     name that does not exist, every query fails with "network is unreachable", consecutiveErrors
#     passes the limit and the canary is aborted — without a single metric being read. The guard
#     fires without having measured anything, so the verdict also reads the rollout message.
#     Whenever a guard fires, ask what it evaluated.
# TR: KOŞAMAYAN bir analiz ile EŞİĞİ geçemeyen bir analiz aynı rollout durumunu üretir
#     (Degraded / RolloutAborted). AnalysisTemplate var olmayan bir Prometheus servis adını
#     gösterirse her sorgu "network is unreachable" ile düşer, consecutiveErrors sınırı aşar ve
#     canary durur — tek bir metrik bile okunmadan. Koruma devreye girer ama hiçbir şey ÖLÇMEMİŞ
#     olur; bu yüzden karar rollout mesajını da okur.
msg=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.status.message}' 2>/dev/null) || true
[[ -n "${msg:-}" ]] && note "rollout mesajı: $(printf '%s' "$msg" | head -c 220)"
infra_err=0
printf '%s' "${msg:-}" | grep -qiE 'unreachable|no such host|connection refused|dial tcp|timeout awaiting' && infra_err=1
(( infra_err == 1 )) && warn "analiz ALTYAPI hatasıyla düştü (metrik okunamadı) — bu, kötü sürümün yakalandığı ANLAMINA GELMEZ"
{ (( aborted == 1 )) && (( infra_err == 0 )); } \
  && reproduced "kötü sürüm canary'de METRİKLE yakalandı (rollout=${phase:-?}, toplam hata %$err_ratio — kötü sürümün kendi oranı %25 idi)"
not_reproduced "canary kötü sürümü metrikle durduramadı (rollout=${phase:-?}, altyapı hatası=${infra_err}) — AnalysisTemplate'in Prometheus adresi doğru mu? (kubectl -n monitoring get svc | grep prometheus)"
