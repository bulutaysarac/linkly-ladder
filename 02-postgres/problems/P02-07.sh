#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-07 · TRAP_MIGRATE_IN_MAIN: migration'ı her pod kendi açılışında koşarsa N replika yarışır
# Varsayılan doğru: tek seferlik Job. Tuzağı açınca pod'lar AYNI tek seferlik işi aynı anda yapar.
#
# ÖLÇÜM NOTU — yarış kendiliğinden OLMAZ.
# Job da pod'lar da aynı hedefle (MIGRATE_TARGET=1) koşarsa Job şemayı zaten 1'e getirmiştir ve her
# pod'un migration'ı bir no-op'tur. "migration koşuluyor" log satırı yapacak işi olmayan pod'da da
# basılır; bu satırları sayan bir hüküm üç no-op'u "tek seferlik iş üç kez yapıldı" diye okur. Üstelik
# goose'un UpTo'su advisory lock ALMIYOR — yani "yarışanlar kilitte sıraya girer" iddiası da goose'a
# değil, ancak tablonun kendi kilidine dayanabilir. Yarışın gerçekten olması için üç şart gerekiyor:
#   1) pod'ların YAPACAK BİR İŞİ olmalı: Job'ın uygulamadığı bir hedef (002, tenant index'i) — tıpkı
#      yeni bir sürümün yeni bir migration getirmesi gibi;
#   2) pod'lar AYNI ANDA başlamalı: rolling update ilk yeni pod'u TEK BAŞINA açar ve işi ona
#      yaptırır, sonrakiler hazır şemayı bulur. Bu yüzden 0'a inip hepsini birden açıyoruz;
#   3) iş, pod'ların başlangıç farkından UZUN sürmeli: 1000 satırda CREATE INDEX milisaniyedir ve
#      pencere hiç çakışmaz. Ölçeğe uydur: tabloyu büyüt (ROWS) ve neyi değiştirdiğini yaz.
# Hüküm log satırına değil VERİTABANININ KENDİ KAYDINA bakıyor: 002 goose_db_version'a kaç kez
# yazıldı, iki migration oturumu aynı anda koştu mu, biri kilit beklerken yakalandı mı, INVALID bir
# index kaldı mı, bir pod migration hatasıyla düştü mü.
# Ne beklenir (kümenin dışında, aynı Postgres 17'de üç eşzamanlı goose.UpTo ile ölçülen): çakışan
# oturumlar çoğunlukla "deadlock detected" (40P01) ile düşer — sırada bekleyen CREATE INDEX
# CONCURRENTLY eski bir snapshot tutuyor, index'i kuran oturum da o snapshot'ın bitmesini bekliyor.
# Bazı turlarda 002 iki kez kaydedilir, bazılarında index'i kuran oturum ölür ve geride INVALID bir
# index "uygulandı" olarak kalır. Pencere çakışmazsa (başlangıç farkı > migration süresi) hiçbiri olmaz.
# EN: if Job and pods target the same version, every pod runs a no-op, and a verdict that counts
#     the "migration running" log line (no-op pods print it too) sees a race that never happened.
#     goose's UpTo takes no advisory lock. A real race needs work to do (a target the Job has not applied), pods that start
#     together (a rolling update lets the first new pod migrate alone) and a migration longer than
#     the start skew (grow the table). The verdict reads the database's own record, not a log line.
ROWS=${ROWS:-2000000}
TARGET=2
ensure_healthy
# Yalnızca UYGULAMA pod'ları: APP_SELECTOR (part-of) postgres'i ve migrate Job'ını da seçer.
appsel="app.kubernetes.io/name=$(app_name)"
pgpod=$(dep_pod app.kubernetes.io/name=postgres) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
psql() { kubectl -n "$NS" exec "$pgpod" -c postgres -- psql -U linkly -d linkly -tAc "$1" 2>/dev/null; }

step "Başlangıç: şema hangi sürümde, migration nerede koşuyor?"
kubectl -n "$NS" get job migrate -o jsonpath='  Job: {.metadata.name} · tamamlanan: {.status.succeeded}{"\n"}' 2>/dev/null || note "  Job bulunamadı"
ver=$(psql "SELECT coalesce(max(version_id), 0) FROM goose_db_version WHERE is_applied" || true)
[[ "$ver" =~ ^[0-9]+$ ]] || { warn "şema sürümü okunamadı (goose_db_version yok mu? önce make up)"; exit 2; }
note "şema sürümü: $ver · pod'lar tuzakla hedef $TARGET'ye (002 · tenant index'i) çıkmaya çalışacak"
if (( ver >= TARGET )); then
  # Yapacak iş yoksa yarış da yoktur — bu bir ölçüm sonucu değil, ölçülemeyen bir durumdur.
  warn "002 zaten uygulanmış (P02-05 çözümü?) — pod'lara yarışacak bir migration kalmadı."
  warn "geri almak için: kubectl -n $NS exec $pgpod -c postgres -- psql -U linkly -d linkly -c 'DROP INDEX CONCURRENTLY IF EXISTS links_tenant_created_idx' -c 'DELETE FROM goose_db_version WHERE version_id >= 2'"
  exit 2
fi

orig=$(replicas_of)
# Temizlik TERS sırada koşar: önce tuzak kapanır ve pod'lar tuzaksız açılır, SONRA şema geri alınır
# (tersi olursa crashloop'taki tuzaklı bir pod 002'yi yeniden uygulayabilir). P02-05 index'siz
# tabloyu ölçüyor; bu deney 002'yi bırakırsa P02-05 sessizce "sorun yok" der.
restore_schema() {
  psql "DROP INDEX CONCURRENTLY IF EXISTS p0207_probe_idx" >/dev/null || true
  psql "DROP INDEX CONCURRENTLY IF EXISTS links_tenant_created_idx" >/dev/null || true
  psql "DELETE FROM goose_db_version WHERE version_id >= $TARGET" >/dev/null || true
  psql "DELETE FROM links WHERE tenant = 'p02-07-bulk'" >/dev/null || true
}
on_cleanup "restore_schema"
on_cleanup "setenv $(app_workload) TRAP_MIGRATE_IN_MAIN- MIGRATE_TARGET-; kubectl -n $NS scale $(app_workload) --replicas=$orig; wait_ready"

step "Tabloyu $ROWS satıra büyüt — migration, pod'ların başlangıç farkından uzun sürmeli"
have=$(psql "SELECT count(*) FROM links" || true); have=${have:-0}
if (( ROWS > have )); then
  psql "INSERT INTO links (code, url, tenant, created_at)
        SELECT 'p7-' || i, 'https://example.com/p0207/' || i, 'p02-07-bulk', now() - (i || ' seconds')::interval
        FROM generate_series(1, $(( ROWS - have ))) i ON CONFLICT DO NOTHING" >/dev/null || true
fi
note "links: $have → $(psql "SELECT count(*) FROM links" || true) satır"
# Pencerenin genişliğini ÖLÇ, varsayma: aynı index'i başka adla bir kez kur, süresini al, sil.
# (Yarıda kalmış bir önceki koşudan kalan probe index'i varsa IF NOT EXISTS atlar ve süre ~0 çıkar.)
psql "DROP INDEX CONCURRENTLY IF EXISTS p0207_probe_idx" >/dev/null || true
probe_ms=$(kubectl -n "$NS" exec "$pgpod" -c postgres -- psql -U linkly -d linkly -c '\timing on' \
             -c "CREATE INDEX CONCURRENTLY IF NOT EXISTS p0207_probe_idx ON links (tenant, created_at DESC)" 2>/dev/null \
           | awk '/^Time:/{t=$2} END{printf "%d", t+0}' || true)
psql "DROP INDEX CONCURRENTLY IF EXISTS p0207_probe_idx" >/dev/null || true
note "002 tek başına ~${probe_ms:-?} ms sürüyor — yarış penceresi bu; pod'lar bundan daha yakın aralıkla başlarsa çakışırlar"

step "Tuzağı aç: TRAP_MIGRATE_IN_MAIN=true + MIGRATE_TARGET=$TARGET, $orig pod'u AYNI ANDA başlat"
note "rolling update ilk yeni pod'u tek başına açıp işi ona yaptırırdı — yarışı gizler. Önce 0'a iniyoruz."
kubectl -n "$NS" scale "$(app_workload)" --replicas=0 >/dev/null
for _ in $(seq 1 60); do [[ -z "$(kubectl -n "$NS" get pods -l "$appsel" --no-headers 2>/dev/null || true)" ]] && break; sleep 2; done
setenv "$(app_workload)" TRAP_MIGRATE_IN_MAIN=true MIGRATE_TARGET="$TARGET" >/dev/null
# Migration oturumlarını pod'lar açılırken örnekle: kaç tanesi AYNI ANDA koşuyor, kaçı kilit bekliyor?
samples=$(mktemp); on_cleanup "rm -f $samples"
( for _ in $(seq 1 80); do
    psql "SELECT count(*) FILTER (WHERE wait_event_type = 'Lock'), count(*) FROM pg_stat_activity
          WHERE pid <> pg_backend_pid() AND state = 'active' AND query ILIKE '%links_tenant_created_idx%'" >> "$samples" || true
    sleep 0.3
  done ) >/dev/null 2>&1 &
sampler=$!
kubectl -n "$NS" scale "$(app_workload)" --replicas="$orig" >/dev/null
rc=0; kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null 2>&1 || rc=$?
wait_pid_quiet "$sampler"
sleep 3

step "Kanıt: veritabanının kendi kaydı ve pod logları"
applied=$(psql "SELECT count(*) FROM goose_db_version WHERE version_id = $TARGET AND is_applied" || true); applied=${applied:-0}
invalid=$(psql "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                WHERE c.relname = 'links_tenant_created_idx' AND NOT i.indisvalid" || true); invalid=${invalid:-0}
maxwait=$(awk -F'|' '$1+0 > m {m = $1+0} END {print m+0}' "$samples")
maxrun=$(awk -F'|' '$2+0 > m {m = $2+0} END {print m+0}' "$samples")
logs=$(kubectl -n "$NS" logs -l "$appsel" --tail=300 --prefix 2>/dev/null || true)
prev=$(for p in $(kubectl -n "$NS" get pods -l "$appsel" -o name 2>/dev/null || true); do kubectl -n "$NS" logs "$p" --previous --tail=100 2>/dev/null || true; done)
failed=$(printf '%s\n%s\n' "$logs" "$prev" | count_lines 'migration başarısız')
did=$(printf '%s\n' "$logs" | count_lines "\"msg\":\"migration bitti\",\"from\":$ver,\"to\":$TARGET")
{ printf '%s\n' "$logs" | grep '"msg":"migration bitti"' | sed 's/^/    /' | head -6; } || true
grafana_hint "01 · Pods & Resources → 'Hazır pod adresi (endpoint) sayısı' · 05 · Postgres → 'Kilitler (türe göre)'"
note "rollout: $([[ $rc == 0 ]] && echo tamam || echo "TIMEOUT ($rc)") · toplam restart: $(restarts)"
note "002 goose_db_version'a $applied kez yazıldı · 'from=$ver to=$TARGET' diyen pod: $did · migration hatası: $failed"
note "aynı anda koşan migration oturumu (en çok): $maxrun · kilit beklerken yakalanan: $maxwait · INVALID index: $invalid"
{ printf '%s\n%s\n' "$logs" "$prev" | grep 'migration başarısız' | head -1 | cut -c1-240 | sed 's/^/    /'; } || true
note "goose (UpTo) kilit almıyor: her pod 'şema $ver'de' diye okuyup aynı işe girişiyor. Tablo kilidi"
note "CREATE INDEX'leri sıraya sokmaya çalışır, ama sıradaki oturumun snapshot'ı ile index'i kuran oturum"
note "birbirini bekler ve Postgres birini 'deadlock detected' ile öldürür: pod düşer, yeniden açılır."
note "Asıl tehlike: uygulamayı geri alırsan (rollback) ŞEMA geri gelmez. Şema değişikliği dağıtımın"
note "parçası değil, AYRI ve tek seferlik bir adımdır — 12'de expand/contract ile derinleşecek."
if (( applied > 1 || maxrun > 1 || maxwait > 0 || failed > 0 || invalid > 0 )); then
  reproduced "tek seferlik migration birden çok pod'da aynı anda koştu: 002 $applied kez kaydedildi, aynı anda $maxrun oturum, kilit bekleyen $maxwait, hata $failed, INVALID index $invalid"
fi
not_reproduced "002'yi tek pod uyguladı, diğerleri hazır şemayı buldu (aynı anda en çok $maxrun oturum) — pencere çakışmadı (${probe_ms:-?} ms); ROWS büyütülüp tekrar denenebilir"
