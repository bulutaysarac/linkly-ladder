#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P09-03 · TRAP_PREPARED_STATEMENTS: transaction havuzlaması + prepared statement = aralıklı hata
# PgBouncer transaction modunda bir bağlantı sana YALNIZCA bir işlem süresince aittir. pgx bir
# arka uç bağlantısında "prepare" eder, başka birinde "execute" etmeye çalışır ve
# "prepared statement ... does not exist" alır. Yük arttıkça olasılık artar: en kötü hata türü,
# ARALIKLI olandır.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_PREPARED_STATEMENTS=false"
step "Pooler modu"
kubectl -n "$NS" get pooler pg-pooler-rw -o jsonpath='    poolMode={.spec.pgbouncer.poolMode} · default_pool_size={.spec.pgbouncer.parameters.default_pool_size}{"\n"}' 2>/dev/null
step "(1) Varsayılan (prepared KAPALI, QueryExecModeExec): yük ver"
k6run mixed --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 10
err_off=$(promq "sum(increase(db_queries_total{namespace=\"$NS\",result=\"error\"}[3m]))")
e5_off=$(k6_5xx)
note "prepared kapalı: DB hatası=${err_off%%.*} · 5xx=$e5_off"
step "(2) TRAP: prepared statement AÇIK"
setenv "$(wl redirect)" TRAP_PREPARED_STATEMENTS=true >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
k6run mixed --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 10
err_on=$(promq "sum(increase(db_queries_total{namespace=\"$NS\",result=\"error\"}[3m]))")
e5_on=$(k6_5xx)
logs=$(kubectl -n "$NS" logs -l app.kubernetes.io/name=redirect --tail=200 2>/dev/null | grep -ci 'prepared statement' || true)
grafana_hint "03 · App Business → 'Yönlendirme sonuçları' (error) · 02 · App RED → '5xx (uç noktaya göre)'"
note "prepared açık: DB hatası=${err_on%%.*} · 5xx=$e5_on · logda 'prepared statement' geçen satır=$logs"
note "Genel ders: bağlantıları ÇOĞULLAYAN bir proxy, 'bağlantı'nın ne demek olduğunu değiştirir."
note "Bağlantı kimliğine dayanan HER özellik yeniden gözden geçirilmelidir:"
note "  prepared statement · oturum değişkenleri (SET) · LISTEN/NOTIFY · geçici tablolar · advisory lock"
note "Seçenekler: (a) client tarafı exec modu (uygulanmış), (b) PgBouncer'da max_prepared_statements>0,"
note "(c) session pooling (çoğullama oranını kaybedersin — yani Pooler'ı almanın sebebini)."
{ awk -v a="${err_off%%.*}" -v b="${err_on%%.*}" 'BEGIN{exit !(b > a)}' || (( logs > 0 )); } \
  && reproduced "prepared statement açıkken hata arttı (${err_off%%.*} → ${err_on%%.*}, logda $logs satır) — transaction havuzlaması ile uyumsuz"
not_reproduced "fark ölçülemedi (PgBouncer max_prepared_statements ayarlı olabilir)"
