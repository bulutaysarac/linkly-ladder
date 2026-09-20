-- +goose Up
-- P02-05'in çözümü. ÖNCE sorunu ölç (seq scan, saniyelerce süren list), SONRA bunu uygula:
--   kubectl -n lvl02 set env deploy/linkly MIGRATE_TARGET=2 && kubectl -n lvl02 rollout restart deploy/linkly
-- Varsayılan MIGRATE_TARGET=1 — yani bu migration normalde UYGULANMAZ.
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
