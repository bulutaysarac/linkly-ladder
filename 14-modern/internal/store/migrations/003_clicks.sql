-- +goose Up
-- Tıklamaları ayrı bir tabloya taşı ve links.clicks'i emekliye ayır.
--
-- EN: Two tables, two jobs. `clicks_daily` is an aggregate the writer upserts in batches — one row
--     per (code, day) instead of one row version per click, which is what made P02-08 hurt. The
--     `clicks` detail table is deliberately NOT here: storing every click individually is a
--     different product decision (and a partitioning problem, level 09). Aggregate first, keep
--     detail only when someone can name the question it answers.
-- TR: İki tablo, iki iş. `clicks_daily`, yazıcının toplu olarak upsert ettiği bir toplam — tıklama
--     başına bir satır sürümü yerine (code, gün) başına bir satır; P02-08'i acıtan şey tam olarak
--     oydu. Ayrıntı tablosu (`clicks`) BİLEREK yok: her tıklamayı tek tek saklamak başka bir ürün
--     kararıdır (ve bir partition sorunudur, 09). Önce topla; ayrıntıyı ancak birileri cevapladığı
--     soruyu adlandırabiliyorsa sakla.
-- [Topic · Konu: Toplama tablosu, yazma amplifikasyonu]
CREATE TABLE IF NOT EXISTS clicks_daily (
    code  TEXT   NOT NULL,
    day   DATE   NOT NULL,
    count BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (code, day)
);

CREATE INDEX IF NOT EXISTS clicks_daily_code_idx ON clicks_daily (code);

-- +goose Down
DROP TABLE IF EXISTS clicks_daily;
