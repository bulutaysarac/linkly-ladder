#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-08 · TRAP_REGEX_PER_REQUEST: metriklerde ve log'larda GÖRÜNMEYEN bir CPU hot spot
# İstek başına regex derlemek klasik bir israftır. p99 hafif artar, CPU biraz yükselir — ama
# hiçbir metrik "regex derleniyor" demez. Bunu gören tek araç PROFİLDİR. Gözlemlenebilirliğin
# dördüncü ayağı: metrik (ne kadar), trace (nerede), log (neden), profil (hangi SATIR).
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_REGEX_PER_REQUEST-"
measure() {
  kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
  sleep 12
  local cpu p99 rps
  cpu=$(promq "sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redirect.*\",image!=\"\",image!~\".*pause.*\"}[2m]))")
  p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")")
  rps=$(promq "sum(rate(http_requests_total{namespace=\"$NS\",route=\"/{code}\"}[2m]))")
  echo "$cpu $p99 $rps"
}
step "(1) Regex bir kez derlenmiş (varsayılan)"
read -r c1 p1 r1 <<< "$(measure)"
note "normal: CPU=$(awk -v v="$c1" 'BEGIN{printf "%.2f", v}') çekirdek · p99=$(awk -v v="$p1" 'BEGIN{printf "%.1f", v*1000}') ms · rps=$(awk -v v="$r1" 'BEGIN{printf "%.0f", v}')"
note "istek başına CPU: $(awk -v c="$c1" -v r="$r1" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') ms"
step "(2) TRAP_REGEX_PER_REQUEST: her istekte yeniden derle"
setenv "$(wl redirect)" TRAP_REGEX_PER_REQUEST=true >/dev/null
read -r c2 p2 r2 <<< "$(measure)"
note "tuzakla: CPU=$(awk -v v="$c2" 'BEGIN{printf "%.2f", v}') çekirdek · p99=$(awk -v v="$p2" 'BEGIN{printf "%.1f", v*1000}') ms · rps=$(awk -v v="$r2" 'BEGIN{printf "%.0f", v}')"
note "istek başına CPU: $(awk -v c="$c2" -v r="$r2" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') ms"
grafana_hint "01 · Pods & Resources → 'CPU kullanımı' · 02 · App RED → p99"
note "Metrikler farkı GÖSTERİR ama SEBEBİ söylemez: 'CPU arttı' ile 'regexp.MustCompile her"
note "istekte çağrılıyor' arasında bir profil vardır."
note "Go'da bu bedava: net/http/pprof ekle, sonra"
note "  kubectl -n $NS port-forward "$(wl redirect)" 6060:6060"
note "  go tool pprof -http=: http://localhost:6060/debug/pprof/profile?seconds=30"
note "Sürekli profil (Pyroscope) bunu üretimde ve geçmişe dönük yapar: 'dün gece CPU neden yükseldi?'"
note "sorusunun cevabı, o gece profil toplanmadıysa kaybolur."
note "Bu merdivende Pyroscope opsiyonel bırakıldı (kaynak): 14'te kapasite modeliyle birlikte."
awk -v a="$c1" -v b="$c2" -v ra="$r1" -v rb="$r2" 'BEGIN{exit !( (rb>0?b/rb:0) > (ra>0?a/ra:0) )}' \
  && reproduced "istek başına CPU $(awk -v c="$c1" -v r="$r1" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') → $(awk -v c="$c2" -v r="$r2" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') ms'e çıktı — metrik farkı gösteriyor, sebebi yalnızca profil söyler"
not_reproduced "CPU farkı ölçülemedi (yükü artırıp tekrar dene)"
