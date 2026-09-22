#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-02 · Tüketici gecikmesi (lag): olaylar kaybolmuyor ama analitik BAYATLIYOR
# Kuyruk artık dayanıklı — bu, verinin güvende olduğu ama GÜNCEL olmadığı anlamına geliyor.
# Yeni izlenecek şey lag: "ne kadar geriden geliyoruz?" Bu, 07'de KEDA'nın ölçekleme sinyali olacak.
ensure_healthy
CONSUMER=analytics
on_cleanup "kubectl -n \"$NS\" scale "$(wl $CONSUMER)" --replicas=1"
code=$(create_link "https://example.com/lag")
before=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
step "Tüketiciyi tamamen durdur (replicas=0)"
kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=0 >/dev/null
sleep 5
step "Tıklama üretmeye devam et — üretici çalışıyor, tüketici yok"
N=${N:-2000}
clicks "$code" "$N" 20
sleep 8
mid=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
produced=$(promq "sum(increase(producer_records_total{namespace=\"$NS\",result=\"ok\"}[10m]))")
note "tüketici kapalıyken: üretilen ≈ ${produced%%.*} · stats'ta görünen: $(( mid - before )) (BAYAT)"
note "Veri KAYIP DEĞİL, sadece henüz işlenmedi — 05'te aynı senaryo kalıcı kayıptı (P05-01)."
# KRİTİK ADIM: burada tüketiciyi ELLE AÇMIYORUZ. Ölçmek istediğimiz şey "sistem kendi kendine
# toparlanıyor mu?" — 06'da hayır (kimse tüketiciyi geri getirmez, analitik bir insan fark edene
# kadar bayat kalır), 07'de evet (KEDA lag'i görüp ölçekler). Script tüketiciyi kendisi açarsa
# iki seviyede de aynı sonucu ölçer ve "07 bunu çözdü" iddiası DOĞRULANAMAZ.
step "Kimse müdahale etmeden 120 sn bekle: sistem kendi kendine toparlanıyor mu?"
t0=$(date +%s); recovered=0
for _ in $(seq 1 40); do
  now=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  (( now - before >= N * 90 / 100 )) && { recovered=1; break; }
  sleep 3
done
t1=$(date +%s)
self=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
reps=$(kubectl -n "$NS" get "$(wl $CONSUMER)" -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
note "120 sn sonra: tüketici replikası=${reps:-?} · sayım $(( self - before ))/$N · kendiliğinden toparlandı mı: $( ((recovered)) && echo EVET || echo HAYIR)"
step "Şimdi ELLE aç — verinin kaybolmadığını göster (dayanıklı log)"
kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=1 >/dev/null
kubectl -n "$NS" rollout status "$(wl $CONSUMER)" --timeout=120s >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  now=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
  (( now - before >= N * 95 / 100 )) && break
  sleep 3
done
final=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
grafana_hint "08 · Stream → 'consumer lag by partition' + 'produced vs consumed vs written'"
note "elle açtıktan sonra son sayım: $(( final - before )) / $N — veri KAYBOLMADI, sadece bekledi"
note "Lag bir HATA değil bir ÖLÇÜDÜR: 'ne kadar geriden geliyoruz'. Alarm eşiği bir ürün kararıdır."
note "07: KEDA lag'i ölçekleme sinyali yapacak — tüketici sayısı otomatik artacak."
note "Ama dikkat: tek partition varsa tüketici artırmak İŞE YARAMAZ (P06-03)."
{ awk -v m="$(( mid - before ))" -v n="$N" 'BEGIN{exit !(m < n*0.9)}' && (( recovered == 0 )); } \
  && reproduced "analitik bayatladı (görünen $(( mid - before ))/$N) ve ~$((t1-t0)) sn boyunca KENDİ KENDİNE toparlanmadı; elle açınca $(( final - before ))/$N'e yakalandı — veri kayıp değil, ama kimse fark etmezse bayat kalır"
not_reproduced "sistem kendi kendine toparlandı (tüketici replikası ${reps:-?}) — lag bir ölçekleme sinyali hâline gelmiş (07: KEDA)"
