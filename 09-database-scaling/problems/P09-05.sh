#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P09-05 · Partition'sız büyüyen tekilleştirme tablosu — ve partition'ın asıl faydası
# 06'daki processed_events tıklama başına bir satır ekliyor ve hiç temizlenmiyor. Devasa bir
# tablodan eski satırları SİLMEK pahalıdır (ölü satır, vacuum, şişme); bir PARTITION'ı DÜŞÜRMEK
# milisaniyeler sürer. Partition'lamanın asıl sebebi sorgu hızı değil, SİLMEYİ ucuzlatmaktır.
ensure_healthy
prim=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
psql() { kubectl -n "$NS" exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>/dev/null; }
ROWS=${ROWS:-500000}
step "Partition'lı tablo var mı?"
parts=$(psql "SELECT count(*) FROM pg_inherits WHERE inhparent = 'processed_events_p'::regclass")
note "processed_events_p partition sayısı: ${parts:-0}"
step "Düz tabloya $ROWS satır ekle ve SİLME maliyetini ölç"
psql "INSERT INTO processed_events (event_id, processed_at) SELECT 'bulk-'||i, now() - (i||' seconds')::interval FROM generate_series(1,$ROWS) i ON CONFLICT DO NOTHING" >/dev/null
psql "ANALYZE processed_events" >/dev/null
before_size=$(psql "SELECT pg_size_pretty(pg_total_relation_size('processed_events'))")
t0=$(date +%s%N)
psql "DELETE FROM processed_events WHERE processed_at < now() - interval '1 hour'" >/dev/null
t1=$(date +%s%N)
dead=$(psql "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='processed_events'")
after_size=$(psql "SELECT pg_size_pretty(pg_total_relation_size('processed_events'))")
del_ms=$(( (t1-t0)/1000000 ))
note "düz tablo: DELETE $del_ms ms · ölü satır=${dead:-?} · boyut ${before_size:-?} → ${after_size:-?}"
note "DİKKAT: DELETE'ten sonra tablo KÜÇÜLMEDİ. Silinen satırlar 'ölü' olarak duruyor ve yeri"
note "ancak VACUUM sonrası yeniden kullanılabiliyor; diske geri vermek için VACUUM FULL (kilit!) gerekir."
step "Partition'lı tabloda aynı temizlik: bir partition'ı DÜŞÜR"
oldpart=$(psql "SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent='processed_events_p'::regclass ORDER BY c.relname LIMIT 1")
if [[ -n "$oldpart" ]]; then
  t2=$(date +%s%N)
  psql "DROP TABLE $oldpart" >/dev/null
  t3=$(date +%s%N)
  note "partition düşürme ($oldpart): $(( (t3-t2)/1000000 )) ms · ölü satır ÜRETMEDİ"
else
  warn "partition bulunamadı (migration 005 uygulandı mı?)"
fi
grafana_hint "05 · Postgres → 'dead tuples' + tablo boyutu"
note "Karşılaştırma: DELETE $del_ms ms + vacuum borcu  vs  DROP PARTITION birkaç ms + borç YOK."
note "Saklama süresi bir ŞEMA kararıdır, bir zamanlanmış iş değil: tabloyu zamana göre bölersen"
note "silmek ücretsizleşir. Bölmezsen, her gece koşan bir DELETE cron'u ile yaşarsın."
note "Aynı desen clicks_daily için de geçerli olurdu (burada gerekmedi: satır sayısı kod×gün ile sınırlı)."
awk -v d="${dead:-0}" 'BEGIN{exit !(d>0)}' \
  && reproduced "düz tabloda DELETE ${dead} ölü satır bıraktı ($del_ms ms); partition düşürmek aynı işi borçsuz yapıyor"
not_reproduced "ölü satır ölçülemedi (autovacuum hızlı davranmış olabilir; ROWS'u artırıp tekrar dene)"
