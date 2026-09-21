#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-01 · Retry fırtınası: bütçesiz yeniden deneme bir YÜKSELTEÇTİR
# %30 hata oranında "3 deneme", bağımlılık ZATEN hata verirken bir kullanıcı isteğini üç
# bağımlılık çağrısına çevirir. Kurtarma aracı, arızanın hızlandırıcısına dönüşür.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env "$(wl redirect)" TRAP_NAIVE_RETRY-"
on_cleanup "$LADDER_ROOT/platform/lib/chaos.sh delete pg-loss-30"
run() {
  kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  k6run mixed --vus 25 --duration 45s >/dev/null 2>&1 || true
  sleep 10
  local calls retries p99
  calls=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"postgres\"}[3m]))")
  retries=$(promq "sum(increase(retry_total{namespace=\"$NS\",dep=\"postgres\"}[3m]))")
  p99=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")")
  echo "${calls%%.*} ${retries%%.*} $p99"
}
step "Postgres'e %30 paket kaybı enjekte et"
chaos_apply pg-loss-30
sleep 5
step "(1) BÜTÇELİ retry (varsayılan: 2 deneme, trafiğin %10'u)"
read -r c1 r1 p1 <<< "$(run)"
note "bütçeli: bağımlılık çağrısı=$c1 · retry=$r1 · p99=$(awk -v v="$p1" 'BEGIN{printf "%.0f", v*1000}') ms"
step "(2) TRAP_NAIVE_RETRY: 3 deneme, bütçe YOK, jitter yok"
kubectl -n "$NS" set env "$(wl redirect)" TRAP_NAIVE_RETRY=true >/dev/null
read -r c2 r2 p2 <<< "$(run)"
note "bütçesiz: bağımlılık çağrısı=$c2 · retry=$r2 · p99=$(awk -v v="$p2" 'BEGIN{printf "%.0f", v*1000}') ms"
grafana_hint "11 · Resilience → 'retry/s by dep' + 'dependency errors/s' · 05 · Postgres → DB CPU"
note "Bütçesiz retry, BAĞIMLILIK ÇAĞRISI sayısını artırır — yani hata anında yükü KATLAR."
note "Üstelik jitter'sız retry'lar senkronize olur: aynı anda hata alan herkes aynı anda tekrar dener."
note "Kural: retry bir KURTARMA aracıdır, bir KAPASİTE aracı değil. Bütçe olmadan retry, arızayı"
note "hızlandırır. Üç şey birlikte olmalı: üstel geri çekilme + jitter + bütçe."
awk -v a="$c1" -v b="$c2" 'BEGIN{exit !(b > a)}' \
  && reproduced "bütçesiz retry bağımlılık çağrılarını $c1 → $c2'ye çıkardı (retry $r1 → $r2) — kurtarma aracı yükseltece dönüştü"
not_reproduced "fark ölçülemedi (chaos uygulandı mı? pg-loss-30 gerekli)"
