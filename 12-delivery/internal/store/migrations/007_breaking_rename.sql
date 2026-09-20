-- +goose Up
-- KIRICI migration — YALNIZCA P12-02 deneyinde uygulanır (MIGRATE_TARGET=7).
--
-- EN: This is what everyone writes the first time: one clean statement that renames the column.
--     It is also a guaranteed outage during a rolling update: for the seconds or minutes while
--     old and new pods coexist, the old ones SELECT a column that no longer exists. Postgres is
--     not the problem here — the deployment model is. Ship this on purpose once, watch the 500s,
--     and the expand/contract discipline stops feeling like bureaucracy.
-- TR: Bu, herkesin ilk seferinde yazdığı şeydir: sütunu yeniden adlandıran tek, temiz bir ifade.
--     Aynı zamanda rolling update sırasında GARANTİ bir kesintidir: eski ve yeni pod'lar bir arada
--     yaşadığı saniyeler ya da dakikalar boyunca eskiler artık var olmayan bir sütunu SELECT eder.
--     Buradaki sorun Postgres değil, DAĞITIM MODELİDİR. Bunu bilerek bir kez dağıt, 500'leri gör;
--     expand/contract disiplini o andan sonra bürokrasi gibi gelmez.
-- [Topic · Konu: Kırıcı şema değişikliği]
ALTER TABLE links RENAME COLUMN url TO url_old;

-- +goose Down
ALTER TABLE links RENAME COLUMN url_old TO url;
