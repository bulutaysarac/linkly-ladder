#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P07-06 · TRAP_LIST_N_PLUS_ONE: tek isteğin maliyeti sonuç kümesiyle doğru orantılı olursa
# 100 link listeleyen bir istek, 1 sorgu yerine 101 sorgu yapıyor. Küçük veride fark edilmez;
# sayfa boyutunu 20'den 100'e çıkardığın gün beş katına çıkar. Servisleri AYIRMAK bu sorunu
# büyütür: eskiden 101 fonksiyon çağrısıydı, şimdi 101 AĞ çağrısı olabilir.
APP_SELECTOR="app.kubernetes.io/name=api"
BASE_API="$BASE_URL"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/api TRAP_LIST_N_PLUS_ONE-"
TEN=${TEN:-nplusone}
step "Bu kiracı için 100 link oluştur"
for i in $(seq 1 100); do
  curl -s -o /dev/null -XPOST "$BASE_API/api/links" -H 'Content-Type: application/json' \
    -H "X-Tenant-ID: $TEN" -d "{\"url\":\"https://example.com/n/$i\"}"
done
step "Varsayılan (tek sorgu): list süresi ve DB sorgu sayısı"
q0=$(promq "sum(db_queries_total{namespace=\"$NS\"})")
t_ok=$(curl -s -o /dev/null -w '%{time_total}' -H "X-Tenant-ID: $TEN" "$BASE_API/api/links")
sleep 12
q1=$(promq "sum(db_queries_total{namespace=\"$NS\"})")
d_ok=$(awk -v a="${q0%%.*}" -v b="${q1%%.*}" 'BEGIN{print b-a}')
note "varsayılan: ${t_ok}s · bu istek için DB sorgusu ≈ $d_ok"
step "Tuzağı aç: her link için AYRI stats sorgusu"
kubectl -n "$NS" set env deploy/api TRAP_LIST_N_PLUS_ONE=true >/dev/null
kubectl -n "$NS" rollout status deploy/api --timeout=180s >/dev/null
sleep 5
q2=$(promq "sum(db_queries_total{namespace=\"$NS\"})")
t_bad=$(curl -s -o /dev/null -w '%{time_total}' -H "X-Tenant-ID: $TEN" "$BASE_API/api/links")
sleep 12
q3=$(promq "sum(db_queries_total{namespace=\"$NS\"})")
d_bad=$(awk -v a="${q2%%.*}" -v b="${q3%%.*}" 'BEGIN{print b-a}')
grafana_hint "05 · Postgres → 'DB queries by op' (op=stats patlaması) · 02 · App RED → p99 (/api/links)"
note "N+1 açık: ${t_bad}s · bu istek için DB sorgusu ≈ $d_bad"
note "Maliyet sonuç kümesiyle DOĞRU ORANTILI: 100 link → ~100 ek sorgu. Sayfa boyutu bir ayar"
note "değil, bir MALİYET ÇARPANI hâline geldi."
note "Doğrusu: tek toplu sorgu (WHERE code = ANY($1)) ya da tek JOIN. 'Kolay' olan döngüdür;"
note "ucuz olan toplu sorgudur ve aradaki fark ölçekte ortaya çıkar."
note "Servis ayrımı bunu KÖTÜLEŞTİRİR: 101 fonksiyon çağrısı 101 ağ çağrısına dönebilir → 14'te gRPC + batch."
awk -v a="$t_ok" -v b="$t_bad" 'BEGIN{exit !(b > a*1.5)}' \
  && reproduced "N+1 list süresini ${t_ok}s → ${t_bad}s yaptı (DB sorgusu $d_ok → $d_bad)"
not_reproduced "N+1 etkisi ölçülemedi (link sayısını artırıp tekrar dene)"
