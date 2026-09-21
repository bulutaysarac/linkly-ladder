#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P09-06 · "Yanlışlıkla sildim": yedek olmadan geri dönüş yok, yedekle var
# 02'de bu deneyi yapamazdık — yedek yoktu, yani veri kaybı KALICIYDI. Şimdi CNPG sürekli
# yedekleme yapabiliyor. Bu script yedeğin VAR OLDUĞUNU değil, GERİ YÜKLENEBİLİR olduğunu sorar:
# test edilmemiş bir yedek, yedek değildir.
ensure_healthy
prim=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
repl=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=replica') || exit 2
psql() { kubectl -n "$NS" exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>/dev/null; }
step "Yedekleme yapılandırması var mı?"
backup=$(kubectl -n "$NS" get cluster pg -o jsonpath='{.spec.backup}' 2>/dev/null) || true
note "cluster.spec.backup: ${backup:-YOK}"
if [[ -z "$backup" ]]; then
  note "Bu seviyede nesne deposu (MinIO/S3) YAPILANDIRILMADI — bilerek."
  note "Sebebi: yedeklemeyi 'açmak' bir YAML satırı; asıl mesele geri yükleme TATBİKATIDIR ve"
  note "onu yapmadan 'yedeğimiz var' demek, yedeği olduğunu SANMAKTIR."
fi
step "WAL arşivleme ve PITR için gereken temel: süreklilik"
lsn=$(psql "SELECT pg_current_wal_lsn()")
walkeep=$(psql "SHOW wal_keep_size")
note "mevcut WAL LSN=${lsn:-?} · wal_keep_size=${walkeep:-?}"
step "Replikalar bir yedek DEĞİLDİR: silmeyi de replike ederler"
code=$(create_link "https://example.com/oops")
sleep 3
before_r=$(kubectl -n "$NS" exec "$repl" -c postgres -- psql -U postgres -d linkly -tAc "SELECT count(*) FROM links WHERE code='$code'" 2>/dev/null) || true
need_confirm "test linki silinecek (yalnızca bu satır)"
psql "DELETE FROM links WHERE code='$code'" >/dev/null
sleep 3
after_r=$(kubectl -n "$NS" exec "$repl" -c postgres -- psql -U postgres -d linkly -tAc "SELECT count(*) FROM links WHERE code='$code'" 2>/dev/null) || true
grafana_hint "05 · Postgres → replication lag"
note "silme öncesi replikada: ${before_r:-?} satır · silme sonrası: ${after_r:-?} satır"
note "Replikasyon bir YEDEK DEĞİLDİR: hatanı da saniyeler içinde kopyalar."
note "Yedek, ZAMANDA GERİ GİTME yeteneğidir — replika ise zamanda İLERİ gitmenin kopyasıdır."
note "Gerçek koruma üç ayaklıdır: (1) sürekli WAL arşivleme, (2) periyodik temel yedek,"
note "(3) DÜZENLİ GERİ YÜKLEME TATBİKATI. Üçüncüsü olmadan ilk ikisi bir temennidir."
note "Bu merdivende (3)'ü game day olarak 14'e bıraktık; (1) ve (2) bir barmanObjectStore bloğudur."
{ [[ "${before_r:-0}" == "1" ]] && [[ "${after_r:-1}" == "0" ]]; } \
  && reproduced "silme replikaya da yayıldı (${before_r} → ${after_r}) — replikasyon yedek değildir, yedekleme yapılandırılmamış"
not_reproduced "silme replikaya yansımadı (replikasyon çalışıyor mu?)"
