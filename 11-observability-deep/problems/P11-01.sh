#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-01 · "p99 yüksek — NEREDE?" sorusunun cevabı
# Metrikler p99'un yüksek OLDUĞUNU söyler. Hangi bağımlılıkta, hangi adımda olduğunu söylemez.
# Bu script önce SENİ tahmin etmeye zorluyor, sonra trace'in cevabı nasıl saniyeler içinde
# verdiğini gösteriyor. Aradaki fark, bir gecelik nöbetle bir kahve molası arasındaki farktır.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Önce temiz taban"
k6run redirect --vus 20 --duration 30s >/dev/null 2>&1 || true
sleep 10
base=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
note "taban p99=$(awk -v v="$base" 'BEGIN{printf "%.0f", v*1000}') ms"
step "Gizli bir gecikme enjekte ediliyor (hangi bağımlılık olduğunu SÖYLEMİYORUZ)"
chaos_apply redis-delay-200ms
sleep 5
k6run redirect --vus 20 --duration 40s >/dev/null 2>&1 || true
sleep 12
slow=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[2m])) by (le))")
note "şimdi p99=$(awk -v v="$slow" 'BEGIN{printf "%.0f", v*1000}') ms — metrik sana BU KADARINI söylüyor"
step "Metrikle teşhis denemesi: bağımlılık bazlı gecikmeler"
# Her bağımlılığın kendi guard'ı ve `dep` etiketi var: Redis postgres guard'ının İÇİNDE ölçülseydi
# bu gecikme dep="postgres" altında görünür ve metrik yanlış kapıyı gösterirdi. Metrik KAPIYI
# söyler, ama yalnızca önceden ölçmeyi düşündüğün kapıları; tek bir isteğin adımlarını değil.
# EN: Redis has its own guard; timed inside the postgres one, this delay would show up as dep="postgres".
curl -sG "$PROM_URL/api/v1/query" --data-urlencode \
  "query=histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le, dep))" \
  | jq -r '.data.result[] | "    \(.metric.dep): \((.value[1]|tonumber*1000)|floor) ms"' 2>/dev/null || true
step "Trace ile teşhis: exemplar'dan tek bir yavaş isteğe atla"
# Exemplar yalnızca ÖRNEKLENMİŞ isteklerde var (%5): her nokta Tempo'da gerçekten bulunan bir trace.
ex=$(curl -sG "$PROM_URL/api/v1/query_exemplars" \
      --data-urlencode "query=http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}" \
      --data-urlencode "start=$(date -u -v-5M +%s 2>/dev/null || date -u -d '5 min ago' +%s)" \
      --data-urlencode "end=$(date -u +%s)" 2>/dev/null \
      | jq -r '[.data[]?.exemplars[]? | select((.value|tonumber) > 0.1) | .labels.trace_id] | .[0] // empty' 2>/dev/null || true)
note "yavaş bir isteğin trace_id'si (exemplar): ${ex:-<exemplar bulunamadı>}"
slowest=""
if [[ -n "$ex" ]]; then
  kubectl -n monitoring port-forward svc/tempo 13201:3200 >/dev/null 2>&1 &
  tpf=$!
  on_cleanup "kill $tpf"
  for _ in $(seq 1 10); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:13201/ready" && break; sleep 1; done
  spans=$(curl -s --max-time 10 "http://127.0.0.1:13201/api/traces/$ex" 2>/dev/null \
    | jq -r '[(.batches // .resourceSpans // [])[]
              | ([.resource.attributes[]? | select(.key=="service.name") | .value.stringValue][0]) as $svc
              | (.scopeSpans // .instrumentationLibrarySpans // [])[] | .spans[]?
              | {s: $svc, n: .name, d: (((.endTimeUnixNano|tonumber) - (.startTimeUnixNano|tonumber)) / 1e6)}]
             | sort_by(-.d) | .[:6][] | "\(.d|floor) ms  \(.n)  (\(.s))"' 2>/dev/null || true)
  kill "$tpf" 2>/dev/null || true
  if [[ -n "$spans" ]]; then
    note "Tempo'daki span'ler (en uzundan):"
    printf '%s\n' "$spans" | sed 's/^/      /'
    # Sunucu span'i hep en uzunudur; soru onun İÇİNDE süreyi kimin yediği: sürenin en az yarısını
    # taşıyan EN KÜÇÜK span (ebeveyn çocuğunu kapsar; cache.get ⊃ guard.redis → guard.redis).
    slowest=$(printf '%s\n' "$spans" | awk 'NR==1{m=$1} NR>1 && $1+0 >= m/2 {s=$3} END{print s}')
    note "sürenin gittiği adım: ${slowest:-?} — metrik 'yavaşladı' dedi, trace NEREDE olduğunu söylüyor"
  else
    note "trace Tempo'da henüz yok ya da okunamadı — Grafana → Explore → Tempo → bu trace_id"
  fi
  note "Log'dan da gidilebilir: Loki'de {namespace=\"$NS\"} |= \"$ex\" → satırdaki trace_id linki Tempo'ya götürür"
fi
grafana_hint "02 · App RED → 'p99 süre (uç noktaya göre)' · 11 · Resilience → 'Bağımlılık gecikmesi p99' · Explore → Tempo (exemplar'daki trace_id)"
note "Ders: metrik ÖLÇER, trace AÇIKLAR, log KANITLAR. Üçü ayrı araç değil, tek bir teşhis zinciridir —"
note "ve zinciri kuran şey ortak kimliktir (trace_id). Korelasyon araçların özelliği değil, KODDAKİ disiplindir."
awk -v a="$base" -v b="$slow" 'BEGIN{exit !(b > a)}' \
  && reproduced "p99 $(awk -v v="$base" 'BEGIN{printf "%.0f", v*1000}') → $(awk -v v="$slow" 'BEGIN{printf "%.0f", v*1000}') ms yükseldi; ${ex:+exemplar → trace: }${slowest:+süre $slowest adımında}"
not_reproduced "gecikme ölçülemedi (chaos uygulandı mı?)"
