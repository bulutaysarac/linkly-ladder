-- +goose Up
-- EXPAND aşaması: yeni sütunu EKLE, eskiyi bırak.
--
-- EN: The rule that makes zero-downtime schema change possible: during a rolling update, OLD and
--     NEW code run at the same time against the SAME schema. Therefore every migration must be
--     compatible with the code on BOTH sides of the deploy. Renaming a column in one step breaks
--     this rule instantly — the old pods query a column that no longer exists (P12-02).
--
--     The safe shape is three deploys, not one:
--       1. EXPAND   — add the new column, write to BOTH (this file + app change)
--       2. MIGRATE  — backfill, switch reads to the new column
--       3. CONTRACT — stop writing the old column, then drop it (a LATER release)
--     Each step is independently reversible. That is the whole point: a schema change you cannot
--     roll back is a deploy you cannot roll back.
-- TR: Sıfır kesintili şema değişikliğini mümkün kılan kural: rolling update sırasında ESKİ ve
--     YENİ kod AYNI şemaya karşı aynı anda çalışır. Dolayısıyla her migration, dağıtımın HER İKİ
--     yanındaki kodla uyumlu olmak zorundadır. Bir sütunu tek adımda yeniden adlandırmak bu kuralı
--     anında çiğner — eski pod'lar artık var olmayan bir sütunu sorgular (P12-02).
--
--     Güvenli biçim tek değil ÜÇ dağıtımdır:
--       1. EXPAND   — yeni sütunu ekle, HER İKİSİNE de yaz (bu dosya + uygulama değişikliği)
--       2. MIGRATE  — geriye doldur, okumaları yeni sütuna çevir
--       3. CONTRACT — eskiye yazmayı bırak, sonra sütunu düşür (SONRAKİ bir sürümde)
--     Her adım bağımsız olarak geri alınabilir. Bütün mesele bu: geri alamadığın bir şema
--     değişikliği, geri alamadığın bir dağıtımdır.
-- [Topic · Konu: Expand/contract, sıfır kesintili şema değişikliği]
ALTER TABLE links ADD COLUMN IF NOT EXISTS target_url TEXT;

-- Geriye doldurma: küçük tabloda tek seferde; büyük tabloda PARTİ PARTİ yapılmalı
-- (tek UPDATE milyonlarca satırı kilitler ve WAL'i şişirir).
UPDATE links SET target_url = url WHERE target_url IS NULL;

-- +goose Down
ALTER TABLE links DROP COLUMN IF EXISTS target_url;
