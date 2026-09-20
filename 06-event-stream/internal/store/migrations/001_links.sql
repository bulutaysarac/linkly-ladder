-- +goose Up
-- EN: The short code is the primary key. Not an auto-increment id with a unique index on the code:
--     the code IS the identity, every read is by code, and a surrogate key would add a second index
--     to keep in sync for no benefit. PRIMARY KEY also gives us the conditional insert for free.
-- TR: Kısa kod birincil anahtar. Otomatik artan bir id + kod üzerinde unique index DEĞİL: kimlik
--     zaten kod, her okuma kodla yapılıyor ve vekil anahtar hiçbir fayda sağlamadan senkron
--     tutulacak ikinci bir index getirirdi. PRIMARY KEY koşullu eklemeyi de bedavaya veriyor.
-- [Topic · Konu: Anahtar seçimi]
CREATE TABLE IF NOT EXISTS links (
    code       TEXT        PRIMARY KEY,
    url        TEXT        NOT NULL,
    tenant     TEXT        NOT NULL DEFAULT 'default',
    clicks     BIGINT      NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- BİLEREK EKSİK: tenant üzerinde index yok. ListByTenant bu yüzden tüm tabloyu tarayacak (P02-05).
-- 1 milyon satırda bunun ne demek olduğunu ölçüp sonra 002 ile ekleyeceğiz — "index unutmak"
-- üretimde tam olarak böyle görünür: küçük veride fark edilmez, büyük veride olay olur.

-- +goose Down
DROP TABLE IF EXISTS links;
