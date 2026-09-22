#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-06 · maxmemory + noeviction → önbellek sessizce önbelleklemeyi bırakır
# Redis dolduğunda `noeviction` politikası YAZMAYI reddeder: "OOM command not allowed".
# Okumalar çalışmaya devam eder, hit oranı bir süre yüksek görünür — ama yeni hiçbir şey
# önbelleğe girmez. Önbellek hâlâ "ayakta"dır ve artık hiçbir işe yaramamaktadır.
#
# ÖLÇÜM NOTU: ilk hâl 6000 küçük link oluşturup 64 MB'lık Redis'i doldurmayı umuyordu —
# ~3 MB yazıp "doldurma gözlenmedi" diyordu. Deneyi ÖLÇEĞE uydur: ya veriyi büyüt ya sınırı
# küçült. Burada ikisini de yapıyoruz (maxmemory 4 MB + ~6 KB'lık URL'ler) ki deney dakikalar
# değil saniyeler sürsün. Sınırı geçici olarak küçültmek meşrudur — DEĞİŞTİRDİĞİNİ SÖYLEDİĞİN sürece.
N=${N:-1200}
TESTMEM=${TESTMEM:-4mb}
ensure_healthy
need_metric redis_evicted_keys_total "redis ServiceMonitor deploy/servicemonitor.yaml'da mı?"
rpod=$(dep_pod app.kubernetes.io/name=redis) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
rcli() { kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli "$@" 2>/dev/null; }
orig_mem=$(rcli CONFIG GET maxmemory | tail -1 | tr -d '\r')
step "Redis ayarları"
note "maxmemory: ${orig_mem:-?} bayt · politika: $(rcli CONFIG GET maxmemory-policy | tail -1)"
note "başlangıç kullanım: $(rcli INFO memory | grep -m1 used_memory_human | tr -d '\r')"
on_cleanup "kubectl -n \"$NS\" exec $rpod -c redis -- redis-cli CONFIG SET maxmemory ${orig_mem:-67108864}"
on_cleanup "kubectl -n \"$NS\" exec $rpod -c redis -- redis-cli FLUSHDB"
step "Sınırı deney için küçült: maxmemory=$TESTMEM (politika DEĞİŞMİYOR: noeviction)"
rcli CONFIG SET maxmemory "$TESTMEM" >/dev/null
rcli FLUSHDB >/dev/null
step "Önbelleği doldur: $N link × ~6 KB URL (oluştur + oku), 20 paralel"
PAD=$(head -c 6000 /dev/zero | tr '\0' 'x')
fill_one() {
  local c
  c=$(curl -s -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' \
        -d "{\"url\":\"https://example.com/fill/$1?p=$PAD\"}" 2>/dev/null \
      | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')
  [[ -n "$c" ]] && curl -s -o /dev/null --max-time 5 "$BASE_URL/$c"
}
export -f fill_one; export BASE_URL PAD
seq 1 "$N" | xargs -P 20 -I{} bash -c 'fill_one {}' >/dev/null 2>&1 || true
sleep 15
# `grep` bulamazsa pipefail atamayı düşürür ve set -e scripti öldürür (bkz. P02-05, P00-01).
used=$(rcli INFO memory | grep -m1 '^used_memory:' | cut -d: -f2 | tr -d '\r' || true)
maxm=$(rcli CONFIG GET maxmemory | tail -1 | tr -d '\r')
keys=$(rcli DBSIZE | tr -d '\r')
seterr=$(promq "sum(increase(cache_errors_total{namespace=\"$NS\",op=\"set\"}[10m]))")
evicted=$(promq "sum(increase(redis_evicted_keys_total{namespace=\"$NS\"}[10m]))")
oomlog=$(kubectl -n "$NS" logs -l "$APP_SELECTOR" --tail=400 2>/dev/null | grep -ci 'OOM command not allowed' || true)
grafana_hint "06 · Redis → 'memory vs maxmemory' + 'evicted / expired keys' · 04 · Cache → 'cache load error'"
note "kullanım: $(( ${used:-0} / 1024 / 1024 )) MB / $(( ${maxm:-1} / 1024 / 1024 )) MB · anahtar: ${keys:-?}"
note "önbellek SET hatası: ${seterr%%.*} · Redis'in attığı anahtar: ${evicted%%.*} · logda 'OOM command not allowed': $oomlog"
note "Kritik ayrım: eviction=0 ve SET hatası>0 ise politika noeviction demektir — önbellek DOLDU"
note "ve yeni hiçbir şey kabul etmiyor. allkeys-lru olsaydı eviction>0 olur, SET hatası olmazdı."
note "Sinsi kısmı: okumalar çalışmaya DEVAM eder, hit oranı bir süre yüksek kalır. Önbellek"
note "'ayakta' görünürken yeni anahtarları hiç kabul etmez ve her yeni link DB'ye iner."
note "ÇÖZÜM: kubectl -n $NS exec $rpod -c redis -- redis-cli CONFIG SET maxmemory-policy allkeys-lru"
note "Ama asıl karar şu: önbelleğin BOYUTU çalışma kümesini karşılıyor mu? Karşılamıyorsa hangi"
note "politikayı seçersen seç hit oranı düşer — LRU yalnızca düşüşü kibarlaştırır."
{ awk -v e="${seterr%%.*}" 'BEGIN{exit !(e>0)}' || (( oomlog > 0 )); } \
  && reproduced "Redis doldu ve yazmayı reddediyor (${seterr%%.*} SET hatası, logda $oomlog OOM satırı, eviction ${evicted%%.*}) — önbellek sessizce devre dışı"
not_reproduced "SET hatası yok (kullanım $(( ${used:-0} / 1024 / 1024 ))/$(( ${maxm:-1} / 1024 / 1024 )) MB — N'i artır ya da TESTMEM'i küçült)"
