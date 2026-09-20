-- +goose Up
-- İdempotency: hangi olayın uygulandığını hatırla.
--
-- EN: At-least-once delivery means the same event WILL arrive twice — after a consumer crash, a
--     rebalance, or a failed commit. Without this table the click count silently inflates and you
--     cannot tell by looking at it. The dedup key is the producer-generated event_id, not the
--     offset: offsets change on retention expiry and mean nothing across topics.
--     Cost: one row per click for the retention window. That is the price of exactly-once-effect,
--     and level 06's README states it plainly rather than pretending exactly-once exists.
-- TR: En-az-bir-kez teslimat, aynı olayın MUTLAKA iki kez geleceği anlamına gelir — tüketici
--     çökmesi, yeniden dengeleme ya da başarısız commit sonrası. Bu tablo olmadan tıklama sayısı
--     sessizce şişer ve bakarak anlayamazsın. Tekilleştirme anahtarı, üreticinin ürettiği
--     event_id'dir, offset değil: offset'ler saklama süresi dolunca değişir ve topic'ler arasında
--     hiçbir şey ifade etmez.
--     Bedeli: saklama penceresi boyunca tıklama başına bir satır. "Tam bir kez etkisi"nin fiyatı
--     budur ve 06'nın README'si, tam-bir-kez varmış gibi yapmak yerine bunu açıkça söylüyor.
-- [Topic · Konu: İdempotency, en az bir kez]
CREATE TABLE IF NOT EXISTS processed_events (
    event_id     TEXT        PRIMARY KEY,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Temizlik için: eski kayıtlar saklama penceresinden sonra silinebilir.
CREATE INDEX IF NOT EXISTS processed_events_at_idx ON processed_events (processed_at);

-- +goose Down
DROP TABLE IF EXISTS processed_events;
