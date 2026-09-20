#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-06 · maxmemory + noeviction → önbellek sessizce önbelleklemeyi bırakır
# Redis dolduğunda `noeviction` politikası YAZMAYI reddeder: "OOM command not allowed".
# Okumalar çalışmaya devam eder, hit oranı bir süre yüksek görünür — ama yeni hiçbir şey
# önbelleğe girmez. Önbellek hâlâ "ayakta"dır ve artık hiçbir işe yaramamaktadır.
ensure_healthy
rpod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}')
rcli() { kubectl -n "$NS" exec "$rpod" -c redis -- redis-cli "$@" 2>/dev/null; }
step "Redis ayarları"
note "maxmemory: $(rcli CONFIG GET maxmemory | tail -1) bayt · politika: $(rcli CONFIG GET maxmemory-policy | tail -1)"
note "başlangıç kullanım: $(rcli INFO memory | grep -m1 used_memory_human | tr -d '\r')"
step "Önbelleği doldur: çok sayıda farklı link oluştur ve oku"
N=${N:-6000}
for i in $(seq 1 "$N"); do
  c=$(create_link "https://example.com/fill/$i/$(head -c 200 /dev/zero | tr '\0' 'x')")
  [[ -n "$c" ]] && status_of "$c" >/dev/null
done
sleep 12
used=$(promq "sum(redis_memory_used_bytes{namespace=\"$NS\"})")
maxm=$(promq "max(redis_memory_max_bytes{namespace=\"$NS\"})")
seterr=$(promq "sum(increase(cache_errors_total{namespace=\"$NS\",op=\"set\"}[10m]))")
evicted=$(promq "sum(increase(redis_evicted_keys_total{namespace=\"$NS\"}[10m]))")
keys=$(rcli DBSIZE | tr -d '\r')
grafana_hint "06 · Redis → 'memory vs maxmemory' + 'evicted / expired keys' · 04 · Cache → 'cache load error'"
note "kullanım: $(( ${used%%.*} / 1024 / 1024 )) MB / $(( ${maxm%%.*} / 1024 / 1024 )) MB · anahtar: ${keys:-?}"
note "önbellek SET hatası: ${seterr%%.*} · Redis'in attığı anahtar: ${evicted%%.*}"
note "Kritik ayrım: eviction=0 ve SET hatası>0 ise politika noeviction demektir — önbellek DOLDU"
note "ve yeni hiçbir şey kabul etmiyor. allkeys-lru olsaydı eviction>0 olur, SET hatası olmazdı."
note "ÇÖZÜM: kubectl -n $NS exec $rpod -c redis -- redis-cli CONFIG SET maxmemory-policy allkeys-lru"
note "Ama asıl karar şu: önbelleğin BOYUTU çalışma kümesini karşılıyor mu? Karşılamıyorsa hangi"
note "politikayı seçersen seç, hit oranı düşer — LRU yalnızca düşüşü kibarlaştırır."
awk -v e="${seterr%%.*}" 'BEGIN{exit !(e>0)}' \
  && reproduced "Redis doldu ve yazmayı reddediyor (${seterr%%.*} SET hatası, eviction ${evicted%%.*}) — önbellek sessizce devre dışı"
not_reproduced "SET hatası yok (N'i artır ya da politikayı kontrol et: allkeys-lru olabilir)"
