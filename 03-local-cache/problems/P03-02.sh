#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-02 · Her rollout/scale-out = soğuk önbellek = DB'de testere dişi
# Önbellek pod'un belleğinde; pod ölünce önbellek de ölüyor. Her dağıtım, DB'ye bir yük dalgası.
ensure_healthy
# TTL'i deney süresince UZAT (10 dk). Neden: varsayılan 60 sn'lik TTL ile 200 anahtar × 3 pod
# sürekli yeniden doluyor (≈10 DB get/s) ve bu "TTL churn", ölçmek istediğimiz SOĞUK BAŞLANGIÇ
# darbesiyle aynı büyüklükte. Varsayılan TTL'le kararlı hâl ~17.6/s, rollout penceresi ~12.0/s
# ölçülür — sinyal gürültünün ALTINDA kalır. İki ayrı olayı (TTL dolması = P03-07, pod'un boş
# doğması = P03-02) ölçmek istiyorsan birini susturman gerekir.
on_cleanup "setenv "$(app_workload)" CACHE_TTL-"
setenv "$(app_workload)" CACHE_TTL=10m >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null || true
for _ in $(seq 1 30); do serving && break; sleep 2; done
# ÖLÇÜM NOTU — "tepe" tek başına kanıt değil:
# `max_over_time(...[5m:15s])` ile TÜM koşunun tepesini alıp sondaki orana bölmek yanıltır.
# O tepe rollout'tan değil, yükün KENDİ soğuk başlangıcından gelir: k6 setup'ı her koşuda
# yeni kodlar oluşturur, ilk okumaları zorunlu olarak DB'ye iner. Böyle bir ölçü rollout hiç
# yapılmasa da "REPRODUCED" der — paylaşılan önbellekli 04'te bile.
# Doğrusu: yük ısındıktan SONRA iki eşit pencereyi kıyasla — kararlı hâl vs rollout penceresi.
step "2000 kodluk çalışma kümesiyle sürekli okuma yükü (ısınma + kararlı hâl + rollout)"
( SEED=2000 SEED_BUDGET_MS=240000 k6run redirect --vus 20 --duration 240s >/tmp/p0302.k6 2>&1 ) & kpid=$!
sleep 75                     # yükün soğuk başlangıcı bitsin: 2000 kod × 3 pod ısınsın
W=45
db_rate() { promq "sum(increase(db_queries_total{namespace=\"$NS\",op=\"get\"}[${1}s])) / $1"; }
sleep "$W"
steady_db=$(db_rate "$W")    # KARARLI hâl: önbellek sıcak, yük aynı, TTL uzun → DB neredeyse boşta
note "kararlı hâl (rollout ÖNCESİ, ${W}s pencere): DB get/s=$(awk -v v="$steady_db" 'BEGIN{printf "%.1f", v}')"
t0=$(date +%s)
kubectl -n "$NS" rollout restart "$(app_workload)" >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null 2>&1 || true
sleep 30                     # yeni pod'lar trafiği alsın ve yeniden ısınsın
t1=$(date +%s); RW=$(( t1 - t0 ))
peak_db=$(db_rate "$RW")     # ROLLOUT penceresi: yalnızca restart'ın etkisi
misses=$(promq "sum(increase(cache_ops_total{namespace=\"$NS\",result=\"miss\"}[${RW}s]))")
wait $kpid || true
sleep 12
now_db=$(promq "sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[1m]))")
grafana_hint "04 · Cache → 'cache miss vs DB qps' · 05 · Postgres → 'DB queries by op'"
note "rollout penceresi (${RW}s): DB get/s=$(awk -v v="$peak_db" 'BEGIN{printf "%.1f", v}') · pencere içi miss=${misses%%.*} · yük sonrası: $(awk -v v="$now_db" 'BEGIN{printf "%.1f", v}')/s"
note "Her yeni pod boş bellekle doğuyor: ilk istekler zorunlu olarak DB'ye iniyor."
note "Bu yüzden 'önbellek sayesinde DB'yi küçülttük' demek tehlikelidir — DB, SOĞUK anı kaldırabilmeli."
note "Çözüm 04: önbellek pod'un dışında (Redis); pod ölse de önbellek yaşar."
awk -v p="$peak_db" -v s="$steady_db" 'BEGIN{exit !(p > s*3 && p > 5)}' \
  && reproduced "rollout DB okumasını kararlı $(awk -v v="$steady_db" 'BEGIN{printf "%.1f", v}')/s'den $(awk -v v="$peak_db" 'BEGIN{printf "%.1f", v}')/s'e çıkardı — soğuk önbellek testere dişi"
not_reproduced "rollout DB'de tepe yaratmadı — önbellek süreç dışında (04)"
