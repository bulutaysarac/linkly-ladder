#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-05 · Yavaş bir bağımlılık, ölü bir bağımlılıktan BETERDİR
# Ölü bağımlılık hızlı hata verir: bağlantı reddedilir, istek biter. Yavaş bağımlılık ise her
# isteği bekletir: goroutine'ler, bağlantılar ve bellek birikir. Sistem "çalışıyor" görünür ve
# yavaşça boğulur. Timeout'suz bir çağrı, sınırsız bir kuyruktur (P05-02'nin bağımlılık hâli).
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env "$(wl redirect)" TRAP_NO_DEP_TIMEOUT-"
on_cleanup "$LADDER_ROOT/platform/lib/chaos.sh delete redis-delay-3s"
step "Redis'e 3 sn gecikme enjekte et (ölmedi, YAVAŞLADI)"
chaos_apply redis-delay-3s
sleep 5
step "(1) Timeout VAR (varsayılan)"
k6run redirect --vus 30 --duration 45s >/dev/null 2>&1 || true
sleep 10
g_on=$(promq "max_over_time(sum(go_goroutines{namespace=\"$NS\",pod=~\"redirect.*\"})[3m:15s])")
m_on=$(peak_working_set_mb 4m)
p99_on=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")")
e5_on=$(k6_5xx)
note "timeout var: tepe goroutine=${g_on%%.*} · tepe bellek=${m_on}MB · p99=$(awk -v v="$p99_on" 'BEGIN{printf "%.0f", v*1000}') ms · 5xx=$e5_on"
step "(2) TRAP_NO_DEP_TIMEOUT: bağımlılık timeout'u yok"
kubectl -n "$NS" set env "$(wl redirect)" TRAP_NO_DEP_TIMEOUT=true >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
k6run redirect --vus 30 --duration 45s >/dev/null 2>&1 || true
sleep 10
g_off=$(promq "max_over_time(sum(go_goroutines{namespace=\"$NS\",pod=~\"redirect.*\"})[3m:15s])")
m_off=$(peak_working_set_mb 4m)
p99_off=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")")
restarts=$(restarts)
grafana_hint "01 · Pods → 'Goroutine' + 'Bellek working set' · 11 · Resilience → 'in-flight by pod'"
note "timeout yok: tepe goroutine=${g_off%%.*} · tepe bellek=${m_off}MB · p99=$(awk -v v="$p99_off" 'BEGIN{printf "%.0f", v*1000}') ms · restart=$restarts"
note "Not: Redis burada fail-open ile atlanabilir olduğu için hizmet sürüyor — asıl gözlem"
note "GOROUTINE ve BELLEK eğrisi. Timeout'suz her bekleyen çağrı bir goroutine tutar."
note "Kural: bir bağımlılığa yapılan HER çağrının bir süre sınırı olmalı; 'genelde hızlıdır'"
note "bir gerekçe değildir, çünkü sorun tam da 'genelde' olmadığı anda başlar."
awk -v a="${g_on%%.*}" -v b="${g_off%%.*}" 'BEGIN{exit !(b >= a)}' \
  && reproduced "timeout'suz yavaş bağımlılık goroutine'leri ${g_on%%.*} → ${g_off%%.*} ve belleği ${m_on} → ${m_off}MB büyüttü"
not_reproduced "fark ölçülemedi (redis-delay-3s uygulandı mı?)"
