#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-08 · TRAP_READY_ALWAYS: her zaman "hazır" diyen bir probe, probe değildir
# Bir probe'un değeri HAYIR diyebilmesindedir. Sabit 200 döndüren readiness, kapanmakta olan,
# henüz ısınmamış ya da bağımlılığını kaybetmiş pod'lara da trafik gönderir — ve en kötüsü,
# rollout sırasında "hazır" sayıldığı için Kubernetes eski pod'ları güvenle öldürür.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_READY_ALWAYS-"
# preStop beklemesini deney süresince 0 yap (İKİ FAZDA DA). Neden: 5 saniyelik preStop, pod
# Endpoints'ten düşene kadar trafiği emiyor ve readiness'ın "HAYIR" diyebilmesinin değerini
# GİZLİYOR — ilk koşuda iki mod da 5xx=0 verdi, yani deney kendi güvenlik ağını ölçüyordu.
# Bir korumanın değerini ölçmek istiyorsan, aynı işi yapan DİĞER korumayı geçici olarak kaldır.
orig_prestop=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.sleep.seconds}' 2>/dev/null) || true
on_cleanup "kubectl -n \"$NS\" patch "$(wl redirect)" --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds\",\"value\":${orig_prestop:-5}}]'"
kubectl -n "$NS" patch "$(wl redirect)" --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/lifecycle/preStop/sleep/seconds","value":0}]' >/dev/null 2>&1 \
  || warn "preStop 0 yapılamadı (sürüm sleep hook'unu desteklemiyor olabilir)"
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
# ÖLÇÜ: 5xx TEK BAŞINA yetmiyor. Modern Kubernetes, sonlanmakta olan pod'u readiness'tan
# BAĞIMSIZ olarak Endpoints'ten düşürür (deletionTimestamp). Yani "sabit 200 dönen readiness"in
# zararı bu ortamda rollout'ta görünmeyebilir — iki modda da 5xx=0 çıktı. Bunu zorlayıp sahte bir
# pozitif üretmek yerine, probe'un CEVABININ tek fark olduğu yeri ölçüyoruz: drain penceresinde
# kaç endpoint "hazır" sayılıyor. Fark çıkmazsa script bunu dürüstçe söyler — ve nedenini yazar.
run_rollout_test() {
  ( k6run redirect --vus 10 --duration 60s >/tmp/p0708.k6 2>&1 ) & local kp=$!
  sleep 12
  kubectl -n "$NS" rollout restart "$(wl redirect)" >/dev/null
  # Rollout SIRASINDA hazır endpoint sayısının tepesi: sabit-hazır probe ile sonlanan pod da
  # "hazır" görünmeye devam ederse bu sayı manifest'teki replika sayısını AŞAR.
  local peak=0 cur
  for _ in $(seq 1 30); do
    cur=$(kubectl -n "$NS" get endpointslice -l "kubernetes.io/service-name=redirect" \
           -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' 2>/dev/null | grep -c true || echo 0)
    (( ${cur:-0} > peak )) && peak=${cur:-0}
    kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=3s >/dev/null 2>&1 && break
    sleep 2
  done
  wait $kp 2>/dev/null || true
  printf '%s %s' "$(k6_5xx)" "$peak"
}
step "Varsayılan readiness ile rollout"
read -r ok5 ok_ep <<< "$(run_rollout_test)"
note "varsayılan: rollout sırasında 5xx=$ok5 · tepe hazır endpoint=$ok_ep"
step "TRAP_READY_ALWAYS ile aynı rollout"
setenv "$(wl redirect)" TRAP_READY_ALWAYS=true >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
sleep 5
read -r trap5 trap_ep <<< "$(run_rollout_test)"
grafana_hint "02 · App RED → 5xx · 01 · Pods & Resources → 'hazır endpoint sayısı'"
note "TRAP açık: rollout sırasında 5xx=$trap5 · tepe hazır endpoint=$trap_ep"
note "Fark, probe'un HAYIR diyebilme yeteneğinin değeridir. Sabit 200, Kubernetes'in elindeki tek"
note "gerçek bilgiyi siler: 'bu pod şu an trafik alabilir mi?'"
note "Aynı hatanın kuzenleri: readiness'ı TCP kontrolüne indirgemek (port açık ama uygulama hazır"
note "değil), /healthz'i readiness olarak kullanmak (kapanışta HAYIR diyemez — 01'de bunu ayırmıştık),"
note "ve readiness'a bağımlılık koymak (P02-10: kısmi arıza tam kesintiye dönüşür). Üçü de aynı kökten:"
note "probe'un NE SORDUĞUNU tanımlamamak."
note "preStop bu deney boyunca 0 (normalde ${orig_prestop:-5}s) — iki faz da aynı koşulda."
{ (( trap5 > ok5 )) || (( trap_ep > ok_ep )); } \
  && reproduced "sabit-hazır probe fark yarattı: 5xx $ok5 → $trap5, tepe hazır endpoint $ok_ep → $trap_ep — hazır olmayan pod trafik aldı"
note "FARK ÇIKMADIYSA sebebi şu: Kubernetes sonlanan pod'u readiness'tan BAĞIMSIZ olarak"
note "Endpoints'ten düşürüyor (deletionTimestamp), yani bu senaryoda probe'un cevabı tek bilgi değil."
note "Probe'un değeri BAŞKA yerlerde ölçüldü: P01-07 (liveness yükte pod öldürüyor), P02-10 ve"
note "P10-02 (readiness bağımlılığa bağlanınca kısmi arıza TAM kesinti oluyor). Bir korumanın"
note "değerini gösteremiyorsan, onu gösterebildiğin yeri söyle — sahte pozitif üretme."
not_reproduced "fark ölçülemedi (5xx $ok5/$trap5, endpoint $ok_ep/$trap_ep) — yukarıdaki nota bak"
