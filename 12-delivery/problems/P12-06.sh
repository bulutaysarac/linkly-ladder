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
appimg=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://') || true
note "şema sürümü (goose): ${dbver:-?} · uygulama imaj etiketi: ${appimg:-?}"
note "Bu iki sayı BAĞIMSIZ ilerliyor ve hiçbir yerde birbirine bağlı değil. 'Hangi kod hangi"
note "şemayla uyumlu?' sorusunun cevabı yalnızca insan hafızasında."
# DÜŞEMEYEN BİR DENEY, DENEY DEĞİLDİR.
# EN: a verdict like `[[ -n "$dbver" ]] && [[ -n "$appimg" ]]` passes whenever two strings can
#     be read, which is true in every healthy cluster. That is not a measurement of
#     the claim ("the app rolls back, the schema does not"); it is a tautology wearing a verdict's
#     clothes, and a script that cannot fail cannot tell you anything. The falsifiable version is
#     cheap and static: count the migrations that CANNOT be undone. If every migration in this
#     repo had a complete Down block and no destructive statement, the script would — correctly —
#     report NOT-REPRODUCED.
# TR: `[[ -n "$dbver" ]] && [[ -n "$appimg" ]]` gibi bir hüküm, iki metin okunabildiğinde geçer,
#     yani sağlıklı her kümede. Bu, iddianın ("uygulama geri alınır, şema alınmaz") ölçümü değil,
#     hüküm kılığına girmiş bir totolojidir; düşemeyen bir script sana hiçbir şey söyleyemez.
#     Falsifiye edilebilir hâli ucuz ve statiktir: geri ALINAMAYAN migration'ları say. Bu depodaki
#     her migration'ın eksiksiz bir Down bloğu olsaydı ve yıkıcı ifade içermeseydi, script haklı
#     olarak NOT-REPRODUCED derdi.
step "Migration'lar geri alınabilir mi? (Down bloğu var mı, içerik yıkıcı mı?)"
nodown=0; destructive=0; total=0
for f in "$(dirname "$0")"/../internal/store/migrations/*.sql; do
  n=$(basename "$f"); total=$(( total + 1 ))
  has_down=$(grep -c '^-- +goose Down' "$f" || true)
  # Down bloğunun GÖVDESİ: yalnızca başlık varsa geri alma yok demektir.
  body=$(sed -n '/+goose Down/,$p' "$f" | grep -vcE '^\s*(--|$)' || true)
  # ASIL SORU DOWN BLOĞUNUN VARLIĞI DEĞİL, NE YAPTIĞIDIR.
  # Bir Down bloğu `DROP TABLE` / `DROP COLUMN` içeriyorsa "geri alma" işlemi, Up'tan bu yana
  # o tabloya/sütuna yazılan HER ŞEYİ siler. Yani migration teknik olarak geri alınabilir,
  # pratikte ise geri alınamaz: kaybettiğin veri geri gelmez. `DROP INDEX` bunun istisnasıdır —
  # indeks türetilmiş veridir, yeniden kurulabilir.
  # EN: the question is not whether a Down block exists but what it DOES. A Down that drops a
  # table or a column deletes everything written since the Up: technically reversible, practically
  # not. `DROP INDEX` is the exception — an index is derived data and can be rebuilt.
  bad=$(sed -n '/+goose Down/,$p' "$f" | grep -icE 'drop +(column|table)|truncate' || true)
  [[ ${has_down:-0} -eq 0 || ${body:-0} -eq 0 ]] && nodown=$(( nodown + 1 ))
  [[ ${bad:-0} -gt 0 ]] && destructive=$(( destructive + 1 ))
  printf '    %-28s Down: %-4s gövde: %-4s geri alma veri kaybettiriyor: %s\n' "$n" \
    "$([[ ${has_down:-0} -gt 0 ]] && echo var || echo YOK)" \
    "$([[ ${body:-0} -gt 0 ]] && echo var || echo YOK)" \
    "$([[ ${bad:-0} -gt 0 ]] && echo EVET || echo hayır)"
done
note "$total migration · geri alma bloğu olmayan: $nodown · geri alması veri kaybettiren: $destructive"
note "\"Down bloğu var\" ile \"geri alınabilir\" aynı şey değildir: DROP COLUMN'lu bir Down,"
note "Up'tan bu yana o sütuna yazılan her şeyi siler. Geri alma İLERİ bir işlemdir."
step "Geri alınamayan değişiklik türleri"
note "  · DROP COLUMN / DROP TABLE → veri gitti, Down bloğu onu geri GETİREMEZ"
note "  · Veri dönüştürme (UPDATE ... SET x = f(y)) → ters fonksiyon yoksa geri alınamaz"
note "  · NOT NULL ekleme → geri almak kolay, ama araya giren NULL'sız satırlar sorun olmaz"
note "  · CREATE INDEX CONCURRENTLY → geri almak kolay (DROP INDEX CONCURRENTLY)"
note "Grafana'da görünmez: şema sürümü hiçbir metrikte yok. 13 · Rollout → 'Hazır pod (sürüme göre)'"
note "uygulamanın sürümlerini gösterir, şemanınkini değil — ikisini bağlayan kayıt yok; sorunun kendisi bu."
note "Pratik kural: bir sürümde YALNIZCA geriye uyumlu şema değişikliği yap. Böylece uygulamayı"
note "geri almak şemayı geri almayı GEREKTİRMEZ — expand/contract'ın asıl sebebi budur."
note "Runbook'a yazılacak cümle: 'Uygulama geri alındığında şema İLERİ kalır ve bu SORUN DEĞİLDİR,"
note "çünkü N-1 sürümü N şemasıyla çalışabilir.' Bu cümleyi yazamıyorsan, migration'ın güvenli değil."
{ [[ -n "$dbver" ]] && (( nodown + destructive > 0 )); } \
  && reproduced "şema (v${dbver}) uygulamadan (${appimg:-?}) bağımsız ilerliyor ve $total migration'ın $destructive tanesinde geri alma VERİ KAYBETTİRİYOR ($nodown tanesinde Down bloğu yok) — uygulamayı geri almak şemayı geri almaz"
not_reproduced "bu depodaki $total migration'ın geri alınması veri kaybettirmiyor (Down blokları dolu ve yıkıcı değil) — iddia bu haliyle gösterilemiyor"
