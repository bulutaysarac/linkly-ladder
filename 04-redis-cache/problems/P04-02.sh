#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-02 · Paylaşılan önbelleğin bedeli: sıcak yolda bir ağ gidiş-gelişi
# 03'te önbellek isabeti bir map aramasıydı (~1 µs). 04'te bir ağ çağrısı (yüzlerce µs).
# Tutarlılığı kazandık, gecikmeyi ödedik. Ölçmeden "daha iyi" demek mühendislik değil temennidir.
#
# ÖLÇÜM NOTU — uçtan uca p50 hükmü 03'ü de "reproduce" eder.
# "Uçtan uca redirect p50'si 0.5 ms'yi geçiyor mu?" sorusunun iki sorunu var: (1) HTTP
# histogramının en küçük kovası 1 ms — milisaniyenin altındaki bir fark o kovadan okunamaz;
# (2) 03'te de 04'te de her tıklama DB'ye bir UPDATE atıyor (P02-08), yani p50 iki seviyede de
# 0.5 ms'nin üstünde. Bu ölçü, iddia yanlışken de (isabet bellekten gelseydi de) aynı sonucu verir.
# Bu yüzden iddianın KENDİSİ ölçülüyor: önbelleğe sormanın süresi, katman başına, 1 µs'den başlayan
# kovalarla (cache_lookup_duration_seconds{layer}). 03 aynı histogramı l1 için yayınlıyor; yani
# karşılaştırma aynı aletle yapılıyor. İki şart birlikte: aramaların (neredeyse) hepsi ağ katmanına
# (l2) gidiyor VE o aramanın p50'si bellek içi bir aramanın on katından fazla.
# EN: an end-to-end verdict (p50 > 0.5 ms) also passes at level 03: the HTTP histogram's
#     smallest bucket is 1 ms and every click still does a DB UPDATE at both levels. So the claim
#     itself is measured: the cost of asking the cache, per layer, with buckets from 1 µs.
# Eşik: 50 µs. Bellek içi bir arama (mutex + map) birkaç µs'nin altında kalır; aynı makinedeki en
# kısa TCP gidiş-gelişi bile (syscall + veth + Redis olay döngüsü) onlarca-yüzlerce µs'dir.
# 50 µs, birincinin on katından fazla, ikincinin altında.
ensure_healthy
need_metric cache_lookup_duration_seconds_bucket "önbellek arama histogramı — küme eski imajı koşuyor olabilir: make up"
step "Önbelleği ısıt, sonra sabit yük altında önbelleğe sormanın bedelini ölç"
k6run redirect --vus 20 --duration 30s >/dev/null 2>&1 || true
k6run redirect --vus 20 --duration 45s || true
sleep 12
# need_metric HERHANGİ bir namespace'te bulunca geçer; bu seviyenin pod'ları yayınlamıyorsa (eski imaj)
# aşağıdaki sorgular 0 döner ve hüküm "ağa gitmiyor" olurdu. Yoksa ölçüm yoktur, hüküm de yoktur.
if prom_absent "cache_lookup_duration_seconds_count{namespace=\"$NS\"}"; then
  warn "$NS pod'ları cache_lookup_duration_seconds yayınlamıyor — imaj eski olabilir: make up"; exit 2
fi
l2p50=$(promq "histogram_quantile(0.50, sum(rate(cache_lookup_duration_seconds_bucket{namespace=\"$NS\",layer=\"l2\"}[1m])) by (le))")
l2p99=$(promq "histogram_quantile(0.99, sum(rate(cache_lookup_duration_seconds_bucket{namespace=\"$NS\",layer=\"l2\"}[1m])) by (le))")
# Aramaların ne kadarı ağ katmanına gidiyor? 04'te hepsi (yalnız l2 var); 14'te sıcak anahtarlar L1'de biter.
share=$(promq "sum(rate(cache_lookup_duration_seconds_count{namespace=\"$NS\",layer=\"l2\"}[1m])) / sum(rate(cache_lookup_duration_seconds_count{namespace=\"$NS\"}[1m]))")
# Aynı aletle 03: Prometheus'ta 03'ün bir koşusu duruyorsa (saklama ~6 sa) L1'in p50'si.
l1p50=$(promq "histogram_quantile(0.50, sum(increase(cache_lookup_duration_seconds_bucket{namespace=\"lvl03\",layer=\"l1\"}[6h])) by (le))")
p50=$(promq "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\",result=\"hit\"}[1m])) / sum(rate(cache_ops_total{namespace=\"$NS\",layer=\"l2\"}[1m]))")
grafana_hint "06 · Redis → 'Komut / sn' · 04 · Cache → 'İsabet oranı (toplam)' · Explore → cache_lookup_duration_seconds"
us() { awk -v v="$1" 'BEGIN{printf "%.0f", v * 1e6}'; }
note "önbelleğe sorma (l2 = Redis GET): p50=$(us "$l2p50") µs · p99=$(us "$l2p99") µs · aramaların %$(awk -v v="$share" 'BEGIN{printf "%.0f", v*100}')'i ağ katmanında · isabet %$(awk -v v="$hit" 'BEGIN{printf "%.0f", v*100}')"
if awk -v v="$l1p50" 'BEGIN{exit !(v > 0)}'; then
  note "aynı alet, 03 (l1 = pod içi map, son 6 sa): p50=$(awk -v v="$l1p50" 'BEGIN{printf "%.1f", v*1e6}') µs → her isabet ~$(awk -v a="$l2p50" -v b="$l1p50" 'BEGIN{printf "%.0f", (b > 0 ? a / b : 0)}') kat pahalı"
else
  note "03'ün koşusu Prometheus'ta yok — yan yana görmek için 03'te 'make load S=redirect' koş (bkz. README)"
fi
note "uçtan uca redirect p50=$(awk -v v="$p50" 'BEGIN{printf "%.2f", v*1000}') ms — hüküm bundan çıkmaz: en küçük kova 1 ms ve her tıklama hâlâ bir DB UPDATE"
note "14'te L1+L2: en sıcak anahtarlar pod belleğinde, gerisi Redis'te — iki dünyanın iyi yanı,"
note "karşılığında yine bir geçersiz kılma kanalı borcu (pub/sub)."
awk -v s="$share" -v v="$l2p50" 'BEGIN{exit !(s >= 0.9 && v >= 0.00005)}' \
  && reproduced "her önbellek isabeti bir ağ gidiş-gelişi: Redis araması p50=$(us "$l2p50") µs (bellek içi arama birkaç µs), aramaların %$(awk -v v="$share" 'BEGIN{printf "%.0f", v*100}')'i ağda"
not_reproduced "önbellek aramaların yalnız %$(awk -v v="$share" 'BEGIN{printf "%.0f", v*100}')'i ağa gidiyor (l2 p50=$(us "$l2p50") µs) — sıcak yol bellekte (L1, 14)"
