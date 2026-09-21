#!/usr/bin/env bash
# Ortak reproduce kütüphanesi. Her problems/PNN-XX.sh şöyle başlar:
#   source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# Kontrat: env NS, BASE_URL, PROM_URL, GRAFANA_URL, LADDER_ROOT. Son satır REPRODUCED (exit 0) ya da NOT-REPRODUCED (exit 1).
set -euo pipefail
: "${NS:?NS gerekli}" "${BASE_URL:?BASE_URL gerekli}"
PROM_URL=${PROM_URL:-http://prometheus.localtest.me}
GRAFANA_URL=${GRAFANA_URL:-http://grafana.localtest.me}
LADDER_ROOT=${LADDER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
APP_SELECTOR=${APP_SELECTOR:-app.kubernetes.io/part-of=linkly-ladder}
PROBLEM_ID=$(basename "${0%.sh}")

# --explain: README'deki "### PNN-XX" bölümünü bas ve çık
if [[ "${1:-}" == "--explain" ]]; then
  awk -v id="### $PROBLEM_ID" 'index($0,id)==1{p=1;print;next} p&&/^### /{exit} p{print}' "$(dirname "$0")/../README.md"
  exit 0
fi

step()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
note()  { printf '  \033[2m%s\033[0m\n' "$*"; }
warn()  { printf '  \033[33m%s\033[0m\n' "$*"; }
reproduced()     { printf '\n\033[1;31mREPRODUCED\033[0m %s — %s\n' "$PROBLEM_ID" "$*"; exit 0; }
not_reproduced() { printf '\n\033[1;32mNOT-REPRODUCED\033[0m %s — %s\n' "$PROBLEM_ID" "$*"; exit 1; }
need_confirm()   { [[ "${CONFIRM:-}" == 1 ]] || { warn "yıkıcı adım ($*): CONFIRM=1 ile çalıştır"; exit 2; }; }
grafana_hint()   { note "Grafana → $GRAFANA_URL/dashboards?query=Ladder → $1  (level=$NS)"; }

# Prometheus anlık sorgu → ilk sonucun değeri (yoksa "0")
promq() { curl -sfG "$PROM_URL/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "0"'; }
# Sorgu hiç seri döndürmüyor mu? (metrik yok)
prom_absent() { [[ "$(curl -sfG "$PROM_URL/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result | length')" == "0" ]]; }

# create_link: BAŞARISIZLIK NORMALDİR. Bir üst seviye aynı isteği bilerek reddedebilir (01'de
# javascript: → 400). `curl -f` böyle bir durumda 22 ile çıkıp `set -e` yüzünden scripti öldürüyordu;
# o zaman script "NOT-REPRODUCED" diyemiyor, ERROR veriyordu. Artık kod yoksa BOŞ döner.
create_link() {
  local body
  body=$(curl -s -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' \
           -d "{\"url\":\"$1\"}" 2>/dev/null) || true
  printf '%s' "$body" | jq -r '.code // empty' 2>/dev/null || true
}
# Oluşturma denemesinin HTTP durumu (reddedildi mi, neden?) — doğrulama testleri bunu okur.
create_status() {
  curl -s -o /dev/null -w '%{http_code}' -XPOST "$BASE_URL/api/links" \
    -H 'Content-Type: application/json' -d "{\"url\":\"$1\"}" 2>/dev/null || echo 000
}
status_of()   { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/$1"; }
header_of()   { curl -sI --max-time 5 "$BASE_URL/$1" | tr -d '\r' | awk -v h="$2" 'tolower($1)==tolower(h)":"{ $1=""; sub(/^ /,""); print }'; }

kpods()       { kubectl -n "$NS" get pods -l "$APP_SELECTOR" "$@"; }
restarts()    { kpods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s+=$1} END{print s+0}'; }
last_reason() { kpods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}' | grep -v '^$' | sort -u | paste -sd, -; }
# rollout status, İZLEDİĞİ nesne watch sırasında silinirse "error: object has been deleted" der.
# Bu bir arıza değil bir yarıştır: ensure_healthy pod'u force-delete ederken ya da bir deney
# rollout restart atarken denk gelir. Gerçekte oldu: P04-07 kendi sorunuyla ilgisiz bir hata
# verdi, sebebi bir önceki adımın sildiği pod'du. Bir kez tekrar dene, sonra yoluna devam et.
wait_ready() {
  local d
  for d in $(kubectl -n "$NS" get deploy -o name 2>/dev/null); do
    kubectl -n "$NS" rollout status "$d" --timeout=180s >/dev/null 2>&1 \
      || kubectl -n "$NS" rollout status "$d" --timeout=180s >/dev/null 2>&1 || true
  done
}

# Bağımlı bileşenin (redis/postgres/redpanda/...) HAZIR pod'unu ver; yoksa gelmesini bekle.
# Neden: önceki bir deney o pod'u silmiş olabilir (P04-01 Redis'i öldürüyor). O pencerede
# `get pod -o jsonpath` boş liste üzerinde patlar ve script, kendi sorunuyla ilgisiz bir
# hatayla düşer. Bağımlılığın hazır olması ÖLÇÜMÜN ÖNKOŞULUDUR, ölçümün kendisi değil.
dep_pod() {
  local sel=$1 p ready
  for _ in $(seq 1 90); do
    p=$(kubectl -n "$NS" get pod -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$p" ]]; then
      ready=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
      [[ "$ready" == "true" ]] && { echo "$p"; return 0; }
    fi
    sleep 2
  done
  warn "bağımlı bileşen hazır olmadı: $sel"
  return 1
}

# Deney sonrası temizlik GARANTİSİ. Bir reproduce scripti yarıda hata verirse cluster'ı bozuk
# bırakmamalı: cordon'lu node, düşük replika, açık kalmış TRAP env'i sonraki deneyleri sessizce
# çürütür. Gerçekte oldu: P01-03 drain'de hata verip uncordon'a ulaşamadı, 3 node cordon'lu kaldı
# ve P01-07 "rollout timeout" diye patladı — sebebi kendi kodunda değil, ÖNCEKİ deneydeydi.
CLEANUP_CMDS=()
on_cleanup() { CLEANUP_CMDS+=("$1"); }
run_cleanup() {
  local c
  for (( i=${#CLEANUP_CMDS[@]}-1 ; i>=0 ; i-- )); do
    c="${CLEANUP_CMDS[i]}"
    eval "$c" >/dev/null 2>&1 || true
  done
  CLEANUP_CMDS=()
}
trap run_cleanup EXIT INT TERM

# Gerçekten hizmet veriyor mu? (Running olmak yetmez: crashloop'taki pod da anlık Running görünür.)
serving() {
  local c
  c=$(curl -sf --max-time 4 -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' \
        -d '{"url":"https://example.com/healthprobe"}' 2>/dev/null | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')
  [[ -n "$c" ]]
}

# Seviyenin İLAN ETTİĞİ replika sayısına dön. Önceki bir deney ölçeği değiştirip bıraktıysa (P00-03 gibi)
# sonraki deney yanlış tabandan başlar ve başka bir sorunu ölçtüğünü sanır.
ensure_baseline_scale() {
  local want live
  want=$(kubectl kustomize "$(dirname "$0")/../deploy" 2>/dev/null \
          | awk '/^kind: Deployment$/{d=1} d&&/^  replicas:/{print $2; exit}')
  [[ -z "$want" ]] && return 0
  live=$(replicas_of)
  if [[ "$live" != "$want" ]]; then
    note "replika sayısı tabana döndürülüyor: $live → $want (manifest'te ilan edilen)"
    scale "$want"
    wait_endpoints "$want"
  fi
}

# Temiz başlangıç noktası — ölçüm yapan her script buradan geçer.
# Neden gerekli: pod CrashLoopBackOff'a düştüğünde kubelet'in geri çekilme süresi 5 dk'ya kadar çıkar;
# o pencerede yeni restart OLMAZ ve "restart arttı mı?" ölçümü yanlış negatif verir. Ayrıca pod'u
# `delete` etmek (rollout restart değil) backoff sayacını sıfırlar: taze bir konteyner, restartCount=0.
ensure_healthy() {
  ensure_baseline_scale
  for attempt in 1 2 3; do
    if serving; then
      # Eski/terminating pod'lar gidene kadar bekle: ölçüm tek pod üzerinden yapılacak.
      for _ in $(seq 1 30); do
        [[ "$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" --no-headers 2>/dev/null | grep -c .)" -le "$(replicas_of)" ]] && return 0
        sleep 2
      done
      return 0
    fi
    warn "uygulama hizmet vermiyor (önceki deneyden crashloop olabilir) — pod siliniyor, backoff sıfırlanıyor ($attempt/3)"
    kubectl -n "$NS" delete pod -l "$APP_SELECTOR" --force --grace-period=0 >/dev/null 2>&1
    wait_ready
    sleep 3
  done
  serving || { warn "uygulama hâlâ ayağa kalkmıyor — önce 'make up' çalıştır"; exit 2; }
}

# Taze pod: backoff sıfırlanır, restartCount 0'dan başlar. Ölçümü restart sayacına dayandıran
# scriptler bunu kullanır — crashloop'taki bir pod'da sayaç DONAR (backoff 5 dk'ya kadar çıkar).
ensure_fresh_pod() {
  kubectl -n "$NS" delete pod -l "$APP_SELECTOR" --force --grace-period=0 >/dev/null 2>&1 || true
  wait_ready
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  serving || { warn "uygulama ayağa kalkmadı — önce 'make up'"; exit 2; }
}

# Ölümcül hata kanıtı: konteyner şu an ölüyse kendi logunda, yeniden başladıysa --previous logunda ara.
fatal_evidence() {
  local pod=$1 pattern=$2
  kubectl -n "$NS" logs "$pod" --previous --tail=400 2>/dev/null | grep -qF "$pattern" && return 0
  kubectl -n "$NS" logs "$pod" --tail=400 2>/dev/null | grep -qF "$pattern"
}
fatal_line() {
  local pod=$1 pattern=$2
  kubectl -n "$NS" logs "$pod" --previous --tail=400 2>/dev/null | grep -m1 -F "$pattern" \
    || kubectl -n "$NS" logs "$pod" --tail=400 2>/dev/null | grep -m1 -F "$pattern"
}

scale()       { kubectl -n "$NS" scale deploy -l "$APP_SELECTOR" --replicas="$1" >/dev/null; wait_ready; }
# Service endpoint'leri ölçeğe yetişene kadar bekle. rollout status "pod hazır" der ama ingress'in
# upstream listesi birkaç saniye geriden gelir; o pencerede tüm istekler TEK pod'a düşer ve
# yük dağılımına dayanan deneyler (P00-03 gibi) yanlış negatif verir.
wait_endpoints() {
  local want=$1 got
  for _ in $(seq 1 30); do
    got=$(kubectl -n "$NS" get endpointslice -l "kubernetes.io/service-name=linkly" \
            -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[0]}{"\n"}{end}{end}' 2>/dev/null | grep -c . || echo 0)
    (( got >= want )) && { sleep 3; return 0; }
    sleep 2
  done
  warn "endpoint sayısı $want'e ulaşmadı (şu an $got)"
}

replicas_of() { kubectl -n "$NS" get deploy -l "$APP_SELECTOR" -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo 1; }
# cAdvisor bu ortamda `container` label'ı üretmiyor → konteyner serilerini image üzerinden seç (bkz. dashboards/gen.py).
# Örneklenen tepe bellek. DİKKAT: Prometheus 15 sn'de bir örnekler; hızlı dolup ölen bir konteynerin
# gerçek tepesini KAÇIRIR (örnekler arasında doldu, öldü, sıfırdan başladı). Yani bu değer daima
# gerçek tepenin altındadır — asıl kanıt OOMKilled/exit 137'dir. (Bu örnekleme sorunu 11'de geri gelir.)
peak_working_set_mb() { promq "max_over_time(max(container_memory_max_usage_bytes{namespace=\"$NS\",image!=\"\",image!~\".*pause.*\"})[${1:-15m}:15s]) / 1024 / 1024" | cut -d. -f1; }
exit_code_of() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null; }
working_set_mb() { promq "sum(container_memory_working_set_bytes{namespace=\"$NS\",image!=\"\",image!~\".*pause.*\"}) / 1024 / 1024" | cut -d. -f1; }

# Pod'a doğrudan bağlan (ingress'i atla): "korumayı kim veriyor, uygulama mı önündeki katman mı?"
# sorusunu ayırt etmek için şart. Temizlik ortak: `wait` öldürülen işin 143'ünü döndürür ve
# `set -e` altında scripti sessizce öldürür — bu yüzden her yerde `|| true`.
PF_PID=""
port_forward() {
  local pod=$1 lport=$2
  kubectl -n "$NS" port-forward "pod/$pod" "$lport:8080" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 15); do
    curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$lport/healthz" && break
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$lport/" && break
    sleep 1
  done
}
port_forward_stop() { [[ -n "$PF_PID" ]] && { kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; PF_PID=""; }; return 0; }

pod_name()    { kubectl -n "$NS" get pod -l "$APP_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
restarts_of() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0; }

# Çökme kanıtı: belirtilen pod'un ÖNCEKİ konteyner loglarında kalıp var mı?
crash_evidence_of() {
  local pod=$1 pattern=$2
  kubectl -n "$NS" logs "$pod" --previous --tail=300 2>/dev/null | grep -qF "$pattern"
}
crash_line_of() {
  kubectl -n "$NS" logs "$1" --previous --tail=300 2>/dev/null | grep -m1 -F "$2"
}

# k6: senaryo adı + ek argümanlar. Özet JSON'u $K6_SUMMARY'ye yazar.
K6_SUMMARY=${K6_SUMMARY:-/tmp/k6-$NS-$PROBLEM_ID.summary.json}
k6run() { local s=$1; shift; "$LADDER_ROOT/platform/lib/k6run.sh" "$s" --summary-export "$K6_SUMMARY" "$@"; }
k6_failed_rate() { jq -r '.metrics.http_req_failed.value // .metrics.http_req_failed.rate // 0' "$K6_SUMMARY"; }
k6_reqs()        { jq -r '.metrics.http_reqs.count // 0' "$K6_SUMMARY"; }
# 5xx ve 404'ü ayrı oku: biri altyapı kesintisi, diğeri uygulamanın "yok" demesi (bkz. platform/k6/lib/ladder.js).
k6_5xx()         { jq -r '.metrics.http_5xx.count // 0' "$K6_SUMMARY"; }
k6_404()         { jq -r '.metrics.http_404.count // 0' "$K6_SUMMARY"; }
k6_429()         { jq -r '.metrics.http_429.count // 0' "$K6_SUMMARY"; }
