#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-02 · Tüketici gecikmesi (lag): olaylar kaybolmuyor ama analitik BAYATLIYOR
# Kuyruk artık dayanıklı — bu, verinin güvende olduğu ama GÜNCEL olmadığı anlamına geliyor.
# Yeni izlenecek şey lag: "ne kadar geriden geliyoruz?" Bu, 07'de KEDA'nın ölçekleme sinyali olacak.
ensure_healthy
CONSUMER=analytics
on_cleanup "kubectl -n \"$NS\" scale deploy/$CONSUMER --replicas=1"
code=$(create_link "https://example.com/lag")
before=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
step "Tüketiciyi tamamen durdur (replicas=0)"
kubectl -n "$NS" scale deploy/$CONSUMER --replicas=0 >/dev/null
sleep 5
step "Tıklama üretmeye devam et — üretici çalışıyor, tüketici yok"
N=${N:-800}
for i in $(seq 1 "$N"); do status_of "$code" >/dev/null; done
sleep 8
mid=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
produced=$(promq "sum(increase(producer_records_total{namespace=\"$NS\",result=\"ok\"}[10m]))")
note "tüketici kapalıyken: üretilen ≈ ${produced%%.*} · stats'ta görünen: $(( mid - before )) (BAYAT)"
note "Veri KAYIP DEĞİL, sadece henüz işlenmedi — 05'te aynı senaryo kalıcı kayıptı (P05-01)."
step "Tüketiciyi geri aç — birikmiş olanlar işlenecek"
t0=$(date +%s)
kubectl -n "$NS" scale deploy/$CONSUMER --replicas=1 >/dev/null
kubectl -n "$NS" rollout status deploy/$CONSUMER --timeout=120s >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  now=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  (( now - before >= N * 95 / 100 )) && break
  sleep 3
done
t1=$(date +%s)
final=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
grafana_hint "08 · Stream → 'consumer lag by partition' + 'produced vs consumed vs written'"
note "yakalama süresi: ~$((t1-t0)) sn · son sayım: $(( final - before )) / $N"
note "Lag bir HATA değil bir ÖLÇÜDÜR: 'ne kadar geriden geliyoruz'. Alarm eşiği bir ürün kararıdır."
note "07: KEDA lag'i ölçekleme sinyali yapacak — tüketici sayısı otomatik artacak."
note "Ama dikkat: tek partition varsa tüketici artırmak İŞE YARAMAZ (P06-03)."
awk -v m="$(( mid - before ))" -v n="$N" 'BEGIN{exit !(m < n*0.9)}' \
  && reproduced "tüketici yokken analitik bayatladı (görünen $(( mid - before ))/$N), tüketici dönünce $(( final - before ))/$N'e yakalandı — kayıp yok, gecikme var"
not_reproduced "tüketici kapalıyken bile sayım güncel kaldı (beklenmedik — kurulum kontrol edilmeli)"
