-- +goose Up
-- Row Level Security: kiracı sınırını VERİTABANINA da öğret.
--
-- EN: Application-level tenant filters are correct until someone writes one query without the
--     WHERE clause — and that mistake produces NO ERROR AT ALL, just other people's data in a
--     response. RLS turns a forgotten filter from a silent data leak into an empty result set.
--     It is defence in depth in its purest form: the same rule expressed twice, in two systems
--     that fail independently.
--     Cost: every connection must SET app.tenant_id, and a connection pool in transaction mode
--     makes that harder (the setting must be per-transaction, not per-session — see the app code).
-- TR: Uygulama seviyesindeki kiracı filtreleri, biri WHERE'i unutana kadar doğrudur — ve o hata
--     HİÇBİR HATA ÜRETMEZ, yalnızca başkalarının verisini yanıta koyar. RLS, unutulmuş bir
--     filtreyi sessiz bir veri sızıntısından BOŞ BİR SONUÇ KÜMESİNE çevirir. En saf hâliyle
--     katmanlı savunma: aynı kural iki kez, birbirinden bağımsız arızalanan iki sistemde.
--     Bedeli: her bağlantı app.tenant_id ayarlamalı ve transaction modundaki bir havuz bunu
--     zorlaştırır (ayar oturum değil İŞLEM başına olmalı — uygulama koduna bak).
-- [Topic · Konu: RLS, katmanlı savunma, çok kiracılılık]
ALTER TABLE links ENABLE ROW LEVEL SECURITY;

-- Politika: yalnızca current_setting('app.tenant_id') ile eşleşen satırlar görünür.
-- current_setting'in ikinci argümanı true: ayar YOKSA hata verme, NULL dön (o zaman hiçbir
-- satır eşleşmez — güvenli varsayılan).
CREATE POLICY links_tenant_isolation ON links
    USING (tenant = current_setting('app.tenant_id', true));

-- Not: tablo sahibi RLS'i BYPASS eder. Uygulama, sahibi OLMAYAN bir rolle bağlanmalı —
-- aksi hâlde politika yazılmış ama hiç uygulanmamış olur. Bu, RLS'in en sık atlanan detayıdır.
-- FORCE, sahibe de uygulatır:
ALTER TABLE links FORCE ROW LEVEL SECURITY;

-- +goose Down
ALTER TABLE links NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS links_tenant_isolation ON links;
ALTER TABLE links DISABLE ROW LEVEL SECURITY;
