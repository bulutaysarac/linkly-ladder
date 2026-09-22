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
curl -sG "$PROM_URL/api/v1/query" --data-urlencode \
  "query=histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le, dep))" \
  | jq -r '.data.result[] | "    \(.metric.dep): \((.value[1]|tonumber*1000)|floor) ms"' 2>/dev/null
step "Trace ile teşhis: exemplar'dan tek bir yavaş isteğe atla"
ex=$(curl -sG "$PROM_URL/api/v1/query_exemplars" \
      --data-urlencode "query=http_request_duration_seconds_bucket{namespace=\"$NS\"}" \
      --data-urlencode "start=$(date -u -v-5M +%s 2>/dev/null || date -u -d '5 min ago' +%s)" \
      --data-urlencode "end=$(date -u +%s)" 2>/dev/null \
      | jq -r '[.data[]?.exemplars[]? | select(.value > 0.1) | .labels.trace_id] | .[0] // empty' 2>/dev/null)
note "yavaş bir isteğin trace_id'si: ${ex:-<exemplar bulunamadı>}"
[[ -n "$ex" ]] && note "Grafana → Explore → Tempo → bu trace_id: hangi span'in süreyi yediği görünür"
note "Log'dan da gidilebilir: Loki'de {namespace=\"$NS\"} |= \"trace_id\" → satırdaki link Tempo'ya götürür"
grafana_hint "02 · App RED → 'latency p99' (exemplar noktaları) · 11 · Resilience → 'dependency p99 by dep'"
note "Ders: metrik ÖLÇER, trace AÇIKLAR, log KANITLAR. Üçü ayrı araç değil, tek bir teşhis zinciridir —"
note "ve zinciri kuran şey ortak kimliktir (trace_id). Korelasyon araçların özelliği değil, KODDAKİ disiplindir."
awk -v a="$base" -v b="$slow" 'BEGIN{exit !(b > a)}' \
  && reproduced "p99 $(awk -v v="$base" 'BEGIN{printf "%.0f", v*1000}') → $(awk -v v="$slow" 'BEGIN{printf "%.0f", v*1000}') ms yükseldi; kaynağı bağımlılık metrikleri ve ${ex:+exemplar/}trace ile bulunabiliyor"
not_reproduced "gecikme ölçülemedi (chaos uygulandı mı?)"
