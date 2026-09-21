#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P12-02 · Kırıcı migration: rolling update sırasında ESKİ ve YENİ kod aynı şemaya bakar
# Sütunu tek adımda yeniden adlandırmak, dağıtımın saniyeleri boyunca eski pod'ların var olmayan
# bir sütunu sorgulaması demektir. Buradaki sorun Postgres değil, DAĞITIM MODELİDİR: rolling
# update, iki sürümün BİR ARADA yaşayacağını garanti eder.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
prim=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
psql() { kubectl -n "$NS" exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>&1; }
on_cleanup "kubectl -n \"$NS\" exec $prim -c postgres -- psql -U postgres -d linkly -tAc \"ALTER TABLE links RENAME COLUMN url_old TO url\" >/dev/null 2>&1 || true"
step "Şu anki şema (expand uygulanmış: hem url hem target_url var)"
psql "SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='links'" | sed 's/^/    /'
step "Yük altında KIRICI migration'ı uygula (url → url_old)"
( k6run mixed --vus 15 --duration 90s >/tmp/p1202.k6 2>&1 ) & kpid=$!
sleep 15
t0=$(date +%s)
psql "ALTER TABLE links RENAME COLUMN url TO url_old" | sed 's/^/    /'
note "sütun yeniden adlandırıldı — çalışan pod'lar hâlâ 'url' sorguluyor"
sleep 25
errs=$(promq "sum(increase(db_queries_total{namespace=\"$NS\",result=\"error\"}[3m]))")
e5_mid=$(promq "sum(increase(http_requests_total{namespace=\"$NS\",code=~\"5..\"}[3m]))")
step "Geri al (rollback): sütunu eski adına döndür"
psql "ALTER TABLE links RENAME COLUMN url_old TO url" >/dev/null
t1=$(date +%s)
wait $kpid || true
e5=$(k6_5xx); reqs=$(k6_reqs)
grafana_hint "05 · Postgres → 'DB queries by op' (result=error) · 02 · App RED → 5xx"
note "kırık pencere: ~$((t1-t0)) sn · DB hatası=${errs%%.*} · 5xx (Prometheus)=${e5_mid%%.*} · k6 5xx=$e5"
note "Kritik nokta: uygulamayı GERİ ALSAN bile şema geri gelmez. Dağıtım geri alınabilir;"
note "migration ancak SEN geri alınabilir yazdıysan geri alınabilir."
note "Güvenli biçim ÜÇ dağıtımdır (migrations/006_expand.sql'deki yorumda tam olarak yazıyor):"
note "  1. EXPAND   → yeni sütunu ekle, HER İKİSİNE yaz     (bu sürüm)"
note "  2. MIGRATE  → geriye doldur, okumayı yeniye çevir   (sonraki sürüm)"
note "  3. CONTRACT → eskiye yazmayı bırak, sonra düşür     (daha sonraki sürüm)"
note "Her adım bağımsız geri alınabilir. 'Üç dağıtım fazla' diyorsan, bu deneyin 5xx sayısına bak."
{ awk -v e="${errs%%.*}" 'BEGIN{exit !(e>0)}' || (( e5 > 0 )); } \
  && reproduced "kırıcı migration ~$((t1-t0)) sn boyunca ${errs%%.*} DB hatası / $e5 adet 5xx üretti — eski pod'lar var olmayan sütunu sorguladı"
not_reproduced "hata gözlenmedi (pod'lar o sütunu okumuyor olabilir — sorgu şeklini kontrol et)"
