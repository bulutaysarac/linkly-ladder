#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-03 · Sıcak anahtar: tek bir link, tek bir Redis çekirdeği
# Redis TEK İŞ PARÇACIKLIDIR. Trafiğin %95'i tek anahtara giderse, o anahtarı hangi sunucuya
# koyarsan koy tek bir çekirdeğin sınırına dayanırsın. Ölçeklenemeyen şey anahtar değil, ERİŞİMDİR.
#
# ÖLÇÜM NOTU — neden "Redis CPU'su arttı mı?" diye BAKMIYORUZ:
# Dağıtık yük ile sıcak yükün Redis CPU'sunu kıyaslamak işe yaramaz: ikisi de AYNI sayıda komut
# üretir; CPU da doğal olarak aynı çıkar ve hüküm "sorun yok" olur. Oysa sorun CPU'nun artması
# değil, TAVANIN YERİ: tek anahtarın tavanı tek instance'ın tavanıdır ve sharding onu yükseltmez.
# Bu yüzden tavanı DOĞRUDAN ölçüyoruz (redis-benchmark) ve uygulamanın ona ne kadar yaklaştığını
# gösteriyoruz. Ölçemediğin bir sınırı, sınırın KENDİSİNİ ölçerek göster.
ensure_healthy
rpod=$(dep_pod app.kubernetes.io/name=redis) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
# redis-benchmark'ın ÇIKTISI bir metin değil, bir EKRANDIR: ilerleme satırlarını \r ile üstüne
# yazar ve `-q` bunu susturmuyor. `tr -d '\r'` hepsini TEK satıra yapıştırınca alan numarası da,
# "ilk sayı" da anlamsızlaşıyor (sonuç "tavanın %1126716'sı" gibi saçma bir satır olur).
# Doğrusu: \r'yi SATIR SONUNA çevir, "N requests per second" kalıbının SONUNCUSUNU al.
# Ders: bir aracın çıktısını ayrıştırırken, o çıktının insan için mi makine için mi yazıldığını sor.
bench() {
  local out
  out=$(kubectl -n "$NS" exec "$rpod" -c redis -- redis-benchmark -q -t get -n "${2:-100000}" -c 50 -r "$1" 2>/dev/null | tr '\r' '\n') || true
  { printf '%s\n' "$out" | grep -oE '[0-9]+(\.[0-9]+)? requests per second' | tail -1 | cut -d' ' -f1 | cut -d. -f1; } || true
}
step "Tavanı DOĞRUDAN ölç: 100k anahtara dağıtılmış GET vs TEK anahtara GET (ağ dışı, pod içinde)"
spread_ceiling=$(bench 100000)
single_ceiling=$(bench 0)
if [[ -z "${spread_ceiling:-}" || -z "${single_ceiling:-}" ]]; then
  warn "redis-benchmark çıktısı ayrıştırılamadı — ham çıktı:"
  kubectl -n "$NS" exec "$rpod" -c redis -- redis-benchmark -q -t get -n 1000 -c 10 -r 0 2>&1 | head -3 | sed 's/^/    /' || true
  exit 2
fi
note "dağıtık GET tavanı: ${spread_ceiling:-?} ops/s"
note "TEK anahtar GET tavanı: ${single_ceiling:-?} ops/s"
note "İkisi birbirine yakınsa mesaj şudur: sınır ANAHTARDA değil, INSTANCE'ta. Yani sharding"
note "(anahtarları dağıtmak) sıcak anahtarı kurtarmaz — o anahtar yine tek bir shard'da kalır."
step "Uygulama tarafı: aynı yükün %95'i tek anahtara"
HOT_SHARE=0.95 k6run hot-key --vus 60 --duration 40s >/dev/null 2>&1 || true
sleep 12
hot_ops=$(promq "max_over_time(sum(rate(redis_commands_processed_total{namespace=\"$NS\"}[30s]))[3m:15s])")
hot_cpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redis.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[3m:15s])")
hot_p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[1m])) by (le))")
grafana_hint "06 · Redis → 'Redis CPU' + 'ops/s' · 02 · App RED → 'p99 by route'"
note "uygulamanın ürettiği: $(awk -v v="$hot_ops" 'BEGIN{printf "%.0f", v}') ops/s · Redis CPU=$(awk -v v="$hot_cpu" 'BEGIN{printf "%.2f", v}') çekirdek · redirect p99=$(awk -v v="$hot_p99" 'BEGIN{printf "%.0f", v*1000}') ms"
note "tavanın $(awk -v a="$hot_ops" -v b="${single_ceiling:-1}" 'BEGIN{printf "%%%.1f", (b>0? a*100/b : 0)}')'i kullanılıyor — bu kümede tavana ÇARPMIYORUZ."
note "Bu dürüst bir sonuçtur: sorun 'şu an yavaşız' değil, 'büyüyünce ÇARE YOK'. Tavanı bilmek,"
note "ona çarpmadan önce karar vermeni sağlar — kapasite planlaması tam olarak budur."
note "Gerçek çözümler: (a) anahtarı çoğalt (key:1..N, rastgele oku) — tutarlılık maliyeti,"
note "                 (b) pod içinde L1 tut (14) — en sıcak anahtar hiç ağa çıkmaz,"
note "                 (c) CDN/edge — en popüler linkler uygulamaya hiç ulaşmaz."
awk -v s="${single_ceiling:-0}" -v d="${spread_ceiling:-0}" 'BEGIN{exit !(s > 0 && d > 0 && s < d*1.3 && s > d*0.7)}' \
  && reproduced "tek anahtar tavanı ${single_ceiling} ops/s ≈ dağıtık tavan ${spread_ceiling} ops/s — sınır instance'ta, sharding sıcak anahtarı kurtarmaz (uygulama şu an $(awk -v v="$hot_ops" 'BEGIN{printf "%.0f", v}') ops/s)"
not_reproduced "tek anahtar tavanı dağıtık tavandan belirgin farklı (${single_ceiling:-?} vs ${spread_ceiling:-?}) — ölçüm gürültülü olabilir, tekrar dene"
