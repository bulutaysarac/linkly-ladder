#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-06 · Kardinalite, üçüncü kez: bu kez tenant label'ı
# P01-06'da kısa kodu label yapmıştık. Aynı hata, daha makul görünen bir kılıkta: "tenant'a göre
# ayırmak istiyoruz". 10 tenant'ta zararsız, 10 bin tenant'ta Prometheus'u dizlerinin üstüne
# çöktürür. Kardinalite, bir label'ın DEĞER SAYISI kadar büyür ve bu sayı genelde İŞ BÜYÜDÜKÇE artar.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_TENANT_LABEL-"
N=${N:-500}
before=$(promq 'prometheus_tsdb_head_series')
note "Prometheus toplam seri (öncesi): ${before%%.*}"
step "TRAP_TENANT_LABEL aç ve $N farklı kiracıdan istek gönder"
setenv "$(wl redirect)" TRAP_TENANT_LABEL=true >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
code=$(create_link "https://example.com/card")
for i in $(seq 1 "$N"); do
  curl -s -o /dev/null -H "X-Tenant-ID: tenant-$i" "$BASE_URL/$code"
done
sleep 20
after=$(promq 'prometheus_tsdb_head_series')
tenants=$(promq "count(count by (tenant) (http_requests_total{namespace=\"$NS\"}))")
qtime=$(promq 'histogram_quantile(0.99, sum(rate(prometheus_engine_query_duration_seconds_bucket[5m])) by (le)) or vector(0)')
mem=$(promq 'sum(container_memory_working_set_bytes{namespace="monitoring",pod=~"prometheus-.*",image!="",image!~".*pause.*"})')
grafana_hint "02 · App RED → seri sayısı · Prometheus kendi metrikleri (prometheus_tsdb_head_series)"
note "farklı tenant label değeri: ${tenants%%.*} · toplam seri: ${before%%.*} → ${after%%.*} (+$(( ${after%%.*} - ${before%%.*} )))"
note "Prometheus sorgu p99=$(awk -v v="$qtime" 'BEGIN{printf "%.0f", v*1000}') ms · bellek=$(( ${mem%%.*} / 1024 / 1024 )) MB"
step "Tuzağı kapat"
setenv "$(wl redirect)" TRAP_TENANT_LABEL- >/dev/null
note "Kural (üçüncü tekrar): label'lar SINIRLI ve ÖNGÖRÜLEBİLİR kümelerden olmalı."
note "'Tenant'a göre görmek istiyorum' meşru bir istektir; cevabı metrik DEĞİLDİR:"
note "  · en çok trafik üreten 10 tenant → log toplama (Loki) ya da ayrı bir analitik sorgusu"
note "  · tek bir tenant'ın tek bir yavaş isteği → EXEMPLAR + trace (kardinalite ödemeden)"
note "  · faturalama → veritabanı, metrik değil"
note "Metrikler ZAMAN SERİSİDİR; her yeni label değeri kalıcı bir bellek maliyetidir."
# ÖLÇÜ SEÇİMİ: karar, Prometheus'un TOPLAM seri sayısına bakıyordu. O sayı yoğun bir kümede
# kendi başına oynar (yeni pod, yeni chaos kaynağı, yeni scrape hedefi) — yani tuzak KODDA HİÇ
# OKUNMAZKEN bile "REPRODUCED" çıkıyordu. Ölçü, tuzağın ÜRETTİĞİ ŞEY olmalı: tenant label'ının
# kaç farklı değer aldığı. Toplam seri artışı bunun sonucudur, kanıtı değil.
awk -v t="${tenants%%.*}" 'BEGIN{exit !(t > 1)}' \
  && reproduced "tenant label'ı ${tenants%%.*} farklı değer aldı → toplam seri ${before%%.*} → ${after%%.*} (+$(( ${after%%.*} - ${before%%.*} )))"
not_reproduced "tenant label'ı üretilmedi (${tenants%%.*} değer) — TRAP_TENANT_LABEL kodda okunuyor mu?"
