-- +goose Up
-- P02-05'in çözümü: (tenant_id, created_at) indeksi. 02–04'te migrate Job'unun hedefi MIGRATE_TARGET=1'dir,
-- yani bu migration uygulanmaz ve sorun (seq scan, saniyelerce süren list) ölçülebilir; 05'ten itibaren
-- hedef daha yüksektir ve indeks hep vardır. 02–04'te dosyayla uygulamak için deploy/migrate-job.yaml'da
-- MIGRATE_TARGET'ı 2 yap, sonra: kubectl -n lvlNN delete job migrate && make deploy
-- (bir Job'un şablonu değiştirilemez; Job silinip yeniden oluşturulur). README'deki P02-05 rehberi aynı
-- indeksi dosyaya dokunmadan psql ile oluşturup siler.
--
-- EN: CONCURRENTLY is not cosmetic: a plain CREATE INDEX takes an ACCESS EXCLUSIVE lock and blocks
--     every write to the table for the duration. On a live table that is an outage. goose runs
--     migrations in a transaction by default, and CONCURRENTLY cannot run inside one — hence NO TRANSACTION.
-- TR: CONCURRENTLY kozmetik değil: düz CREATE INDEX tabloya ACCESS EXCLUSIVE kilidi koyar ve süre
--     boyunca her yazmayı bloklar. Canlı tabloda bu bir kesintidir. goose migration'ları varsayılan
--     olarak transaction içinde koşar, CONCURRENTLY ise transaction içinde çalışamaz — bu yüzden NO TRANSACTION.
-- [Topic · Konu: Online şema değişikliği, kilitler]
-- +goose NO TRANSACTION
CREATE INDEX CONCURRENTLY IF NOT EXISTS links_tenant_created_idx ON links (tenant, created_at DESC);

-- +goose Down
-- +goose NO TRANSACTION
DROP INDEX CONCURRENTLY IF EXISTS links_tenant_created_idx;
