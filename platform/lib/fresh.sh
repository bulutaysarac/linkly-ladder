#!/usr/bin/env bash
# Grafana'yı temiz sayfaya döndür: bütün seviyelerin (lvl*) ve k6'nın metriklerini Prometheus'tan sil.
#
#   make fresh        bir deneyi temiz grafikle başlatmak için (seviye README'lerindeki her deneyin ilk adımı)
#   make up           bunu kendisi çağırır: her seviye boş bir Grafana ile başlar
#
# Silinen yalnızca GEÇMİŞ çizgilerdir. Kurulum, pod'lar ve uygulama verisi (veritabanı, önbellek) yerinde
# kalır; çalışan pod'ların yeni örnekleri 10-30 sn içinde yeniden görünür, rate() kullanan paneller iki
# örnek biriktikten sonra (~1 dk) dolar. Silme Prometheus'un admin API'siyle yapılır
# (kube-prometheus-stack.values.yaml → enableAdminAPI): saniyeler sürer, Prometheus yeniden başlamaz.
# Aynı anda tek seviye çalıştığı için bütün lvl* serileri birlikte silinir; önceki seviyenin çizgileri
# yeni seviyeninkine karışmaz.
#
# SOFT=1 (make up): Prometheus'a ulaşılamazsa uyarır ve devam eder — seviyeyi kurmak, grafiği temizlemekten
# önemlidir. Elle `make fresh` ise hata verir: temizlenmemiş bir grafiği temiz sanmak yanıltır.
# [Topic · Konu: Deney araçları]
set -uo pipefail
PROM_URL=${PROM_URL:-http://prometheus.localtest.me}

code=$(curl -sS -o /tmp/ladder-fresh.out -w '%{http_code}' --max-time 30 -X POST \
  "$PROM_URL/api/v1/admin/tsdb/delete_series" \
  --data-urlencode 'match[]={namespace=~"lvl[0-9]+"}' \
  --data-urlencode 'match[]={exported_namespace=~"lvl[0-9]+"}' \
  --data-urlencode 'match[]={dest_namespace=~"lvl[0-9]+"}' \
  --data-urlencode 'match[]={level=~"lvl[0-9]+"}' 2>/dev/null)

if [[ "$code" == 204 ]]; then
  echo "✔ Grafana temiz: seviyelerin ve k6'nın geçmiş metrikleri silindi (yeni veri 10-30 sn içinde gelir)"
  exit 0
fi
msg="✘ Prometheus metrikleri silinemedi (HTTP ${code:-yok}): $(head -c 200 /tmp/ladder-fresh.out 2>/dev/null)"
if [[ "$code" == 403 || "$code" == 404 ]] || grep -qi 'admin' /tmp/ladder-fresh.out 2>/dev/null; then
  msg+=$'\n  admin API kapalı: make -C platform obs (kube-prometheus-stack.values.yaml → enableAdminAPI: true)'
fi
if [[ "${SOFT:-0}" == 1 ]]; then echo "${msg/✘/!} — kuruluma devam" >&2; exit 0; fi
echo "$msg" >&2
exit 1
