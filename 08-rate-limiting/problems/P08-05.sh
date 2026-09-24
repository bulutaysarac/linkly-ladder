#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-05 · TRAP_GLOBAL_LIMIT: tek global anahtar = Redis'te hot key
# "Tüm sistem için saniyede N istek" makul bir kural gibi görünür. Gerçekleştirmesi tek bir Redis
# anahtarına HER istekte yazmaktır — ve Redis tek iş parçacıklıdır (P04-03). Koruma, koruduğu
# sistemden önce kendisi darboğaz olur.
#
# ÖLÇÜM NOTU — neden "p99 arttı mı?" diye BAKMIYORUZ (P04-03 ile aynı ders):
# Dağıtık anahtar ile global anahtarın limit kontrolü p99'unu kıyaslamak iki koşuda da aynı sayıyı
# verir. Sebep basit: bu kümede uygulama saniyede birkaç yüz istek üretiyor, tek bir Redis anahtarı
# ise on binlerce yazmayı rahatça kaldırır. Bu "sorun YOK" demek değildir — sorunun göründüğü YÜKE
# hiç çıkılmamıştır. Sıcak anahtarın arızası bir yavaşlama değil, bir TAVAN'dır:
# tek anahtar tek çekirdektir ve o tavanı ancak tavanı DOĞRUDAN ölçerek gösterebilirsin.
limits_enforced   # bu script limiter'ı sınıyor — yük girişi ve muafiyet jetonu KULLANILMAZ
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
rpod=$(dep_pod app.kubernetes.io/name=redis) || exit 2
on_cleanup "setenv "$(wl redirect)" TRAP_GLOBAL_LIMIT-"
measure() {
  kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  k6run redirect --vus 40 --duration 40s >/dev/null 2>&1 || true
  sleep 10
  local p99 cpu
  p99=$(promq "histogram_quantile(0.99, sum(rate(ratelimit_check_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")
  cpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"redis.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[3m:15s])")
  echo "$p99 $cpu"
}
# redis-benchmark'ın çıktısı insan içindir: ilerleme satırlarını \r ile üstüne yazar.
# \r'yi satır sonuna çevir, "N requests per second" kalıbının SONUNCUSUNU al (P04-03'ün dersi).
bench() {
  local out
  out=$(kubectl -n "$NS" exec "$rpod" -c redis -- redis-benchmark -q -t incr -n "${2:-100000}" -c 50 -r "$1" 2>/dev/null | tr '\r' '\n') || true
  { printf '%s\n' "$out" | grep -oE '[0-9]+(\.[0-9]+)? requests per second' | tail -1 | cut -d' ' -f1 | cut -d. -f1; } || true
}
step "TAVANI DOĞRUDAN ÖLÇ: sayaç 100k anahtara dağılmış vs TEK anahtarda (pod içinde, ağ dışı)"
spread=$(bench 100000)
single=$(bench 0)
[[ -z "${spread:-}" || -z "${single:-}" ]] && { warn "redis-benchmark çıktısı ayrıştırılamadı"; exit 2; }
note "dağıtık INCR tavanı: ${spread} ops/s · TEK anahtar INCR tavanı: ${single} ops/s"
note "İkisi yakınsa mesaj şudur: sınır ANAHTARDA değil INSTANCE'ta — yani global limitin tavanı,"
note "kaç pod'un olduğundan BAĞIMSIZ olarak tek bir Redis çekirdeğidir. Koruma, koruduğu sistemin"
note "ölçeklenmesini kendi tavanıyla sınırlar."

step "Anahtar başına limit (varsayılan): yük Redis'te birçok anahtara dağılıyor"
read -r p1 c1 <<< "$(measure)"
note "dağıtık anahtar: limit kontrolü p99=$(awk -v v="$p1" 'BEGIN{printf "%.2f", v*1000}') ms · Redis CPU=$(awk -v v="$c1" 'BEGIN{printf "%.2f", v}')"
step "TRAP_GLOBAL_LIMIT: her istek TEK anahtara yazıyor"
setenv "$(wl redirect)" TRAP_GLOBAL_LIMIT=true >/dev/null
read -r p2 c2 <<< "$(measure)"
note "global anahtar: limit kontrolü p99=$(awk -v v="$p2" 'BEGIN{printf "%.2f", v*1000}') ms · Redis CPU=$(awk -v v="$c2" 'BEGIN{printf "%.2f", v}')"
grafana_hint "06 · Redis → 'Redis CPU' + 'Komutlar (türe göre)' · 10 · Rate limit → 'Kararlar (anahtar türüne göre)'"
note "Global limit gerçekten gerekiyorsa: anahtarı PARÇALA (global:0..15, rastgele seç, limiti 16'ya böl)."
note "Bu, kesinlikten biraz ödün verir (parçalar eşit dolmaz) ama sıcak anahtarı ortadan kaldırır."
note "Genel kural: paylaşılan durumda 'tek sayaç' istemek, tek bir CPU çekirdeğine ölçeklenmek demektir."
note "Aynı desen 04'te önbellekte (P04-03), 02'de DB satırında (P02-08) karşımıza çıktı — üçü de aynı fizik."
note "Uygulama şu an bu tavanın çok altında: ölçülen p99 farkı $(awk -v a="$p1" -v b="$p2" 'BEGIN{printf "%.2f", (b-a)*1000}') ms."
note "Bu bir 'sorun yok' kanıtı DEĞİL, 'henüz oraya gelmedin' kanıtıdır — ve tavan, trafik"
note "büyüdüğünde taşınamaz bir yerdedir. Kapasite planlaması tam olarak bu farkı okumaktır."
# KARAR: tavan tek çekirdekte mi? Dağıtık ve tek anahtar tavanları birbirine YAKINSA
# (sharding kurtarmıyorsa) iddia kanıtlanmıştır. Ölçü, uygulamanın o an ne kadar yavaş
# olduğu değil, SINIRIN NEREDE olduğudur.
awk -v s="$spread" -v o="$single" 'BEGIN{exit !(o > 0 && s > 0 && o < s*1.5)}' \
  && reproduced "tek anahtar tavanı ${single} ops/s, dağıtık tavan ${spread} ops/s — sınır anahtarda değil INSTANCE'ta, yani global limit tek çekirdeğe ölçeklenir (uygulama p99 $(awk -v v="$p1" 'BEGIN{printf "%.2f", v*1000}') → $(awk -v v="$p2" 'BEGIN{printf "%.2f", v*1000}') ms)"
not_reproduced "tavan karşılaştırması beklenmedik: dağıtık=${spread:-?} tek=${single:-?} ops/s"
