#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P05-04 · Toplama tablosu ölçeklenir, ayrıntı tablosu ölçeklenmez
# clicks_daily (code, day) başına TEK satır tutuyor: 1 milyon tıklama = 1 satır. Eğer her tıklamayı
# ayrı satır olarak saklasaydık stats sorgusu bir count(*) taramasına dönerdi. Bu seviye doğru
# tercihi yapıyor; script yanlış tercihin ne kadar pahalı olacağını ÖLÇÜYOR.
ensure_healthy
pgpod=$(dep_pod app.kubernetes.io/name=postgres) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
psql() { kubectl -n "$NS" exec "$pgpod" -c postgres -- psql -U linkly -d linkly -tAc "$1" 2>/dev/null; }
ROWS=${ROWS:-2000000}
code=$(create_link "https://example.com/stats-scale")
step "Toplama tablosunda stats: mevcut hâli ölç"
for i in $(seq 1 200); do status_of "$code" >/dev/null; done
sleep 4
t_agg=$(curl -s -o /dev/null -w '%{time_total}' "$BASE_URL/api/links/$code/stats")
rows_agg=$(psql "SELECT count(*) FROM clicks_daily")
note "clicks_daily satır sayısı: ${rows_agg:-?} · stats süresi: ${t_agg}s"
step "Karşı senaryo: ayrıntı tablosu kursaydık ne olurdu? ($ROWS satır)"
psql "CREATE TABLE IF NOT EXISTS clicks_detail (id bigserial, code text, at timestamptz)" >/dev/null
psql "INSERT INTO clicks_detail (code, at)
      SELECT '$code', now() - (i || ' seconds')::interval FROM generate_series(1, $ROWS) i" >/dev/null
psql "ANALYZE clicks_detail" >/dev/null
# Planın TAMAMINI al: "Parallel Seq Scan" satırı 4. satıra düşebilir ve `head -3` ile kırpılmış bir
# plan onu keser (P02-05'te de aynı tuzak var). Kanıtı okunabilirlik uğruna kırpma; ekrana kırpılmışını bas.
detail_plan=$(psql "EXPLAIN (ANALYZE) SELECT count(*) FROM clicks_detail WHERE code='$code'")
{ echo "$detail_plan" | head -5 | sed 's/^/    /'; } || true
t_detail=$(psql "\timing on" >/dev/null; { time psql "SELECT count(*) FROM clicks_detail WHERE code='$code'" >/dev/null; } 2>&1 | awk '/real/{print $2}')
agg_plan=$(psql "EXPLAIN (ANALYZE) SELECT sum(count) FROM clicks_daily WHERE code='$code'")
{ echo "$agg_plan" | head -5 | sed 's/^/    /'; } || true
psql "DROP TABLE clicks_detail" >/dev/null
grafana_hint "07 · Analytics → 'İstatistik ucu süresi (p99)' · 05 · Postgres → 'Sorgu süresi p99 (türe göre)' (op=stats)"
note "ayrıntı tablosu count(*): ${t_detail:-?} ($ROWS satır) · toplama tablosu: ${rows_agg:-?} satırda anında"
note "Toplama, veriyi YAZARKEN küçültür; ayrıntı ise OKURKEN büyür. İkisi arasındaki seçim,"
note "'hangi soruları soracağım?' sorusuna verilen cevaptır — ve ayrıntıyı sonradan eklemek,"
note "toplamayı sonradan eklemekten çok daha pahalıdır (veri zaten yazılmıştır)."
note "09'da: ayrıntı gerekiyorsa partition (RANGE by day) + eski partition'ları düşürme."
echo "$detail_plan" | grep -qi 'seq scan' \
  && reproduced "ayrıntı tablosu $ROWS satırda tam tarama yapıyor; toplama tablosu ${rows_agg:-?} satırla aynı cevabı veriyor"
not_reproduced "ayrıntı tablosu taraması ölçülemedi"
