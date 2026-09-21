#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-08 · TRAP_READY_ALWAYS: her zaman "hazır" diyen bir probe, probe değildir
# Bir probe'un değeri HAYIR diyebilmesindedir. Sabit 200 döndüren readiness, kapanmakta olan,
# henüz ısınmamış ya da bağımlılığını kaybetmiş pod'lara da trafik gönderir — ve en kötüsü,
# rollout sırasında "hazır" sayıldığı için Kubernetes eski pod'ları güvenle öldürür.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/redirect TRAP_READY_ALWAYS-"
# preStop beklemesini deney süresince 0 yap (İKİ FAZDA DA). Neden: 5 saniyelik preStop, pod
# Endpoints'ten düşene kadar trafiği emiyor ve readiness'ın "HAYIR" diyebilmesinin değerini
# GİZLİYOR — ilk koşuda iki mod da 5xx=0 verdi, yani deney kendi güvenlik ağını ölçüyordu.
# Bir korumanın değerini ölçmek istiyorsan, aynı işi yapan DİĞER korumayı geçici olarak kaldır.
orig_prestop=$(kubectl -n "$NS" get deploy redirect -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.sleep.seconds}' 2>/dev/null) || true
on_cleanup "kubectl -n \"$NS\" patch deploy redirect --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds\",\"value\":${orig_prestop:-5}}]'"
kubectl -n "$NS" patch deploy redirect --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":0}]' >/dev/null 2>&1 \
  || warn "preStop 0 yapılamadı (sürüm sleep hook'unu desteklemiyor olabilir)"
kubectl -n "$NS" rollout status deploy/redirect --timeout=180s >/dev/null 2>&1 || true
run_rollout_test() {
  ( k6run redirect --vus 10 --duration 60s >/tmp/p0708.k6 2>&1 ) & local kp=$!
  sleep 12
  kubectl -n "$NS" rollout restart deploy/redirect >/dev/null
  kubectl -n "$NS" rollout status deploy/redirect --timeout=150s >/dev/null 2>&1 || true
  wait $kp || true
  k6_5xx
}
step "Varsayılan readiness ile rollout"
ok5=$(run_rollout_test)
note "varsayılan: rollout sırasında 5xx=$ok5"
step "TRAP_READY_ALWAYS ile aynı rollout"
kubectl -n "$NS" set env deploy/redirect TRAP_READY_ALWAYS=true >/dev/null
kubectl -n "$NS" rollout status deploy/redirect --timeout=180s >/dev/null 2>&1 || true
sleep 5
trap5=$(run_rollout_test)
grafana_hint "02 · App RED → 5xx · 01 · Pods & Resources → 'hazır endpoint sayısı'"
note "TRAP açık: rollout sırasında 5xx=$trap5"
note "Fark, probe'un HAYIR diyebilme yeteneğinin değeridir. Sabit 200, Kubernetes'in elindeki tek"
note "gerçek bilgiyi siler: 'bu pod şu an trafik alabilir mi?'"
note "Aynı hatanın kuzenleri: readiness'ı TCP kontrolüne indirgemek (port açık ama uygulama hazır"
note "değil), /healthz'i readiness olarak kullanmak (kapanışta HAYIR diyemez — 01'de bunu ayırmıştık),"
note "ve readiness'a bağımlılık koymak (P02-10: kısmi arıza tam kesintiye dönüşür). Üçü de aynı kökten:"
note "probe'un NE SORDUĞUNU tanımlamamak."
note "preStop bu deney boyunca 0 (normalde ${orig_prestop:-5}s) — iki faz da aynı koşulda."
(( trap5 > ok5 )) \
  && reproduced "sabit-hazır probe rollout'ta 5xx'i $ok5 → $trap5'e çıkardı — hazır olmayan pod trafik aldı"
not_reproduced "fark ölçülemedi (rollout çok hızlı geçmiş olabilir; yükü artırıp tekrar dene)"
