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
# Bunu iddia edip profili almamak, tezi kanıtsız bırakmaktır.
# Uç, deploy edilen sürecin AYRI bir iç portta açtığı kendi sunucusunda (:6060, PPROF_ADDR,
# cmd/*/main.go). Servislerin kullanmadığı bir handler'a (API.Handler(); servisler split.go'daki
# kendi handler'larını kullanır) kaydedilen bir uç hiç var olmaz; servis portunda (:8080) ise
# ingress "/"'i redirect:8080'e gönderdiği için internete açık olurdu.
# EN: take the profile for real. The endpoint lives on its own internal listener (:6060): registered
# on a handler no deployed service serves it would not exist, and on :8080 it would be public.
step "PROFİLİ AL: sebebi yalnızca burada görünür"
pod=$(pod_name) || true
prof=$(mktemp); top=""; got_prof=0
if [[ -n "${pod:-}" ]]; then
  ( k6run redirect --vus 30 --duration 30s >/dev/null 2>&1 || true ) &
  kpid=$!
  kubectl --request-timeout=60s -n "$NS" get --raw \
    "/api/v1/namespaces/$NS/pods/$pod:6060/proxy/debug/pprof/profile?seconds=20" > "$prof" 2>/dev/null || true
  wait_pid_quiet "$kpid"
  # İLK SEKİZ DÜĞÜM YETMEZ. Tuzak istek başına CPU'yu ~%11 artırır (0.613 → 0.680 ms); bu,
  # regexp karelerini `-top` sıralamasının ilk 8'ine sokmaya yetmez. Bu yüzden düğüm sayısı 40,
  # KÜMÜLATİF sıralamaya da bakılır ve iki AYRI durum tek cümlede birleştirilmez: profil YOK mu,
  # yoksa profil VAR ama regexp görünmüyor mu? İkincisi tezin çürütülmesidir; birincisi ölçümün
  # yapılamamasıdır.
  # EN: the trap raises per-request CPU by ~11%, not enough to push regexp frames into the top 8.
  # So widen the node count, look at the cumulative ordering too, and keep "no profile" apart from
  # "profile without regexp" — the latter refutes the thesis, the former means we could not measure.
  # Gelen şey bir profil mi? Uç yoksa API sunucusu 404/503 metni döndürür ve `-s` onu da geçirir.
  if [[ -s "$prof" ]] && command -v go >/dev/null && go tool pprof -top -nodecount=1 "$prof" >/dev/null 2>&1; then
    got_prof=1
    top=$( { go tool pprof -top -nodecount=40 "$prof" 2>/dev/null; go tool pprof -top -cum -nodecount=40 "$prof" 2>/dev/null; } \
           | grep -iE 'regexp|onepass|syntax|Compile|MatchString' | head -3) || true
  fi
fi
if [[ -n "$top" ]]; then
  note "profilde regexp derlemesi GÖRÜNÜYOR:"
  echo "$top" | sed 's/^/      /'
elif [[ "${got_prof:-0}" == "1" ]]; then
  note "profil alındı ama ilk 40 düğümde regexp karesi YOK — bu ölçekte derleme maliyeti profilde baskın değil"
else
  warn "profil ALINAMADI (pprof ucu: pods/$pod:6060/proxy/debug/pprof/profile)"
  warn "go kurulu mu, pod iç portta (6060, PPROF_ADDR) dinliyor mu, kubectl raw isteği zaman aşımına mı uğradı?"
fi
rm -f "$prof"
grafana_hint "01 · Pods & Resources → 'CPU kullanımı (bir çekirdeğin %'si)' · 02 · App RED → 'p99 süre (uç noktaya göre)' — sebep hiçbir panelde yok, profilde"
note "ÖLÇÜM DERSİ: istek başına regexp.MustCompile birkaç MİKROSANİYEDİR. 600 rps'te bu, saniyede"
note "birkaç milisaniyelik CPU demek — konteyner CPU metriğinin gürültüsünün ALTINDA. Yani"
note "'istek başına CPU arttı mı?' diye soran bir script çoğu koşuda HAYIR cevabı alır"
note "ve 'sorun yok' der. Oysa sorunun kendisi tam olarak bu: metrik bunu göremez."
note "Bir tezi, tezin YANLIŞ olduğu durumda geçecek bir ölçüyle sınayamazsın."
note "Go'da profil bedava: net/http/pprof (bu seviyede İÇ portta, :6060 — ingress'te değil), sonra"
note "  kubectl -n $NS port-forward $(wl redirect) 6060:6060"
note "  go tool pprof -http=: http://localhost:6060/debug/pprof/profile?seconds=30"
note "Sürekli profil (Pyroscope) bunu üretimde ve geçmişe dönük yapar: 'dün gece CPU neden yükseldi?'"
note "sorusunun cevabı, o gece profil toplanmadıysa kaybolur."
note "Bu merdivende Pyroscope opsiyonel bırakıldı (kaynak): 14'te kapasite modeliyle birlikte."
[[ -n "$top" ]] \
  && reproduced "metrik farkı gürültünün altında (istek başına CPU $(awk -v c="$c1" -v r="$r1" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') → $(awk -v c="$c2" -v r="$r2" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') ms) ama PROFİL sebebi doğrudan gösterdi: regexp derlemesi"
# Profil YOKSA hüküm yok: ölçemediğimiz şey "sorun yok" değildir.
if [[ "${got_prof:-0}" != "1" ]]; then
  warn "profil alınamadı (pod: ${pod:-yok}) — tez sınanamadı."
  warn "Bu bir hüküm değil, EKSİK ÖLÇÜMdür."
  exit 2
fi
not_reproduced "profil alındı ama regexp derlemesi ilk 40 düğümde görünmedi (istek başına CPU $(awk -v c="$c1" -v r="$r1" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') → $(awk -v c="$c2" -v r="$r2" 'BEGIN{printf "%.3f", (r>0? c*1000/r : 0)}') ms)"
