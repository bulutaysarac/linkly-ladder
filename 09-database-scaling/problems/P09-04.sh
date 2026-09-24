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
# ÖLÇÜM SEÇİMİ: "çakışma oldu mu?" YANLIŞ SORUDUR.
# EN: this level sets hot_standby_feedback=on on purpose, so a cancellation is exactly what will
#     NOT happen — asking whether the behaviour you deliberately disabled occurred gets a dutiful
#     "no" every time. A question whose answer is fixed by your own configuration is not a
#     measurement. The trade-off is still real; it is just paid on the
#     OTHER side: the primary cannot vacuum rows that the replica's long query still needs, so
#     dead tuples accumulate and VACUUM cannot reclaim them. That side IS measurable.
# TR: bu seviye hot_standby_feedback=on'u bilerek açıyor, yani iptal TAM DA OLMAYACAK olan şey —
#     bilerek devre dışı bıraktığın davranışın gerçekleşip gerçekleşmediğini sormak her seferinde
#     uslu uslu "hayır" cevabını alır. Cevabı kendi yapılandırmanla SABİTLENMİŞ
#     bir soru, ölçüm değildir. Pazarlık yine de gerçek; yalnızca DİĞER taraftan ödeniyor:
#     replikanın uzun sorgusunun hâlâ ihtiyaç duyduğu satırları primary VACUUM EDEMEZ, ölü satırlar
#     birikir ve geri kazanılamaz. Ölçülebilir olan taraf bu.
step "Taban: ölü satırları temizle"
ppsql "VACUUM (ANALYZE) links" >/dev/null
base_dead=$(ppsql "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='links'")
note "VACUUM sonrası ölü satır: ${base_dead:-?}"

step "Replikada UZUN bir okuma başlat (primary'nin vacuum'unu rehin alır)"
( rpsql "SELECT count(*) FROM links, pg_sleep(45)" > /tmp/p0904.out 2>&1 ) &
qpid=$!
sleep 5
pinned=$(ppsql "SELECT coalesce(max(age(backend_xmin)),0) FROM pg_stat_replication WHERE backend_xmin IS NOT NULL")
note "primary'de replika tarafından REHİN ALINAN xmin yaşı: ${pinned:-0} işlem"
note "Bu sayı, replikanın 'bu andan eski hiçbir satırı silme' dediği noktadır."

step "Primary'de çöp üret ve VACUUM dene — rehin varken"
ppsql "INSERT INTO links (code, url, tenant) SELECT substr(md5(random()::text),1,7)||i, 'https://e/'||i, 'vac' FROM generate_series(1,50000) i ON CONFLICT DO NOTHING" >/dev/null
ppsql "DELETE FROM links WHERE tenant='vac'" >/dev/null
ppsql "VACUUM links" >/dev/null
held_dead=$(ppsql "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='links'")
note "rehin VARKEN VACUUM sonrası ölü satır: ${held_dead:-?} (temizlenemedi)"

step "Uzun sorgu bitsin, tekrar VACUUM"
wait_pid_quiet "$qpid"
out=$(head -c 200 /tmp/p0904.out 2>/dev/null); rm -f /tmp/p0904.out
sleep 5
ppsql "VACUUM links" >/dev/null
free_dead=$(ppsql "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='links'")
note "rehin YOKKEN VACUUM sonrası ölü satır: ${free_dead:-?}"
conflicts=$(rpsql "SELECT confl_snapshot + confl_bufferpin + confl_deadlock + confl_lock + confl_tablespace FROM pg_stat_database_conflicts WHERE datname='linkly'")
grafana_hint "05 · Postgres → 'Replikasyon gecikmesi' · Explore → cnpg_pg_stat_replication_backend_xmin_age ('Ölü satırlar' paneli 09+'da boş: CNPG tablo başına metrik yayınlamıyor)"
note "replikadaki uzun sorgu sonucu: ${out:-<boş>} · replikada çakışma: ${conflicts:-0} (feedback=on olduğu için 0 BEKLENİR)"
note "Pazarlığın iki tarafı:"
note "  feedback=on  → uzun okuma iptal EDİLMEZ, primary'de şişme birikir (ölçtüğümüz taraf)"
note "  feedback=off → şişme olmaz, uzun okuma 'canceling statement due to conflict' ile İPTAL edilir"
note "Genel kural: bir replika 'ücretsiz okuma kapasitesi' değildir. Primary ile arasında bir"
note "PAZARLIK vardır ve pazarlığın hangi tarafını seçtiğini bilmezsen, seni o taraf bulur."
note "Pratikte: uzun analitik sorguları AYRI bir replikaya (feedback=off) koy, OLTP okumalarını"
note "feedback=on olan replikada tut. Tek bir replikaya iki iş yükü koymak, iki bedeli birden ödemektir."
awk -v h="${held_dead:-0}" -v f="${free_dead:-0}" -v b="${base_dead:-0}" 'BEGIN{exit !(h > f && h > b)}' \
  && reproduced "replikadaki uzun sorgu primary'nin vacuum'unu rehin aldı: ölü satır ${base_dead} → ${held_dead} (rehin varken temizlenemedi) → ${free_dead} (sorgu bitince temizlendi); rehin alınan xmin yaşı ${pinned:-0}"
not_reproduced "rehin etkisi ölçülemedi (taban=${base_dead:-?} rehinli=${held_dead:-?} serbest=${free_dead:-?}) — çöp miktarını artır"
