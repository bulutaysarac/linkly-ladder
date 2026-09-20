-- +goose Up
-- processed_events'i GÜNE GÖRE partition'la ve eski günleri düşürülebilir yap.
--
-- EN: 06 added a dedup table that grows by one row per click, forever. Deleting old rows from a
--     huge table is expensive (dead tuples, vacuum, bloat) — but DROPPING a partition is a
--     metadata operation that takes milliseconds. This is the real reason to partition: not
--     query speed, but making DELETION cheap. Retention is a schema decision, not a cron job.
-- TR: 06, tıklama başına bir satır ekleyen ve sonsuza kadar büyüyen bir tekilleştirme tablosu
--     getirdi. Devasa bir tablodan eski satırları SİLMEK pahalıdır (ölü satır, vacuum, şişme) —
--     ama bir partition'ı DÜŞÜRMEK milisaniyeler süren bir metadata işlemidir. Partition'lamanın
--     asıl sebebi budur: sorgu hızı değil, SİLMEYİ ucuzlatmak. Saklama süresi bir şema kararıdır,
--     bir zamanlanmış iş değil.
-- [Topic · Konu: Partition, retention, vacuum]

-- +goose NO TRANSACTION
CREATE TABLE IF NOT EXISTS processed_events_p (
    event_id     TEXT        NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, processed_at)
) PARTITION BY RANGE (processed_at);

-- Bugün ve yarın için partition. Üretimde bunu pg_partman ya da bir operatör yapar;
-- burada elle yazmak, "partition'lar kendiliğinden oluşmaz" dersini görünür kılıyor.
-- +goose StatementBegin
DO $$
DECLARE d date;
BEGIN
  FOR d IN SELECT generate_series(CURRENT_DATE - 1, CURRENT_DATE + 7, '1 day')::date LOOP
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS processed_events_p_%s PARTITION OF processed_events_p
       FOR VALUES FROM (%L) TO (%L)',
      to_char(d, 'YYYYMMDD'), d, d + 1);
  END LOOP;
END $$;
-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS processed_events_p;
