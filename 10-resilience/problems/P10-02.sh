#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-02 · TRAP_READY_CHECKS_REDIS: kısmi arızayı TAM kesintiye çevirmenin en kolay yolu
# P02-10'un kardeşi. Aynı hata, yeni bağımlılık. Redis 10 saniye kesilirse: fail-open sayesinde
# hizmet ÇALIŞIR (DB'ye düşülür) — ama readiness Redis'e bakıyorsa TÜM pod'lar aynı anda
# Endpoints'ten düşer ve ingress'in yönlendirecek hedefi kalmaz.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_READY_CHECKS_REDIS-"
on_cleanup "kubectl -n \"$NS\" rollout status statefulset/redis --timeout=180s"
on_cleanup "kubectl -n \"$NS\" scale statefulset redis --replicas=1"
measure_outage() {
  local label=$1
  ( k6run redirect --vus 10 --duration 90s >/tmp/p1002-$label.k6 2>&1 ) & local kp=$!
  sleep 12
  kubectl -n "$NS" scale statefulset redis --replicas=0 >/dev/null
  local minep=99
  for _ in $(seq 1 20); do
    local ep
    ep=$(kubectl -n "$NS" get endpointslice -l kubernetes.io/service-name=redirect \
          -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' 2>/dev/null | grep -c true || true)
    (( ${ep:-0} < minep )) && minep=${ep:-0}
    sleep 2
  done
  kubectl -n "$NS" scale statefulset redis --replicas=1 >/dev/null
  wait $kp || true
  sleep 10                                    # son kazıma kesinti anını kapsasın
  # Redis KENDİ guard'ının arkasında: kesintide Redis devresi açılır ve degrade "no_cache" 1 olur
  # (önbellek atlanır, okumalar DB'den). Hizmet ÇALIŞIYOR demenin metrik hâli bu.
  local deg
  deg=$(promq "max_over_time(max(degraded_mode{namespace=\"$NS\",mode=\"no_cache\"})[2m:10s])")
  echo "$minep $(k6_5xx) ${deg%%.*}"
}
need_confirm "redis geçici olarak durdurulacak"
step "(1) Varsayılan: readiness Redis'e BAKMAZ"
read -r ep_ok e5_ok deg_ok <<< "$(measure_outage ok)"
note "varsayılan: en düşük hazır endpoint=$ep_ok · 5xx=$e5_ok · degrade no_cache (tepe)=$deg_ok"
note "  → Redis yokken devre açıldı ve hizmet önbelleksiz sürdü: bağımlılığın durumu METRİKTE, pod ayakta."
step "(2) TRAP_READY_CHECKS_REDIS: readiness Redis'e bakar"
setenv "$(wl redirect)" TRAP_READY_CHECKS_REDIS=true >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
read -r ep_bad e5_bad _ <<< "$(measure_outage trap)"
grafana_hint "11 · Resilience → 'Hazır pod adresi (endpoint) sayısı' + 'Azaltılmış mod (degrade)' · 15 · k6 → 'Dönen durum kodları'"
note "tuzakla: en düşük hazır endpoint=$ep_bad · 5xx=$e5_bad"
note "Aynı arıza, iki farklı sonuç. Fark bir YAML satırı ve bir kavram: readiness NE SORAR?"
note "Doğru cevap: 'BEN trafik alabilir miyim?' — 'bağımlılığım iyi mi?' sorusunun cevabı bir METRİKTİR"
note "ve buna verilecek tepki degrade mod ya da devre kesicidir, pod'u trafikten düşürmek değil."
note "Not: bu tuzağın en sinsi tarafı, bağımlılık DÖNDÜĞÜNDE tüm pod'ların AYNI ANDA geri gelip"
note "onu ikinci kez devirmesidir (thundering herd). Kurtarma da senkronize olur."
{ (( ep_bad < ep_ok )) || (( e5_bad > e5_ok )); } \
  && reproduced "readiness bağımlılığa bağlanınca endpoint $ep_ok → $ep_bad'e düştü (5xx $e5_ok → $e5_bad) — kısmi arıza tam kesintiye dönüştü"
not_reproduced "fark ölçülemedi (redis gerçekten durdu mu?)"
