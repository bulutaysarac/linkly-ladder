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
  p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
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
# PROFİLİ GERÇEKTEN AL. Tezin tamamı bu: metrik farkı GÖSTEREBİLİR ama SEBEBİ söylemez.
# Bunu iddia edip profili almamak, tezi kanıtsız bırakmaktı — üstelik script okuyucuya
# çalışmayan bir pprof komutu öneriyordu (uç hiç kayıtlı değildi; artık /debug/pprof var).
# EN: take the profile for real. Claiming "only a profile can tell you why" and then not taking
# one leaves the thesis unproven — and the script used to print a pprof command that could not
# work, because the endpoint was never registered.
step "PROFİLİ AL: sebebi yalnızca burada görünür"
pod=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
prof=$(mktemp); top=""
if [[ -n "${pod:-}" ]]; then
  ( k6run redirect --vus 30 --duration 30s >/dev/null 2>&1 || true ) &
  kpid=$!
  kubectl --request-timeout=60s -n "$NS" get --raw \
    "/api/v1/namespaces/$NS/pods/$pod:8080/proxy/debug/pprof/profile?seconds=20" > "$prof" 2>/dev/null || true
  wait_pid_quiet "$kpid"
  if [[ -s "$prof" ]] && command -v go >/dev/null; then
    top=$(go tool pprof -top -nodecount=8 "$prof" 2>/dev/null | grep -iE 'regexp|onepass|syntax' | head -3) || true
  fi
fi
if [[ -n "$top" ]]; then
  note "profilde regexp derlemesi GÖRÜNÜYOR:"
  echo "$top" | sed 's/^/      /'
else
  note "profil alınamadı ya da regexp satırı bulunamadı (pprof ucu: /debug/pprof/profile)"
fi
rm -f "$prof"
grafana_hint "01 · Pods & Resources → 'CPU kullanımı' · 02 · App RED → p99"
note "ÖLÇÜM DERSİ: istek başına regexp.MustCompile birkaç MİKROSANİYEDİR. 600 rps'te bu, saniyede"
note "birkaç milisaniyelik CPU demek — konteyner CPU metriğinin gürültüsünün ALTINDA. Yani bu"
note "scriptin ilk hâli 'istek başına CPU arttı mı?' diye sorup çoğu koşuda HAYIR cevabı alıyordu"
note "ve "sorun yok" diyordu. Oysa sorunun kendisi tam olarak buydu: metrik bunu göremez."
note "Bir tezi, tezin YANLIŞ olduğu durumda geçecek bir ölçüyle sınayamazsın."
note "Go'da profil bedava: net/http/pprof (bu seviyede iç portta açık), sonra"
note "  kubectl -n $NS port-forward $(wl redirect) 8080:8080"
note "  go tool pprof -http=: http://localhost:8080/debug/pprof/profile?seconds=30"
note "Sürekli profil (Pyroscope) bunu üretimde ve geçmişe dönük yapar: 'dün gece CPU neden yükseldi?'"
note "sorusunun cevabı, o gece profil toplanmadıysa kaybolur."
note "Bu merdivende Pyroscope opsiyonel bırakıldı (kaynak): 14'te kapasite modeliyle birlikte."
[[ -n "$top" ]] \
  && reproduced "metrik farkı gürültünün altında (istek başına CPU $(awk -v c="$c1" -v r="$r1" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') → $(awk -v c="$c2" -v r="$r2" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') ms) ama PROFİL sebebi doğrudan gösterdi: regexp derlemesi"
not_reproduced "profil alınamadı — /debug/pprof/profile erişilebilir mi? (pod: ${pod:-yok})"
