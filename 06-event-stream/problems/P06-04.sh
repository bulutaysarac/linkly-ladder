#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-04 · Poison message: tek bozuk kayıt tüm analitiği durdurabilir
# Tüketici ayrıştıramadığı bir mesajda sadece hata verirse offset İLERLEMEZ: aynı mesaj sonsuza
# kadar yeniden teslim edilir, lag sınırsız büyür ve arkasındaki HER ŞEY bekler. Bir tek bozuk
# kayıt, tüm boru hattını rehin alır. DLQ bunu sınırlı ve incelenebilir bir olaya çevirir.
ensure_healthy
CONSUMER=analytics
on_cleanup "kubectl -n \"$NS\" set env deploy/$CONSUMER TRAP_NO_DLQ-"
rp=$(dep_pod app.kubernetes.io/name=redpanda) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
code=$(create_link "https://example.com/poison")
before=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
step "Topic'e BOZUK mesajlar bas (geçerli JSON değil)"
for i in 1 2 3; do
  kubectl -n "$NS" exec "$rp" -- sh -c "echo 'bu-json-degil-$i' | rpk topic produce clicks" >/dev/null 2>&1 || true
done
step "Ardından geçerli tıklamalar üret — bozuk kaydın ARKASINDA kalacaklar"
N=${N:-200}
for i in $(seq 1 "$N"); do status_of "$code" >/dev/null; done
sleep 20
after=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
dlq=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"dlq\"}[10m]))")
errs=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"error\"}[10m]))")
restarts=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=$CONSUMER -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
dlqcount=$(kubectl -n "$NS" exec "$rp" -- rpk topic describe clicks-dlq 2>/dev/null | grep -c . || echo 0)
grafana_hint "08 · Stream → 'consumer records by result' (dlq) + 'consumer lag by partition'"
note "bozuk mesaj sonrası geçerli tıklamalar: $(( after - before )) / $N (ARKASINDAKİLER İŞLENDİ Mİ?)"
note "DLQ'ya taşınan: ${dlq%%.*} · hata: ${errs%%.*} · tüketici restart: ${restarts:-0}"
note "DLQ olmasaydı: offset ilerlemez, lag sonsuza büyür, arkadaki $N tıklama HİÇ işlenmezdi."
note "Deneyin ters ucu: kubectl -n $NS set env deploy/$CONSUMER TRAP_NO_DLQ=true"
note "Kural: bir tüketici, işleyemediği mesaj için bir ÇIKIŞ YOLU tanımlamak zorundadır —"
note "atla+say, DLQ'ya taşı ya da durdur. 'Tanımlamamak' da bir seçimdir: sonsuza kadar dene."
{ awk -v d="${dlq%%.*}" 'BEGIN{exit !(d>0)}' && (( after - before > 0 )); } \
  && reproduced "bozuk mesaj DLQ'ya alındı (${dlq%%.*} kayıt) ve boru hattı akmaya devam etti ($(( after - before ))/$N işlendi)"
not_reproduced "bozuk mesaj etkisi ölçülemedi (rpk produce çalışmamış olabilir)"
