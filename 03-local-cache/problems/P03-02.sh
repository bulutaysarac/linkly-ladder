#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-02 · Her rollout/scale-out = soğuk önbellek = DB'de testere dişi
# Önbellek pod'un belleğinde; pod ölünce önbellek de ölüyor. Her dağıtım, DB'ye bir yük dalgası.
ensure_healthy
step "Önbelleği ısıt: 300 link, her birine birkaç okuma"
codes=$(mktemp)
for i in $(seq 1 300); do create_link "https://example.com/warm/$i" >> "$codes"; done
for round in 1 2 3; do while read -r c; do [[ -n "$c" ]] && status_of "$c" >/dev/null; done < "$codes"; done
sleep 12
warm_db=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[1m]))")
hit=$(promq "sum(rate(cache_ops_total{namespace=\"$NS\",result=\"hit\"}[1m])) / sum(rate(cache_ops_total{namespace=\"$NS\"}[1m]))")
note "ısınmış durumda: DB get/s=$(awk -v v="$warm_db" 'BEGIN{printf "%.1f", v}') · hit oranı=$(awk -v v="$hit" 'BEGIN{printf "%.0f%%", v*100}')"
# ÖLÇÜM NOTU — "tepe" tek başına kanıt değil:
# İlk hâl `max_over_time(...[5m:15s])` ile TÜM koşunun tepesini alıp sondaki orana bölüyordu.
# O tepe rollout'tan değil, yükün KENDİ soğuk başlangıcından geliyordu: k6 setup'ı her koşuda
# yeni kodlar oluşturur, ilk okumaları zorunlu olarak DB'ye iner. Yani script, rollout'u hiç
# yapmasa da "REPRODUCED" derdi — nitekim 04'te (paylaşılan önbellek) yanlışlıkla dedi.
# Doğrusu: yük ısındıktan SONRA iki eşit pencereyi kıyasla — kararlı hâl vs rollout penceresi.
step "Sürekli okuma yükü altında rollout restart — önbellek sıfırlanacak"
( k6run redirect --vus 20 --duration 180s >/tmp/p0302.k6 2>&1 ) & kpid=$!
sleep 35                     # yükün soğuk başlangıcı bitsin: tüm kodlar önbellekte
W=45
db_rate() { promq "sum(increase(db_queries_total{namespace=\"$NS\",op=\"get\"}[${1}s])) / $1"; }
sleep "$W"
steady_db=$(db_rate "$W")    # KARARLI hâl: önbellek sıcak, yük aynı
note "kararlı hâl (rollout ÖNCESİ, ${W}s pencere): DB get/s=$(awk -v v="$steady_db" 'BEGIN{printf "%.1f", v}')"
t0=$(date +%s)
kubectl -n "$NS" rollout restart deploy/linkly >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null 2>&1 || true
sleep 25                     # yeni pod'lar trafiği alsın ve ısınsın
t1=$(date +%s); RW=$(( t1 - t0 ))
peak_db=$(db_rate "$RW")     # ROLLOUT penceresi: yalnızca restart'ın etkisi
wait $kpid || true
sleep 12
now_db=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[1m]))")
misses=$(promq "sum(increase(cache_ops_total{namespace=\"$NS\",result=\"miss\"}[${RW}s]))")
rm -f "$codes"
grafana_hint "04 · Cache → 'cache miss vs DB qps' · 05 · Postgres → 'DB queries by op'"
note "rollout penceresi (${RW}s): DB get/s=$(awk -v v="$peak_db" 'BEGIN{printf "%.1f", v}') · pencere içi miss=${misses%%.*} · yük sonrası: $(awk -v v="$now_db" 'BEGIN{printf "%.1f", v}')/s"
note "Her yeni pod boş bellekle doğuyor: ilk istekler zorunlu olarak DB'ye iniyor."
note "Bu yüzden 'önbellek sayesinde DB'yi küçülttük' demek tehlikelidir — DB, SOĞUK anı kaldırabilmeli."
note "Çözüm 04: önbellek pod'un dışında (Redis); pod ölse de önbellek yaşar."
awk -v p="$peak_db" -v s="$steady_db" 'BEGIN{exit !(p > s*2 && p > 2)}' \
  && reproduced "rollout DB okumasını kararlı $(awk -v v="$steady_db" 'BEGIN{printf "%.1f", v}')/s'den $(awk -v v="$peak_db" 'BEGIN{printf "%.1f", v}')/s'e çıkardı — soğuk önbellek testere dişi"
not_reproduced "rollout DB'de tepe yaratmadı — önbellek süreç dışında (04)"
