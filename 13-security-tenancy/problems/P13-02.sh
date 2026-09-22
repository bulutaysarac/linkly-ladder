#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-02 · Unutulan tenant filtresi SESSİZ bir sızıntıdır — RLS onu boş sonuca çevirir
# Uygulama seviyesindeki filtreler, biri WHERE'i unutana kadar doğrudur. O hata HİÇBİR HATA
# ÜRETMEZ: yalnızca başkalarının verisi yanıta girer. Katmanlı savunma tam da bunun içindir.
#
# NEDEN RLS VARSAYILAN OLARAK KAPALI (ve bu scriptin kendi tarihi):
# 007_rls.sql bir süre migration hedefinin İÇİNDEYDİ. Sonuç: seviye hiç açılamadı. Politika
# `tenant = current_setting('app.tenant_id')` diyor; uygulama bu değişkeni HİÇ ayarlamıyor ve
# PUBLIC yönlendirme yolunun kiracısı zaten yok — kısa kod herkes için çözülür. Yani her INSERT
# SQLSTATE 42501 ile reddedildi, her yazma 503 döndü ve smoke "link oluşturulamadı" dedi.
# Dersin kendisi bu: RLS ücretsiz bir onay kutusu değildir. Açmak, uygulamanın veritabanına
# HER İŞLEMDE kim olduğunu söylemesini gerektirir (SET LOCAL). Söylemiyorsa, sızıntıyı
# KESİNTİYE çevirirsin. Bu script ikisini de ölçüyor: neyi koruduğunu VE neye mal olduğunu.
ensure_healthy
prim=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary') || exit 2
psql() { kubectl -n "$NS" exec "$prim" -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>&1; }
on_cleanup "kubectl -n \"$NS\" exec $prim -c postgres -- psql -U postgres -d linkly -tAc \"ALTER TABLE links NO FORCE ROW LEVEL SECURITY; DROP POLICY IF EXISTS links_tenant_isolation ON links; ALTER TABLE links DISABLE ROW LEVEL SECURITY\" >/dev/null 2>&1 || true"

step "Başlangıç: iki kiracı için veri üret"
for t in acme globex; do
  for _ in 1 2 3; do
    curl -s -o /dev/null -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' \
      "${AUTH_HDR[@]}" -H "X-Tenant-ID: $t" -d '{"url":"https://example.com/rls"}'
  done
done
total=$(psql "SELECT count(*) FROM links")
note "links tablosunda toplam ${total:-?} satır"

step "UYGULAMA FİLTRESİ: 'WHERE tenant = ...' unutulursa ne olur?"
leak=$(psql "SELECT count(*) FROM links")           # filtresiz sorgu = unutulmuş WHERE
note "filtresiz sorgu → ${leak:-?} satır döndü. HATA YOK, LOG YOK, ALARM YOK."
note "Sızıntının tanımı bu: yanlış cevap, DOĞRU cevap gibi görünür."

step "RLS'i AÇ (007_rls.sql'in yaptığı şey)"
psql "ALTER TABLE links ENABLE ROW LEVEL SECURITY" >/dev/null
psql "CREATE POLICY links_tenant_isolation ON links USING (tenant = current_setting('app.tenant_id', true))" >/dev/null
psql "ALTER TABLE links FORCE ROW LEVEL SECURITY" >/dev/null
pol=$(psql "SELECT polname FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid WHERE c.relname='links'")
force=$(psql "SELECT relforcerowsecurity FROM pg_class WHERE relname='links'")
note "politika: ${pol:-YOK} · FORCE ROW LEVEL SECURITY: ${force:-?}"
note "FORCE olmadan tablo SAHİBİ politikayı ATLAR — politika yazılmış ama uygulanmamış olur."
note "(En sık atlanan detay: CNPG'de uygulama kullanıcısı çoğu tabloya sahiptir.)"

step "Aynı unutulmuş sorgu, bu kez RLS altında"
no_setting=$(psql "SELECT count(*) FROM links")
as_acme=$(psql "SET app.tenant_id = 'acme'; SELECT count(*) FROM links")
as_globex=$(psql "SET app.tenant_id = 'globex'; SELECT count(*) FROM links")
note "app.tenant_id ayarsız → ${no_setting:-?} satır (önce ${leak:-?} idi)"
note "tenant=acme → ${as_acme:-?} · tenant=globex → ${as_globex:-?}"
note "Aynı SQL, farklı sonuç: filtreyi uygulama unutsa bile veritabanı hatırlıyor."

step "BEDELİ ÖLÇ: uygulama kiracıyı bildirmiyorsa ne oluyor?"
codes=0; errs=0
for _ in 1 2 3; do
  st=$(curl -s -o /dev/null -w '%{http_code}' -XPOST "$BASE_URL/api/links" \
        -H 'Content-Type: application/json' "${AUTH_HDR[@]}" -d '{"url":"https://example.com/cost"}')
  [[ "$st" == 2* ]] && codes=$(( codes + 1 )) || errs=$(( errs + 1 ))
done
note "RLS açıkken uygulama yazması: $codes başarılı · $errs başarısız"
note "Uygulama app.tenant_id'yi AYARLAMIYOR, dolayısıyla INSERT politikayı geçemiyor (42501)."
note "Yani RLS'i uygulamanın işbirliği olmadan açmak, SESSİZ SIZINTIYI GÜRÜLTÜLÜ KESİNTİYE çevirir."
note "Doğru sıra: (1) uygulama her işlemde SET LOCAL app.tenant_id yapsın, (2) SONRA politikayı aç."
note "Ve PUBLIC yolları (kısa kod çözme) bunun DIŞINDA kalmalı: onların kiracısı yoktur —"
note "sınırı geçtiklerini AÇIKÇA ilan etmeleri gerekir (ayrı rol ya da app.tenant_id='*' gibi)."

step "RLS'i kapat (temizlik zaten kayıtlı, ama ölçümü burada bitir)"
psql "ALTER TABLE links NO FORCE ROW LEVEL SECURITY" >/dev/null
psql "DROP POLICY IF EXISTS links_tenant_isolation ON links" >/dev/null
psql "ALTER TABLE links DISABLE ROW LEVEL SECURITY" >/dev/null
back=$(psql "SELECT count(*) FROM links")
note "kapatıldıktan sonra filtresiz sorgu → ${back:-?} satır (sızıntı geri döndü)"

grafana_hint "14 · Security → '401/403' · 05 · Postgres"
note "RLS'in bedeli, transaction modundaki bir havuzda daha da artar: ayar İŞLEM BAŞINA yapılmalı"
note "(SET LOCAL), oturum başına değil — yoksa bir sonraki kiracı öncekinin ayarını devralır."
note "P09-03'teki aynı fizik: proxy, 'bağlantı'nın ne demek olduğunu değiştirir."
{ [[ "${no_setting:-1}" == "0" ]] && awk -v l="${leak:-0}" 'BEGIN{exit !(l>0)}'; } \
  && reproduced "unutulan filtre RLS'siz ${leak} satır sızdırdı, RLS ile ${no_setting} satır döndü — ama bedeli var: RLS açıkken uygulamanın $errs/3 yazması 42501 ile reddedildi"
not_reproduced "RLS farkı ölçülemedi (filtresiz=${leak:-?} · RLS ayarsız=${no_setting:-?} · politika=${pol:-YOK})"
