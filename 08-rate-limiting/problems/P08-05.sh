#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-05 · TRAP_GLOBAL_LIMIT: tek global anahtar = Redis'te hot key
# "Tüm sistem için saniyede N istek" makul bir kural gibi görünür. Gerçekleştirmesi tek bir Redis
# anahtarına HER istekte yazmaktır — ve Redis tek iş parçacıklıdır (P04-03). Koruma, koruduğu
# sistemden önce kendisi darboğaz olur.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env "$(wl redirect)" TRAP_GLOBAL_LIMIT-"
measure() {
  kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  k6run redirect --vus 40 --duration 40s >/dev/null 2>&1 || true
  sleep 10
  local p99 cpu
  p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(ratelimit_check_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")")
  cpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redis.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[3m:15s])")
  echo "$p99 $cpu"
}
step "Anahtar başına limit (varsayılan): yük Redis'te birçok anahtara dağılıyor"
read -r p1 c1 <<< "$(measure)"
note "dağıtık anahtar: limit kontrolü p99=$(awk -v v="$p1" 'BEGIN{printf "%.2f", v*1000}') ms · Redis CPU=$(awk -v v="$c1" 'BEGIN{printf "%.2f", v}')"
step "TRAP_GLOBAL_LIMIT: her istek TEK anahtara yazıyor"
kubectl -n "$NS" set env "$(wl redirect)" TRAP_GLOBAL_LIMIT=true >/dev/null
read -r p2 c2 <<< "$(measure)"
note "global anahtar: limit kontrolü p99=$(awk -v v="$p2" 'BEGIN{printf "%.2f", v*1000}') ms · Redis CPU=$(awk -v v="$c2" 'BEGIN{printf "%.2f", v}')"
grafana_hint "06 · Redis → 'Redis CPU' + 'commands by type' · 10 · Rate limit → 'decisions by key type'"
note "Global limit gerçekten gerekiyorsa: anahtarı PARÇALA (global:0..15, rastgele seç, limiti 16'ya böl)."
note "Bu, kesinlikten biraz ödün verir (parçalar eşit dolmaz) ama sıcak anahtarı ortadan kaldırır."
note "Genel kural: paylaşılan durumda 'tek sayaç' istemek, tek bir CPU çekirdeğine ölçeklenmek demektir."
note "Aynı desen 04'te önbellekte (P04-03), 02'de DB satırında (P02-08) karşımıza çıktı — üçü de aynı fizik."
awk -v a="$p1" -v b="$p2" 'BEGIN{exit !(b >= a)}' \
  && reproduced "global anahtar limit kontrolünü yavaşlattı ($(awk -v v="$p1" 'BEGIN{printf "%.2f", v*1000}') → $(awk -v v="$p2" 'BEGIN{printf "%.2f", v*1000}') ms, Redis CPU $(awk -v v="$c1" 'BEGIN{printf "%.2f", v}') → $(awk -v v="$c2" 'BEGIN{printf "%.2f", v}'))"
not_reproduced "global anahtar etkisi ölçülemedi (yükü artırıp tekrar dene)"
