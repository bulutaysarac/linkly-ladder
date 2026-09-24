#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-06 · TRAP_LIST_N_PLUS_ONE: tek isteğin maliyeti sonuç kümesiyle doğru orantılı olursa
# 100 link listeleyen bir istek, 1 sorgu yerine 101 sorgu yapıyor. Küçük veride fark edilmez;
# sayfa boyutunu 20'den 100'e çıkardığın gün beş katına çıkar. Servisleri AYIRMAK bu sorunu
# büyütür: tek süreçte 101 fonksiyon çağrısı olan şey, servisler arasında 101 AĞ çağrısı olabilir.
APP_SELECTOR="app.kubernetes.io/name=api"
BASE_API="$BASE_URL"
ensure_healthy
on_cleanup "setenv "$(wl api)" TRAP_LIST_N_PLUS_ONE-"
TEN=${TEN:-nplusone}
step "Bu kiracı için 100 link oluştur"
for i in $(seq 1 100); do
  curl -s -o /dev/null -XPOST "$BASE_API/api/links" -H 'Content-Type: application/json' \
    -H "X-Tenant-ID: $TEN" -d "{\"url\":\"https://example.com/n/$i\"}"
done
# Sayaç deltasını YALNIZCA api pod'larından al ve negatifi 0'a kırp: bu deneyde arada bir
# rollout var (TRAP env'i) ve ölen pod'un sayacı toplamdan düşünce fark NEGATİF çıkabilir.
# Ölçtüğün şey bir SAYAÇ ise, seri kaybının farkı bozduğunu unutma.
dbq() { promq "sum(db_queries_total{namespace=\"$NS\",pod=~\"api-.*\"})"; }
delta() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{d=b-a; print (d<0 ? 0 : int(d))}'; }
# Ölçüm penceresi kuralı ve gerekçesi paylaşılan kütüphanede: platform/lib/repro.sh → settle_scrape
# (kuralı çiğneyen bir ölçüm, kazıma gecikmesi yüzünden sayaç farkını yanlış okur; oradaki yoruma bak).
# ISINDIRMA ŞART: ilk /api/links isteği havuzu açar ve ~1 sn sürer; ısınmış bir N+1 koşusu ise
# ~0.1 sn — ısıtmadan ölçmek "N+1 daha HIZLI" gibi saçma bir sonuç üretir. İlk isteğin maliyeti
# ölçtüğün şeyin değil, ÖLÇÜME BAŞLAMANIN maliyetidir.
curl -s -o /dev/null -H "X-Tenant-ID: $TEN" "$BASE_API/api/links" || true
curl -s -o /dev/null -H "X-Tenant-ID: $TEN" "$BASE_API/api/links" || true
step "Varsayılan (tek sorgu): list süresi ve DB sorgu sayısı"
settle_scrape                      # oluşturma trafiği sayaca işlensin
q0=$(dbq)
t_ok=$(curl -s -o /dev/null -w '%{time_total}' -H "X-Tenant-ID: $TEN" "$BASE_API/api/links")
settle_scrape
q1=$(dbq)
d_ok=$(delta "${q0%%.*}" "${q1%%.*}")
note "varsayılan: ${t_ok}s · bu istek için DB sorgusu ≈ $d_ok"
step "Tuzağı aç: her link için AYRI stats sorgusu"
setenv "$(wl api)" TRAP_LIST_N_PLUS_ONE=true >/dev/null
kubectl -n "$NS" rollout status "$(wl api)" --timeout=180s >/dev/null || true
sleep 5
curl -s -o /dev/null -H "X-Tenant-ID: $TEN" "$BASE_API/api/links" || true   # yeni pod da soğuk
curl -s -o /dev/null -H "X-Tenant-ID: $TEN" "$BASE_API/api/links" || true
settle_scrape                      # ölen pod'un serisi toplamdan düşsün, yenisi kazınsın
q2=$(dbq)
t_bad=$(curl -s -o /dev/null -w '%{time_total}' -H "X-Tenant-ID: $TEN" "$BASE_API/api/links")
settle_scrape
q3=$(dbq)
d_bad=$(delta "${q2%%.*}" "${q3%%.*}")
grafana_hint "05 · Postgres → 'Veritabanı sorguları (türe göre)' (op=stats patlaması) · 02 · App RED → 'p99 süre (uç noktaya göre)' (/api/links)"
note "N+1 açık: ${t_bad}s · bu istek için DB sorgusu ≈ $d_bad"
note "Maliyet sonuç kümesiyle DOĞRU ORANTILI: 100 link → ~100 ek sorgu. Sayfa boyutu bir ayar"
note "değil, bir MALİYET ÇARPANI hâline geldi."
# DİKKAT: `$1` çift tırnak içinde kabuğun KONUMSAL PARAMETRESİdir; `set -u` altında script
# "unbound variable" ile ölür — ölçüm biter ama karar satırına varılamaz. Bu yüzden tek tırnak.
note 'Doğrusu: tek toplu sorgu (WHERE code = ANY($1)) ya da tek JOIN. "Kolay" olan döngüdür;'
note "ucuz olan toplu sorgudur ve aradaki fark ölçekte ortaya çıkar."
note "Servis ayrımı bunu KÖTÜLEŞTİRİR: 101 fonksiyon çağrısı 101 ağ çağrısına dönebilir → 14'te gRPC + batch."
# ASIL ÖLÇÜ SORGU SAYISIDIR, SÜRE DEĞİL. İddia "maliyet sonuç kümesiyle doğru orantılı";
# bunun ölçüsü 100 link için ~100 EK SORGU'dur. Süre bu kümede iki koşu arasında zaten oynar ve
# tek başına dayanak yapılırsa, sorgu sayısı KENDİ İDDİASINI ÇÜRÜTÜRKEN bile hüküm geçebilir.
# Süre yine raporlanıyor, ama karar sayıya bakıyor.
# EN: the real measure is the query COUNT, not the duration. Duration varies run to run on this
# cluster, and when it alone decides, the verdict can pass while the query count REFUTES it.
# Duration is still reported; the decision reads the count.
awk -v qa="$d_ok" -v qb="$d_bad" 'BEGIN{exit !(qa > 0 && qb > qa * 2)}' \
  && reproduced "N+1 bu istek için DB sorgusunu $d_ok → $d_bad yaptı (list süresi ${t_ok}s → ${t_bad}s)"
not_reproduced "N+1 etkisi ölçülemedi (sorgu sayısı $d_ok → $d_bad; link sayısını artır ya da SCRAPE_SETTLE'i büyüt)"
