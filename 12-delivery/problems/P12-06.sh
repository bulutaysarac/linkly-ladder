#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P12-06 · Uygulama geri alındı, migration geri alınmadı
# "Rollback" kelimesi tek bir şeymiş gibi konuşulur; aslında iki ayrı şeydir ve yalnızca biri
# otomatiktir. Kod sürümü saniyeler içinde geri alınır; şema geri alınmaz — çünkü geri almak,
# İLERİ bir işlemdir (yeni bir migration) ve veri kaybettirebilir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
prim=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
psql() { kubectl -n "$NS" exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>/dev/null; }
step "Şema sürümü ve uygulama sürümü ayrı ayrı izleniyor mu?"
dbver=$(psql "SELECT max(version_id) FROM goose_db_version")
appimg=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
note "şema sürümü (goose): ${dbver:-?} · uygulama imaj etiketi: ${appimg:-?}"
note "Bu iki sayı BAĞIMSIZ ilerliyor ve hiçbir yerde birbirine bağlı değil. 'Hangi kod hangi"
note "şemayla uyumlu?' sorusunun cevabı yalnızca insan hafızasında."
step "Migration'lar geri alınabilir mi? (Down bloğu var mı?)"
for f in "$(dirname "$0")"/../internal/store/migrations/*.sql; do
  n=$(basename "$f")
  has_down=$(grep -c '^-- +goose Down' "$f" || true)
  body=$(sed -n '/+goose Down/,$p' "$f" | grep -vc '^--' || true)
  printf '    %-28s Down bloğu: %s\n' "$n" "$([[ ${has_down:-0} -gt 0 ]] && echo var || echo YOK)"
done
step "Geri alınamayan değişiklik türleri"
note "  · DROP COLUMN / DROP TABLE → veri gitti, Down bloğu onu geri GETİREMEZ"
note "  · Veri dönüştürme (UPDATE ... SET x = f(y)) → ters fonksiyon yoksa geri alınamaz"
note "  · NOT NULL ekleme → geri almak kolay, ama araya giren NULL'sız satırlar sorun olmaz"
note "  · CREATE INDEX CONCURRENTLY → geri almak kolay (DROP INDEX CONCURRENTLY)"
grafana_hint "13 · Rollout → 'Rollout fazı' · 05 · Postgres"
note "Pratik kural: bir sürümde YALNIZCA geriye uyumlu şema değişikliği yap. Böylece uygulamayı"
note "geri almak şemayı geri almayı GEREKTİRMEZ — expand/contract'ın asıl sebebi budur."
note "Runbook'a yazılacak cümle: 'Uygulama geri alındığında şema İLERİ kalır ve bu SORUN DEĞİLDİR,"
note "çünkü N-1 sürümü N şemasıyla çalışabilir.' Bu cümleyi yazamıyorsan, migration'ın güvenli değil."
{ [[ -n "$dbver" ]] && [[ -n "$appimg" ]]; } \
  && reproduced "şema (v${dbver}) ve uygulama (${appimg}) sürümleri bağımsız ilerliyor; uyumluluk yalnızca expand/contract disipliniyle garanti ediliyor"
not_reproduced "sürüm bilgileri okunamadı"
