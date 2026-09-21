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

# Prometheus anlık sorgu → ilk sonucun değeri (yoksa "0").
# DAYANIKLILIK: `curl -sf` bağlantı düşünce 52 ("empty reply") ile çıkıyor ve `promq` komut
# ikamesi içinde çağrıldığı için `set -e` scripti ORADA öldürüyordu — ölçüm bitmiş olsa bile
# sonuç "HATA" görünüyordu (P07-04/05). Ölçüm ALTYAPISININ tökezlemesi, deneyi iptal etmemeli.
# Ama sessizce 0 da dönmemeli: iki denemede de alamazsa STDERR'e uyarı basar (stdout'a basarsa
# değeri kirletir — bu fonksiyon hep `$( )` içinde çağrılıyor).
_promq_raw() { curl -sfG --max-time 15 "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null; }
promq() {
  local out rc=0
  out=$(_promq_raw "$1") || rc=$?
  if (( rc != 0 )); then
    sleep 2
    rc=0; out=$(_promq_raw "$1") || rc=$?
  fi
  if (( rc != 0 )); then
    printf '  \033[33mPrometheus sorgusu başarısız (curl %s), 0 sayıldı: %.60s\033[0m\n' "$rc" "$1" >&2
    echo 0; return 0
  fi
  printf '%s' "$out" | jq -r '.data.result[0].value[1] // "0"'
}
# Sorgu hiç seri döndürmüyor mu? (metrik yok)
prom_absent() {
  local out
  out=$(_promq_raw "$1") || { sleep 2; out=$(_promq_raw "$1") || { echo "prom_absent: sorgu yapılamadı" >&2; return 1; }; }
  [[ "$(printf '%s' "$out" | jq -r '.data.result | length')" == "0" ]]
}

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

# Pod'un kendi /metrics ucunu SANİYEDE BİR örnekle → saniyelik fark dizisi (dosyaya, satır başına bir sayı).
#   sample_series <pod> <saniye> <çıktı-dosyası> <awk-deseni> [atlanacak-ilk-saniye]
#
# Neden var: Prometheus bu kurulumda 15 sn'de bir örnekliyor ve `rate(...[30s])` 1-2 saniyelik bir
# darbeyi 30 saniyeye yayıp düzlüyor. Tepe/ortalama oranını ölçmek istiyorsan ölçüm çözünürlüğün
# olaydan İNCE olmalı. (Aynı sorun 11'de yüksek çözünürlük/exemplar başlığıyla dönüyor.)
#
# Neden port-forward DEĞİL: ilk sürüm `kubectl port-forward` kullanıyordu ve 150 saniyelik
# örnekleme boyunca bağlantı düşünce curl 28 (timeout) / 52 (empty reply) döndürüyor, `pipefail`
# altında scripti öldürüyordu — ölçüm aracının kendisi deneyi bozuyordu. API sunucusunun pod
# proxy'si (`/proxy/metrics`) kalıcı bir tünel gerektirmez. Yine de tek tük hata olabilir:
# başarısız örnek ATLANIR, sayaç farkı bir sonraki başarılı örnekte doğru kapanır.
sample_series() {
  local pod=$1 secs=$2 out=$3 pattern=$4 skip=${5:-0}
  local prev="" cur i fails=0 raw rc firsterr=""
  : > "$out"
  for (( i = 0; i < secs; i++ )); do
    rc=0
    raw=$(kubectl --request-timeout=3s -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$pod:8080/proxy/metrics" 2>&1) || rc=$?
    if (( rc != 0 )); then
      # Tek bir anlık hata örnekleme serisini delik deşik etmesin: bir kez hemen tekrar dene.
      rc=0
      raw=$(kubectl --request-timeout=3s -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$pod:8080/proxy/metrics" 2>&1) || rc=$?
    fi
    if (( rc != 0 )); then
      # İlk hatayı SAKLA ve bas: "144/150 örnek kayboldu" tek başına teşhis değil, semptomdur.
      [[ -z "$firsterr" ]] && firsterr=$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-160)
      fails=$(( fails + 1 )); prev=""; sleep 1; continue
    fi
    cur=$(printf '%s\n' "$raw" | awk -v pat="$pattern" '$0 ~ pat {s += $2} END {print s + 0}')
    if [[ -n "$prev" && $i -gt $skip ]]; then
      awk -v a="$prev" -v b="$cur" 'BEGIN{d=b-a; print (d<0?0:d)}' >> "$out"
    fi
    prev=$cur
    sleep 1
  done
  if (( fails > secs / 5 )); then
    warn "örnekleme kayıpları: $fails/$secs — ilk hata: ${firsterr:-<yok>}"
  fi
  return 0
}
# "tepe ortalama oran" üçlüsü — kapasite tepeye göre planlanır, ortalamaya göre değil.
peak_avg() {
  awk '{n++; s+=$1; if ($1>p) p=$1} END{if (n==0||s==0){print "0 0 0"; exit} printf "%d %.1f %.1f", p, s/n, p/(s/n)}' "$1"
}

# Komutu ZAMAN SINIRIYLA çalıştır (macOS'ta `timeout` yok).
# Neden: P07-07 bir node'u dondurup çözdükten sonra 43 dakika asılı kaldı — k6 bitmişti ama
# script ilerlemiyordu. Bir deneyin adımları SINIRLI sürmeli; süresiz bekleyen bir adım,
# doğrulama turunun tamamını durdurur ve hangi adımda takıldığını bile söylemez.
with_timeout() {
  local secs=$1; shift
  ( "$@" ) & local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) & local watchdog=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

# Bir metrik YOKSA ölçüme başlama.
# `promq` serisi olmayan bir sorguya "0" döndürür; yani var olmayan bir metrik ile gerçekten
# sıfır olan bir metrik aşağı akışta AYNI görünür. Gerçekte oldu: 07-14'te postgres/redis
# ServiceMonitor'ları eksikti, P07-02 ekrana `max_connections=0` basıp "sorun yok" dedi.
# Kural: bir ölçüm, dayandığı metriğin VARLIĞINI önce doğrulamalı.
need_metric() {
  local m=$1 hint=${2:-}
  if prom_absent "$m{namespace=\"$NS\"}" && prom_absent "$m"; then
    warn "metrik YOK: $m — ölçüm anlamsız${hint:+ ($hint)}"
    exit 2
  fi
}

# Chaos uygula ve temizliğini kaydet; UYGULANAMADIYSA scripti DURDUR.
# Neden: yaygın `|| warn "Chaos Mesh yok"` kalıbı iki farklı durumu aynı kefeye koyuyordu —
#   (2) Chaos Mesh kurulu değil
#   (3) bu seviyede hedef pod YOK (etiket uyuşmuyor)
# İkincisi bir YAPILANDIRMA HATASIDIR. Sessizce geçilirse script arızayı hiç enjekte etmeden
# ölçüm yapar ve "sorun yok" der. Gerçekte oldu: 09-14'te Postgres CNPG'ye geçti, pod'lar
# `app.kubernetes.io/name=postgres` etiketini taşımıyordu ve pg-loss/pg-delay deneylerinin
# hepsi sessizce arızasız koştu. Ölçemediğin şeyi "yok" sanma; enjekte edemediğin arızayı da.
chaos_apply() {
  local c=$1 out rc=0
  out=$("$LADDER_ROOT/platform/lib/chaos.sh" apply "$c" 2>&1) || rc=$?
  case $rc in
    0) on_cleanup "$LADDER_ROOT/platform/lib/chaos.sh delete $c"
       # "Nesne oluştu" ile "arıza ENJEKTE EDİLDİ" aynı şey değil: chaos-daemon sağlıksızsa nesne
       # Run fazında kalır ve hiçbir şey olmaz. AllInjected koşulunu bekle, olmazsa yüksek sesle söyle.
       local kind name injected=""
       kind=$(awk '/^kind:/{print tolower($2); exit}' "$LADDER_ROOT/platform/chaos/$c.yaml")
       name=$(sed -n 's/.*name: *\([a-z0-9-]*\).*/\1/p' "$LADDER_ROOT/platform/chaos/$c.yaml" | head -1)
       for _ in $(seq 1 15); do
         injected=$(kubectl -n "$NS" get "$kind" "$name" -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}' 2>/dev/null || true)
         [[ "$injected" == "True" ]] && break
         sleep 2
       done
       if [[ "$injected" == "True" ]]; then note "chaos uygulandı ve enjekte edildi: $c"
       else warn "chaos nesnesi oluştu ama ENJEKTE EDİLMEDİ ($c, AllInjected=${injected:-bilinmiyor}) — chaos-daemon sağlıklı mı?"; fi
       return 0 ;;
    2) warn "Chaos Mesh kurulu değil: cd platform && make chaos"; exit 2 ;;
    3) warn "chaos hedefi bu seviyede yok ($c) — ETİKET UYUŞMUYOR, arıza enjekte edilemedi"; exit 2 ;;
    *) warn "chaos uygulanamadı ($c): $out"; exit 2 ;;
  esac
}

# Bilinen bir koda N tıklama üret (varsayılan 10 paralel).
# Neden paralel: sıralı `for + curl` döngüsü ~20-40 istek/s'te kalıyor. "Tampon/ kuyruk doluyken
# öldür" türü deneylerde bu hız yetersiz — tüketici üretimden hızlı çalışıyorsa hiç birikim olmaz
# ve deney, ölçmek istediği durumu HİÇ oluşturmadan "sorun yok" der.
clicks() {
  local code=$1 n=$2 par=${3:-10}
  seq 1 "$n" | xargs -P "$par" -I{} curl -s -o /dev/null --max-time 5 "$BASE_URL/$code" >/dev/null 2>&1 || true
}

kpods()       { kubectl -n "$NS" get pods -l "$APP_SELECTOR" "$@"; }
restarts()    { kpods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s+=$1} END{print s+0}'; }
last_reason() { kpods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}' | grep -v '^$' | sort -u | paste -sd, -; }
# rollout status, İZLEDİĞİ nesne watch sırasında silinirse "error: object has been deleted" der.
# Bu bir arıza değil bir yarıştır: ensure_healthy pod'u force-delete ederken ya da bir deney
# rollout restart atarken denk gelir. Gerçekte oldu: P04-07 kendi sorunuyla ilgisiz bir hata
# verdi, sebebi bir önceki adımın sildiği pod'du. Bir kez tekrar dene, sonra yoluna devam et.
wait_ready() {
  local d r want got
  for d in $(kubectl -n "$NS" get deploy -o name 2>/dev/null); do
    kubectl -n "$NS" rollout status "$d" --timeout=180s >/dev/null 2>&1 \
      || kubectl -n "$NS" rollout status "$d" --timeout=180s >/dev/null 2>&1 || true
  done
  # Argo Rollout'u `kubectl rollout status` TANIMIYOR (o yalnızca yerleşik türleri bilir) ve
  # `kubectl argo rollouts` eklentisi burada kurulu değil. 12+'da hazır olmayı beklemezsek
  # ölçüm, henüz trafiğe girmemiş pod'larla başlar. Hazır replika sayısını kendimiz sayıyoruz.
  for r in $(kubectl -n "$NS" get rollout -o name 2>/dev/null); do
    want=$(kubectl -n "$NS" get "$r" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
    for _ in $(seq 1 90); do
      got=$(kubectl -n "$NS" get "$r" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      (( ${got:-0} >= ${want:-1} )) && break
      sleep 2
    done
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
  local want live svc; svc=$(app_name)
  # Manifest'teki replika sayısını, BU scriptin ilgilendiği iş yükünden oku.
  # İlk hâl "ilk Deployment"ı alıyordu; 07'den sonra deploy/ içinde birden çok iş yükü var
  # (redirect, api, analytics) ve alfabetik sırada gelen başkasının sayısını redirect'e
  # uygulamak sessizce yanlış bir tabandan başlamak demek. 12'den sonra redirect artık
  # Deployment bile değil (Argo Rollout) — kind listesi ona göre.
  want=$(kubectl kustomize "$(dirname "$0")/../deploy" 2>/dev/null | awk -v want_name="$svc" '
    /^kind: (Deployment|Rollout|StatefulSet)$/ { kind=$2; name=""; reps=""; next }
    /^kind: /                                  { kind="";  name=""; reps=""; next }
    kind != "" && /^  name: /                  { if (name == "") name=$2 }
    kind != "" && /^  replicas: /              { reps=$2 }
    kind != "" && name == want_name && reps != "" { print reps; exit }
  ')
  # Ada göre bulunamadıysa eski davranış: ilk Deployment
  [[ -z "$want" ]] && want=$(kubectl kustomize "$(dirname "$0")/../deploy" 2>/dev/null \
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
# Bu namespace'teki HER iş yükü pod'u hazır mı? (Completed job'lar hariç)
# Neden: Redpanda 06'dan beri CrashLoopBackOff'taydı ve hiçbir script bunu sormadığı için
# bütün stream deneyleri ÖLÜ bir broker'ı ölçtü — üstelik "75 bin üretici hatası" gibi
# sonuçları bulgu sanarak rapor ettik. Bir deneyin ön koşulu da ölçülmesi gereken bir şeydir.
ensure_deps_ready() {
  local bad
  # BEKLE, hemen patlama: bir önceki deneyin rollout'u hâlâ sürüyor olabilir ve "şu an hazır
  # değil" ile "hiç hazır olmayacak" farklı şeylerdir. İlk sürüm hemen exit 2 veriyordu ve
  # normal bir rollout penceresi, sonraki TÜM scriptleri zincirleme SKIPPED yapıyordu.
  for _ in $(seq 1 60); do
    bad=$(kubectl -n "$NS" get pods -o json 2>/dev/null | jq -r '
      [ .items[]
        | select(.status.phase != "Succeeded")
        | select(.metadata.deletionTimestamp == null)
        | select(any(.status.containerStatuses[]?; .ready | not))
        | .metadata.name ] | join(", ")')
    [[ -z "${bad:-}" ]] && return 0
    sleep 2
  done
  warn "2 dk sonra hâlâ hazır olmayan pod(lar): $bad — ortam bozukken ölçüm yapılmaz (kubectl describe)"
  exit 2
}

ensure_healthy() {
  ensure_deps_ready
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

# 12'den sonra redirect bir Deployment değil, Argo Rollout. Ölçek/okuma yardımcıları iş yükünün
# TÜRÜNÜ sormak zorunda; "deploy" varsaymak "error: no objects passed to scale" ile patlıyordu.
workload_kind() {
  if kubectl -n "$NS" get "rollout/$(app_name)" -o name 2>/dev/null | grep -q .; then
    printf 'rollout'
  else
    printf 'deploy'
  fi
}
# Yalnızca BU scriptin iş yükünü ölçekle, etiketle eşleşen HER ŞEYİ değil.
# Gerçekte oldu: 06'dan sonra tüketici (analytics) de `part-of=linkly-ladder` taşıyor ve
# `scale deploy -l "$APP_SELECTOR"` uygulamayla birlikte onu da ölçekliyordu — deney, ölçtüğünü
# sandığı şeyden başka bir şeyi değiştiriyordu (P06-03/04/07 hata verdi).
scale()       { kubectl -n "$NS" scale "$(workload_kind)/$(app_name)" --replicas="$1" >/dev/null; wait_ready; }
# Service endpoint'leri ölçeğe yetişene kadar bekle. rollout status "pod hazır" der ama ingress'in
# upstream listesi birkaç saniye geriden gelir; o pencerede tüm istekler TEK pod'a düşer ve
# yük dağılımına dayanan deneyler (P00-03 gibi) yanlış negatif verir.
# Bu scriptin ilgilendiği iş yükünün ADI. 00-06'da tek servis var (linkly); 07'den sonra
# uygulama redirect/api diye BÖLÜNÜYOR ve scriptler APP_SELECTOR'ü buna göre değiştiriyor.
# Servis adını sabit "linkly" varsaymak, 07+ seviyelerde wait_endpoints'i her seferinde
# 60 saniye boş bekletip uyarı bastırıyordu — sessiz ama her deneye 1 dakika ekleyen bir hata.
app_name() {
  case "$APP_SELECTOR" in
    *app.kubernetes.io/name=*) printf '%s' "${APP_SELECTOR##*app.kubernetes.io/name=}"; return ;;
  esac
  # APP_SELECTOR ad vermiyorsa KÜMEYE SOR. Neden: 06'nın scriptleri `deploy/linkly` diye
  # yazılmıştı; 07'de uygulama redirect/api diye bölününce `verify-prev` o scriptleri çalıştırdı
  # ve hepsi "deployments.apps 'linkly' not found" ile ERROR verdi. Merdivenin kontratı "bir
  # sonraki seviye bunu ÇÖZER" demek; scriptin çalışamaması bunu DOĞRULAMAZ, yalnızca gizler.
  local n
  for n in linkly redirect app; do
    kubectl -n "$NS" get "deploy/$n" >/dev/null 2>&1 && { printf '%s' "$n"; return; }
    kubectl -n "$NS" get "rollout/$n" >/dev/null 2>&1 && { printf '%s' "$n"; return; }
  done
  printf 'linkly'
}
# Bu seviyedeki uygulama iş yükünün tam adı: `deploy/linkly` ya da `rollout/redirect`.
app_workload() { printf '%s/%s' "$(workload_kind)" "$(app_name)"; }
wait_endpoints() {
  local want=$1 got svc; svc=$(app_name)
  for _ in $(seq 1 30); do
    got=$(kubectl -n "$NS" get endpointslice -l "kubernetes.io/service-name=$svc" \
            -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[0]}{"\n"}{end}{end}' 2>/dev/null | grep -c . || echo 0)
    (( got >= want )) && { sleep 3; return 0; }
    sleep 2
  done
  warn "endpoint sayısı $want'e ulaşmadı (servis=$svc, şu an $got)"
}

replicas_of() { kubectl -n "$NS" get "$(workload_kind)/$(app_name)" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1; }
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

# HAZIR ve silinmekte OLMAYAN bir pod seç.
# Gerçekte oldu: `items[0]` rollout'tan sonra hâlâ listede duran TERMINATING pod'u veriyordu ve
# 150 saniyelik örnekleme boyunca her istek "connection refused" aldı (P03-07, 142/150 kayıp).
# Aynı kod bir başka seviyede çalıştı — çünkü orada items[0] şansa canlı pod'du. Şansa dayanan
# bir seçim, ölçümün bir parçası değildir.
pod_name() {
  kubectl -n "$NS" get pod -l "$APP_SELECTOR" -o json 2>/dev/null \
    | jq -r '[.items[]
              | select(.metadata.deletionTimestamp == null)
              | select(any(.status.containerStatuses[]?; .ready))
              | .metadata.name][0] // empty'
}
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
# Her yük koşusu ZAMAN SINIRLI: süre + 4 dk pay (setup/teardown). Bir k6 takılırsa yalnızca o
# adım düşer, doğrulama turunun tamamı değil (P07-07 bir kez 43 dakika asılı kaldı).
k6run() {
  local s=$1; shift
  # NOT: döngü gövdesinin son komutu `[[ ]] && ...` olursa döngünün çıkış kodu 1 olur ve
  # `set -e` fonksiyonu orada bitirir — bu merdivende defalarca ısırdı. `if` kullan.
  local args=("$@") dur="" secs=300 i
  for (( i=0; i<${#args[@]}; i++ )); do
    if [[ "${args[i]}" == "--duration" ]]; then dur="${args[i+1]:-}"; fi
  done
  if [[ -n "$dur" ]]; then
    case "$dur" in
      *m) secs=$(( ${dur%m} * 60 )) ;;
      *s) secs=${dur%s} ;;
      *)  secs=$dur ;;
    esac
  fi
  # --duration yoksa senaryo kendi aşamalarını (stages) tanımlıyordur: stairs ~200 sn,
  # burst ~70 sn. 300 sn taban + 240 sn pay, hepsini rahatça kapsar.
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=300
  with_timeout $(( secs + 240 )) "$LADDER_ROOT/platform/lib/k6run.sh" "$s" --summary-export "$K6_SUMMARY" "${args[@]}"
}
# k6 özeti YOKSA (koşu hiç başlamadıysa) jq dosya bulamayıp hata veriyor ve `set -e` scripti
# öldürüyor. Yokluk bir ölçüm sonucudur: 0 döndür ama STDERR'e söyle.
_k6q() {
  [[ -s "$K6_SUMMARY" ]] || { printf '  \033[33mk6 özeti yok (%s) — 0 sayıldı\033[0m\n' "$K6_SUMMARY" >&2; echo 0; return 0; }
  jq -r "$1" "$K6_SUMMARY" 2>/dev/null || echo 0
}
k6_failed_rate() { _k6q '.metrics.http_req_failed.value // .metrics.http_req_failed.rate // 0'; }
k6_reqs()        { _k6q '.metrics.http_reqs.count // 0'; }
# 5xx ve 404'ü ayrı oku: biri altyapı kesintisi, diğeri uygulamanın "yok" demesi (bkz. platform/k6/lib/ladder.js).
k6_5xx()         { _k6q '.metrics.http_5xx.count // 0'; }
k6_404()         { _k6q '.metrics.http_404.count // 0'; }
k6_429()         { _k6q '.metrics.http_429.count // 0'; }
