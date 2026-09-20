#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-07 · TRAP_NO_TTL_JITTER: aynı anda yazılan anahtarlar aynı anda dolar → periyodik DB tepesi
# Bir dağıtımdan sonra önbellek tek seferde ısınır: binlerce anahtar aynı saniyede yazılır ve
# TTL süresi sonra hepsi aynı saniyede dolar. Grafikte düzenli aralıklı dikey darbeler görürsün;
# sistemin kendi kendine yarattığı, saat gibi işleyen bir yük dalgası.
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_NO_TTL_JITTER- CACHE_TTL-"
TTLS=${TTLS:-20s}
warm_and_watch() {
  kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  # Tek seferde ısıt: 400 anahtarı arka arkaya oku → hepsi neredeyse aynı anda önbelleğe girsin
  for i in $(seq 1 400); do status_of "$(create_link "https://example.com/j/$i")" >/dev/null; done
  # Sonra sabit, düşük yoğunluklu okuma: tepeler yalnızca TTL dolmalarından gelsin
  k6run redirect --vus 5 --duration 90s >/dev/null 2>&1 || true
  sleep 10
  peak=$(promq "max_over_time(sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[15s]))[3m:15s])")
  avg=$(promq "avg_over_time(sum(rate(db_queries_total{namespace=\"$NS\",op=\"get\"}[15s]))[3m:15s])")
  echo "$peak $avg"
}
step "Jitter AÇIK (varsayılan), TTL $TTLS"
kubectl -n "$NS" set env deploy/linkly CACHE_TTL="$TTLS" TRAP_NO_TTL_JITTER- >/dev/null
read -r p1 a1 <<< "$(warm_and_watch)"
r1=$(awk -v p="$p1" -v a="$a1" 'BEGIN{printf "%.1f", (a>0? p/a : 0)}')
note "jitter'lı: tepe=$(awk -v v="$p1" 'BEGIN{printf "%.0f", v}')/s ortalama=$(awk -v v="$a1" 'BEGIN{printf "%.0f", v}')/s → tepe/ortalama=$r1"
step "Jitter KAPALI, aynı senaryo"
kubectl -n "$NS" set env deploy/linkly TRAP_NO_TTL_JITTER=true >/dev/null
read -r p2 a2 <<< "$(warm_and_watch)"
r2=$(awk -v p="$p2" -v a="$a2" 'BEGIN{printf "%.1f", (a>0? p/a : 0)}')
note "jitter'sız: tepe=$(awk -v v="$p2" 'BEGIN{printf "%.0f", v}')/s ortalama=$(awk -v v="$a2" 'BEGIN{printf "%.0f", v}')/s → tepe/ortalama=$r2"
grafana_hint "05 · Postgres → 'DB queries by op' (düzenli aralıklı dikey darbeler) · 04 · Cache → 'eviction/expired'"
note "Bakılacak sayı ortalama değil, TEPE/ORTALAMA oranı: kapasite planlaması tepeye göre yapılır."
note "Jitter, ilişkisiz olayların ilişkili hâle gelmesini engelleyen genel bir tekniktir —"
note "aynı fikir retry'da (10) ve cron'larda da karşına çıkacak."
awk -v a="$r1" -v b="$r2" 'BEGIN{exit !(b > a)}' \
  && reproduced "jitter'sız tepe/ortalama oranı $r1 → $r2'ye çıktı — TTL'ler hizalandı, DB periyodik darbe alıyor"
not_reproduced "tepe oranı artmadı (TTL ya da ısıtma penceresini gözden geçir)"
