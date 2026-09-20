#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-02 · Bağlantı havuzu taşması: replika sayısı × pool > max_connections
# Her pod kendi havuzunu "tek başınaymış gibi" boyutlar. 3×25=75 < 100 iken sorun yok;
# 10×25=250 > 100 olduğu anda Postgres yeni bağlantıları REDDEDER ve uygulama 503 döner.
ensure_healthy
need_confirm "replika 10'a çıkacak (deney sonunda geri alınır)"
orig=$(replicas_of)
on_cleanup "kubectl -n \"$NS\" scale deploy -l \"$APP_SELECTOR\" --replicas=$orig"
maxconn=$(promq "max(pg_settings_max_connections{namespace=\"$NS\"})")
poolper=$(promq "max(db_pool_max_conns{namespace=\"$NS\"})")
step "Matematik önce: pod başına havuz × replika, max_connections'ı aşıyor mu?"
note "max_connections=${maxconn%%.*} · pod başına havuz=${poolper%%.*} · şu anki replika=$orig → toplam $(( ${poolper%%.*} * orig ))"
note "10 replikada: $(( ${poolper%%.*} * 10 )) > ${maxconn%%.*} → taşma kaçınılmaz"
step "10 replikaya çık ve havuzları doldur"
scale 10; wait_endpoints 6
k6run mixed --vus 80 --duration 60s || true
sleep 12
used=$(promq "sum(pg_stat_activity_count{namespace=\"$NS\"})")
e5=$(k6_5xx); fr=$(k6_failed_rate)
errs=$(promq "sum(increase(db_queries_total{namespace=\"$NS\",result=\"error\"}[5m]))")
empty=$(promq "sum(increase(db_pool_empty_acquire_total{namespace=\"$NS\"}[5m]))")
grafana_hint "05 · Postgres → 'connections vs max' (tavana yapışma) + 'App pool: empty acquire/s'"
note "PG aktif bağlantı: ${used%%.*} / ${maxconn%%.*} · havuz boş bekleme: ${empty%%.*} · DB hatası: ${errs%%.*} · k6 5xx: $e5"
note "Kanıt logda: kubectl -n $NS logs -l app.kubernetes.io/name=linkly | grep -i 'too many clients'"
note "Asıl ders: havuz boyutu YEREL bir karar gibi görünür ama GLOBAL bir kaynağı tüketir."
note "Doğru cevap pool'u küçültmek değil (o da kuyruk yaratır) — araya bir havuz yöneticisi koymak: 09, PgBouncer."
{ awk -v e="${errs%%.*}" 'BEGIN{exit !(e>0)}' || (( e5 > 0 )); } \
  && reproduced "bağlantı limiti aşıldı: ${used%%.*}/${maxconn%%.*} bağlantı, ${errs%%.*} DB hatası, $e5 istek 5xx"
not_reproduced "limit aşılmadı (pooler devrede olabilir — 09)"
