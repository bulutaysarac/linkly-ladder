#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-02 · Unutulan tenant filtresi SESSİZ bir sızıntıdır — RLS onu boş sonuca çevirir
# Uygulama seviyesindeki filtreler, biri WHERE'i unutana kadar doğrudur. O hata HİÇBİR HATA
# ÜRETMEZ: yalnızca başkalarının verisi yanıta girer. Katmanlı savunma tam da bunun içindir.
ensure_healthy
prim=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
psql() { kubectl -n "$NS" exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>&1; }
step "RLS etkin mi?"
rls=$(psql "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname='links'")
pol=$(psql "SELECT polname FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid WHERE c.relname='links'")
note "links tablosu → rowsecurity/force: ${rls:-?} · politika: ${pol:-YOK}"
step "Filtresiz sorgu: app.tenant_id AYARLI DEĞİLKEN ne dönüyor?"
no_setting=$(psql "SELECT count(*) FROM links")
note "app.tenant_id ayarsız → ${no_setting:-?} satır (RLS çalışıyorsa 0 olmalı)"
step "app.tenant_id ayarlıyken"
as_acme=$(psql "SET app.tenant_id = 'acme'; SELECT count(*) FROM links")
as_globex=$(psql "SET app.tenant_id = 'globex'; SELECT count(*) FROM links")
note "tenant=acme → ${as_acme:-?} satır · tenant=globex → ${as_globex:-?} satır"
note "Aynı SQL, farklı sonuç: filtreyi uygulama unutsa bile veritabanı hatırlıyor."
step "Tablo sahibi RLS'i atlar mı? (en sık atlanan detay)"
force=$(psql "SELECT relforcerowsecurity FROM pg_class WHERE relname='links'")
note "FORCE ROW LEVEL SECURITY: ${force:-?} (f ise SAHİP politikayı atlar — politika yazılmış ama uygulanmamış olur)"
grafana_hint "14 · Security → '401/403' · 05 · Postgres"
note "RLS'in bedeli: her BAĞLANTI app.tenant_id ayarlamak zorunda ve transaction modundaki bir"
note "havuzda bu AYAR İŞLEM BAŞINA yapılmalı (SET LOCAL), oturum başına değil — yoksa bir sonraki"
note "kiracı önceki kiracının ayarını devralır. Yani P09-03'teki aynı fizik: proxy, 'bağlantı'nın"
note "ne demek olduğunu değiştirir ve bağlantı durumuna dayanan her şeyi gözden geçirmen gerekir."
note "Uygulamada bu, her sorgudan önce SET LOCAL çağırmak demektir — ölçülebilir bir maliyet."
{ [[ "${no_setting:-1}" == "0" ]] || [[ -n "${pol:-}" ]]; } \
  && reproduced "RLS etkin (politika: ${pol:-?}); ayarsız sorgu ${no_setting:-?} satır dönüyor — unutulan filtre sızıntı değil boş sonuç üretir"
not_reproduced "RLS etkin değil (migration 008 uygulandı mı? MIGRATE_TARGET=8)"
