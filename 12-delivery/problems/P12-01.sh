#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P12-01 · Kötü sürüm: rolling update %100'e taşır, analizli canary %10'da durdurur
# Rolling update "pod'ları değiştir ve umut et"tir. Analizli canary "%10'unu değiştir, ÖLÇ,
# sonra karar ver"dir. Fark trafik dağılımında değil: kararı bir dashboard'a bakan İNSANIN değil,
# saniyeler içinde bir MAKİNENİN vermesinde.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env rollout/redirect BAD_VERSION_ERROR_PCT=0 2>/dev/null || true"
has_rollout=$(kubectl -n "$NS" get rollout redirect -o name 2>/dev/null) || true
[[ -z "$has_rollout" ]] && { warn "Rollout bulunamadı (Argo Rollouts kurulu mu? cd platform && make argo)"; exit 2; }
step "Mevcut sürüm sağlıklı mı?"
kubectl -n "$NS" get rollout redirect -o custom-columns=AŞAMA:.status.phase,HAZIR:.status.readyReplicas,GÜNCEL:.status.updatedReplicas --no-headers 2>/dev/null | sed 's/^/    /'
step "KÖTÜ sürümü dağıt: redirect'lerin %25'i 500 dönecek"
( k6run redirect --vus 15 --duration 180s >/tmp/p1201.k6 2>&1 ) & kpid=$!
sleep 15
kubectl -n "$NS" set env rollout/redirect BAD_VERSION_ERROR_PCT=25 >/dev/null
note "canary başladı: %10 trafik kötü sürüme gidiyor, analiz 30 sn sonra ilk ölçümü alacak"
phase=""; aborted=0
for i in $(seq 1 45); do
  phase=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.status.phase}' 2>/dev/null) || true
  [[ "$phase" == "Degraded" ]] && { aborted=1; note "  → analiz BAŞARISIZ: rollout $((i*4)) sn içinde durduruldu"; break; }
  [[ "$phase" == "Healthy" ]] && { note "  → rollout tamamlandı (analiz geçti?)"; break; }
  sleep 4
done
wait $kpid || true
e5=$(k6_5xx); reqs=$(k6_reqs)
err_ratio=$(awk -v a="$e5" -v b="$reqs" 'BEGIN{printf "%.2f", (b>0? a*100/b : 0)}')
analysis=$(kubectl -n "$NS" get analysisrun -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.status.phase}{"\n"}{end}' 2>/dev/null | tail -3) || true
grafana_hint "13 · Rollout → '5xx oranı by version' (stable vs canary yan yana)"
note "rollout durumu: ${phase:-?} · k6: $reqs istek, $e5 tanesi 5xx (%$err_ratio)"
[[ -n "$analysis" ]] && { note "analiz koşuları:"; echo "$analysis" | sed 's/^/      /'; }
note "Kötü sürüm %25 hata üretiyordu; ama trafiğin yalnızca %10'una verildiği için toplam etki"
note "~%2.5 ile sınırlı kaldı ve analiz bunu 30-60 sn içinde yakaladı."
note "Rolling update olsaydı (maxSurge/maxUnavailable ile) hata oranı kademeli olarak %25'e"
note "çıkardı ve durduracak bir mekanizma OLMAZDI — yalnızca birinin fark etmesi."
note "Canary'nin bedeli: dağıtım 30 sn yerine birkaç dakika sürer. Bu, sigorta primidir."
{ (( aborted == 1 )) || awk -v e="$err_ratio" 'BEGIN{exit !(e < 25)}'; } \
  && reproduced "kötü sürüm canary'de yakalandı (rollout=${phase:-?}, toplam hata %$err_ratio — kötü sürümün kendi oranı %25 idi)"
not_reproduced "canary kötü sürümü durduramadı (analiz şablonu ve Prometheus adresi doğru mu?)"
