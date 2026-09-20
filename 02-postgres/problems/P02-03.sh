#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-03 · Veritabanı tek nokta: ölürse hem yazma hem OKUMA durur
# Uygulama 3 replika ve "yüksek erişilebilir" görünüyor. Değil: üç pod da aynı tek Postgres'e bağlı.
# Yedeklilik, zincirin EN ZAYIF halkası kadardır.
ensure_healthy
need_confirm "postgres pod'u silinecek (veri PVC'de kalır)"
( k6run redirect --vus 5 --duration 120s >/tmp/p0203.k6 2>&1 ) & kpid=$!
sleep 15
step "Postgres'i öldür — uygulama pod'larına DOKUNMUYORUZ"
t0=$(date +%s)
kubectl -n "$NS" delete pod -l app.kubernetes.io/name=postgres --wait=false >/dev/null
down=0
for _ in $(seq 1 90); do
  st=$(status_of "healthz-probe-xyz")
  [[ "$st" == 503 || "$st" == 000 ]] && down=$((down+1))
  serving && break
  sleep 2
done
t1=$(date +%s)
wait $kpid || true
e5=$(k6_5xx); reqs=$(k6_reqs)
appready=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" --no-headers | grep -c '1/1' || true)
grafana_hint "05 · Postgres → 'pg_up' / 'connections' · 02 · App RED → 5xx · 01 · Pods → 'hazır endpoint sayısı'"
note "kesinti penceresi: ~$((t1-t0)) sn · k6: $reqs istek, $e5 tanesi 5xx"
note "Uygulama pod'ları bu süre boyunca AYAKTA ve HAZIR kaldı ($appready/3) — ve hiçbir şey yapamadılar."
note "Bu bilinçli bir tercih: readiness bağımlılığa bakmıyor (P02-10 bunun alternatifini ölçüyor)."
note "Çözüm 09: CNPG ile primary+replica ve otomatik failover. Ama failover da anlık değildir — 09 o pencereyi ölçecek."
(( e5 > 0 )) && reproduced "tek DB düştü → $e5 istek 5xx, ~$((t1-t0)) sn kesinti; 3 replika hiçbir şeyi kurtarmadı"
not_reproduced "DB kaybında kesinti olmadı — failover var (09)"
