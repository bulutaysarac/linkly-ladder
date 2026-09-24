#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-05 · Index yok → seq scan. Küçük veride görünmez, büyük veride olay.
# migrations/001 tenant üzerinde index OLUŞTURMUYOR (bilerek). ListByTenant bu yüzden tüm tabloyu tarar.
ROWS=${ROWS:-300000}
ensure_healthy
pgpod=$(dep_pod app.kubernetes.io/name=postgres) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
psql() { kubectl -n "$NS" exec "$pgpod" -c postgres -- psql -U linkly -d linkly -tAc "$1" 2>/dev/null; }
step "Tabloyu $ROWS satıra kadar doldur (tek INSERT ... generate_series)"
before=$(psql "SELECT count(*) FROM links")
note "mevcut satır: ${before:-?}"
psql "INSERT INTO links (code, url, tenant, created_at)
      SELECT substr(md5(random()::text), 1, 7) || i, 'https://example.com/seed/' || i,
             CASE WHEN i % 100 = 0 THEN 'acme' ELSE 'tenant-' || (i % 50) END,
             now() - (i || ' seconds')::interval
      FROM generate_series(1, $ROWS) i ON CONFLICT DO NOTHING" >/dev/null
psql "ANALYZE links" >/dev/null
after=$(psql "SELECT count(*) FROM links")
note "şimdi: ${after:-?} satır"
step "Sorgu planı: index mi, seq scan mi?"
# NOT: planın tamamını arıyoruz. `head -6` gibi bir kırpma "Parallel Seq Scan" satırını kesebilir —
# ölçtüğün kanıtı, okunabilirlik uğruna kırpma.
plan=$(psql "EXPLAIN (ANALYZE, BUFFERS) SELECT code FROM links WHERE tenant='acme' ORDER BY created_at DESC LIMIT 100")
{ echo "$plan" | head -8 | sed 's/^/    /'; } || true
# BULAMAMAK HATA DEĞİLDİR — ve burada bulamamak ASIL BEKLENEN SONUÇTUR.
# EN: when the index is in place there is no "Seq Scan" line, `grep` exits 1, `pipefail` fails the
#     pipeline and `set -e` kills the script on a failing assignment — so the script dies exactly
#     on the path where it should print NOT-REPRODUCED ("the index is being used"). A guard that
#     only breaks on success is the worst kind.
# TR: indeks yerindeyken "Seq Scan" satırı yoktur; `grep` 1 döner, `pipefail` boru hattını
#     düşürür ve `set -e` başarısız atamada scripti öldürür — yani script tam olarak
#     NOT-REPRODUCED basması gereken yolda ölür. Yalnızca başarıda bozulan bir koruma, en kötüsü.
scan_line=$(echo "$plan" | grep -i "Seq Scan" | head -1 || true)
seq_before=$(promq "sum(pg_stat_user_tables_seq_scan{namespace=\"$NS\",relname=\"links\"})")
step "API üzerinden list — kullanıcının hissettiği süre"
t=$(curl -s -o /dev/null -w '%{time_total}' -H 'X-Tenant-ID: acme' "$BASE_URL/api/links")
sleep 12
seq_after=$(promq "sum(pg_stat_user_tables_seq_scan{namespace=\"$NS\",relname=\"links\"})")
listp99=$(promq "histogram_quantile(0.99, sum(rate(db_query_duration_seconds_bucket{namespace=\"$NS\",op=\"list\"}[5m])) by (le))")
grafana_hint "05 · Postgres → 'seq scan / idx scan' · 'DB query p99 by op' (op=list)"
note "GET /api/links süresi: ${t}s · list p99: $(awk -v v="$listp99" 'BEGIN{printf "%.0f", v*1000}') ms · seq_scan sayacı: ${seq_before%%.*} → ${seq_after%%.*}"
note "ÇÖZÜM (002 migration, CONCURRENTLY): deploy/migrate-job.yaml'da MIGRATE_TARGET'ı 2 yap, sonra"
note "  kubectl -n $NS delete job migrate && make deploy   →  bu scripti tekrar koş"
note "  (ya da README P02-05 rehberindeki psql komutuyla aynı indeksi elle oluştur)"
note "Dikkat: düz CREATE INDEX tabloyu KİLİTLER; 002 bu yüzden CONCURRENTLY kullanıyor."
if [[ -n "$scan_line" ]]; then
  reproduced "planda Seq Scan var (${after:-?} satır, list ${t}s) — tenant index'i yok"
fi
not_reproduced "sorgu index kullanıyor — 002 migration uygulanmış"
