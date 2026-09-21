#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P09-04 · Replikada uzun okuma: "canceling statement due to conflict with recovery"
# Replika, primary'den gelen WAL'i uygulamak ZORUNDADIR. Uzun süren bir okuma sorgusu, silinmesi
# gereken bir satırı hâlâ okuyorsa çakışma olur ve Postgres SORGUYU İPTAL EDER. Yani replikaya
# "okuma yükünü at" demek, uzun sorguların iptal edilebileceğini kabul etmektir.
ensure_healthy
pgpod=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=replica') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
prim=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
[[ -z "$pgpod" ]] && { warn "replika bulunamadı"; exit 2; }
rpsql() { kubectl -n "$NS" exec "$pgpod" -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>&1; }
ppsql() { kubectl -n "$NS" exec "$prim"  -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>&1; }
step "hot_standby_feedback ayarı"
fb=$(rpsql "SHOW hot_standby_feedback")
note "replika hot_standby_feedback = ${fb:-?}"
note "on  → replika, primary'ye 'şu satırları hâlâ okuyorum' der; vacuum bekler (çakışma azalır, ŞİŞME artar)"
note "off → primary umursamaz; uzun okumalar İPTAL edilir (çakışma artar, şişme azalmaz)"
step "Replikada uzun bir okuma başlat, aynı anda primary'de yoğun yazma+vacuum yap"
( rpsql "SELECT count(*) FROM (SELECT pg_sleep(0.001), * FROM links LIMIT 200000) t" > /tmp/p0904.out 2>&1 ) &
qpid=$!
sleep 2
ppsql "INSERT INTO links (code, url, tenant) SELECT substr(md5(random()::text),1,7)||i, 'https://e/'||i, 'vac' FROM generate_series(1,50000) i ON CONFLICT DO NOTHING" >/dev/null
ppsql "DELETE FROM links WHERE tenant='vac'" >/dev/null
ppsql "VACUUM links" >/dev/null
wait $qpid 2>/dev/null || true
out=$(cat /tmp/p0904.out 2>/dev/null | head -c 300); rm -f /tmp/p0904.out
conflicts=$(rpsql "SELECT confl_snapshot + confl_bufferpin + confl_deadlock + confl_lock + confl_tablespace FROM pg_stat_database_conflicts WHERE datname='linkly'")
grafana_hint "05 · Postgres → 'replication lag' + 'dead tuples'"
note "replikadaki sorgu çıktısı: ${out:-<boş>}"
note "replikada kaydedilen çakışma sayısı: ${conflicts:-0}"
note "Bu seviyede hot_standby_feedback=on olduğu için çakışma BEKLENMİYOR — bedeli primary'de"
note "gecikmiş vacuum ve artan şişme. Kapatmak isteseydin: uzun analitik sorgularını replikadan"
note "tamamen çıkarman ya da iptal edilmelerini kabul etmen gerekirdi."
note "Genel kural: bir replika 'ücretsiz okuma kapasitesi' değildir. Primary ile arasında bir"
note "PAZARLIK vardır ve pazarlığın hangi tarafını seçtiğini bilmezsen, seni o taraf bulur."
awk -v c="${conflicts:-0}" 'BEGIN{exit !(c>0)}' \
  && reproduced "replikada ${conflicts} okuma çakışması kaydedildi — uzun sorgular WAL uygulamasıyla yarışıyor"
not_reproduced "çakışma olmadı (hot_standby_feedback=on bunu bekleniyordu: pazarlığın bedeli primary'de şişme)"
