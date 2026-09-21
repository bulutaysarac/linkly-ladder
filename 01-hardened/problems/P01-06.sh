#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-06 · TRAP_METRIC_LABEL_CODE: kısa kodu metrik label'ı yapmak → kardinalite patlaması
# Metrik eklemek "ücretsiz" değildir. Sınırsız değerli bir label, her yeni değerde YENİ zaman serisi
# üretir; Prometheus'un belleği seri sayısıyla büyür ve bir noktada sorgular da Prometheus da yavaşlar.
ensure_healthy
N=${N:-400}
on_cleanup 'kubectl -n "$NS" set env deploy/linkly TRAP_METRIC_LABEL_CODE-'
step "Tuzağı aç: TRAP_METRIC_LABEL_CODE=true"
kubectl -n "$NS" set env deploy/linkly TRAP_METRIC_LABEL_CODE=true >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=120s >/dev/null || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
before=$(promq 'prometheus_tsdb_head_series')
note "Prometheus toplam seri sayısı (öncesi): ${before%%.*}"
step "$N farklı kısa kodu ziyaret et"
for i in $(seq 1 "$N"); do
  c=$(create_link "https://example.com/card/$i"); status_of "$c" >/dev/null
done
sleep 15
series=$(promq "count(count by (short_code) (http_requests_total{namespace=\"$NS\"}))")
after=$(promq 'prometheus_tsdb_head_series')
grafana_hint "02 · App RED → 'rps by route' (artık tek route yerine binlerce seri)"
note "http_requests_total'daki farklı short_code sayısı: ${series%%.*}"
note "Prometheus toplam seri: ${before%%.*} → ${after%%.*} (fark: $(( ${after%%.*} - ${before%%.*} )))"
note "1 milyon linkte bu label 1 milyon seri demek. Kural: label'lar SINIRLI kümelerden olmalı"
note "(route, method, status). Tekil kimlikler metriğe değil, log'a ve trace'e (exemplar) gider — 11."
step "Tuzağı kapat"
kubectl -n "$NS" set env deploy/linkly TRAP_METRIC_LABEL_CODE- >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=120s >/dev/null || true
awk -v s="${series%%.*}" 'BEGIN{exit !(s>50)}' \
  && reproduced "tek bir label ${series%%.*} yeni zaman serisi üretti; toplam seri $(( ${after%%.*} - ${before%%.*} )) arttı"
not_reproduced "kardinalite artmadı — kısa kod label olarak kullanılmıyor"
