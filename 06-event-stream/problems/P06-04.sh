#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-04 · Poison message: tek bozuk kayıt tüm analitiği durdurabilir
# Tüketici ayrıştıramadığı bir mesajda sadece hata verirse offset İLERLEMEZ: aynı mesaj sonsuza
# kadar yeniden teslim edilir, lag sınırsız büyür ve arkasındaki HER ŞEY bekler. Bir tek bozuk
# kayıt, tüm boru hattını rehin alır. DLQ bunu sınırlı ve incelenebilir bir olaya çevirir.
#
# İKİ FAZ, AYNI BOZUK KAYIT. Yalnızca DLQ'lu (varsayılan) modu ölçüp "DLQ çalıştı" demek, iddia
# edilen DURMAYI hiç üretmez. Bu yüzden: (A) TRAP_NO_DLQ ile bozuk kaydın arkasındaki tıklamalar
# işlenmiyor mu, lag büyüyor mu? (B) DLQ açılınca AYNI tıklamalar serbest kalıyor mu?
# EN: two phases, the same poison record. Measuring only the DLQ path and calling it REPRODUCED
#     because "the DLQ worked" never produces the stall the problem claims; phase A must show it.
ensure_healthy
CONSUMER=analytics
on_cleanup "setenv "$(wl $CONSUMER)" TRAP_NO_DLQ-"
rp=$(dep_pod app.kubernetes.io/name=redpanda) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız

consumer_metric() {   # consumer_metric <awk-deseni> → tüketici pod'larının toplamı (ulaşılamazsa 0)
  local p s=0 v
  for p in $(kubectl -n "$NS" get pods -l app.kubernetes.io/name=$CONSUMER --field-selector=status.phase=Running \
               -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true); do
    v=$({ kubectl --request-timeout=5s -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$p:8080/proxy/metrics" 2>/dev/null || true; } \
          | awk -v pat="$1" '$0 ~ pat {s += $2} END {print s + 0}')
    s=$(awk -v a="$s" -v b="$v" 'BEGIN{print a + b}')
  done
  echo "$s"
}
# Tüketici grubunun gecikmesi (commit edilmemiş kayıt) — broker'ın kendi cevabı, sütun ADIYLA okunur.
group_lag() {
  { kubectl -n "$NS" exec "$rp" -- rpk group describe analytics 2>/dev/null || true; } \
    | awk '$1=="TOPIC" && $2=="PARTITION" {for (i=1;i<=NF;i++) if ($i=="LAG") c=i; next}
           c && $1=="clicks" {s += $c} END {print s + 0}'
}
stats_clicks() { curl -s --max-time 5 "$BASE_URL/api/links/$1/stats" | jq -r '.clicks // 0' 2>/dev/null || echo 0; }
wait_clicks() {   # wait_clicks <kod> <hedef> <saniye> → hedefe ulaşıldıysa 0
  local i
  for (( i = 0; i < $3; i += 3 )); do
    (( $(stats_clicks "$1") >= $2 )) && return 0
    sleep 3
  done
  return 1
}

step "(A) TRAP_NO_DLQ: bozuk kayıt için çıkış yolu YOK"
setenv "$(wl $CONSUMER)" TRAP_NO_DLQ=true >/dev/null
settle_rollout "$(wl $CONSUMER)"
code=$(create_link "https://example.com/poison")
[[ -n "$code" ]] || { warn "link oluşturulamadı"; exit 2; }
# KONTROL: tuzaklı tüketici SAĞLAM kayıtları işliyor mu? İşlemiyorsa sonraki "durdu" ölçüsü
# bozuk kayda değil, çalışmayan bir tüketiciye ait olurdu.
for _ in $(seq 1 20); do status_of "$code" >/dev/null; done
if ! wait_clicks "$code" 20 90; then
  warn "ölçüm yapılamadı: tuzaklı tüketici bozuk kayıt yokken de işlemiyor (sayım $(stats_clicks "$code")/20)."
  exit 2
fi
note "kontrol: bozuk kayıt yokken 20/20 tıklama işlendi"
before=$(stats_clicks "$code")
lag0=$(group_lag)
# Anahtar = kısa kod: bozuk kayıt, arkasından gelecek tıklamalarla AYNI partition'a düşer
# (P06-03'teki add-partitions alıştırmasından sonra da "arkasında" kalsınlar diye).
step "Topic'e BOZUK mesajlar bas (geçerli JSON değil), ardından geçerli tıklamalar"
produced=0
for i in 1 2 3; do
  kubectl -n "$NS" exec "$rp" -- sh -c "echo 'bu-json-degil-$i' | rpk topic produce clicks -k '$code'" >/dev/null 2>&1 \
    && produced=$(( produced + 1 ))
done
(( produced > 0 )) || { warn "ölçüm yapılamadı: rpk ile bozuk kayıt basılamadı"; exit 2; }
N=${N:-200}
for i in $(seq 1 "$N"); do status_of "$code" >/dev/null; done
sleep 30
stuck=$(( $(stats_clicks "$code") - before ))
lagA=$(group_lag)
e1=$(consumer_metric '^consumer_records_total.*result="error"'); sleep 10
e2=$(consumer_metric '^consumer_records_total.*result="error"')
retries=$(awk -v a="$e1" -v b="$e2" 'BEGIN{printf "%d", b - a}')
note "bozuk kaydın arkasındaki $N tıklamadan işlenen: $stuck · grup gecikmesi: $lag0 → $lagA"
note "tüketici aynı bozuk kaydı yeniden deniyor: 10 sn'de +$retries 'error' (offset ilerlemiyor)"

step "(B) DLQ açık (varsayılan): aynı bozuk kayıt kenara alınıyor mu, arkasındakiler akıyor mu?"
setenv "$(wl $CONSUMER)" TRAP_NO_DLQ- >/dev/null
settle_rollout "$(wl $CONSUMER)"
released=0
if wait_clicks "$code" $(( before + N )) 150; then released=$N; else released=$(( $(stats_clicks "$code") - before )); fi
sleep 12
dlq=$(consumer_metric '^consumer_records_total.*result="dlq"')
lagB=$(group_lag)
grafana_hint "08 · Stream → 'Tüketilen kayıtlar (sonuca göre)' + 'Tüketici gecikmesi (bölüme göre)'"
note "DLQ açılınca: $released/$N tıklama işlendi · yeni tüketicinin DLQ'ya taşıdığı: ${dlq%%.*} · grup gecikmesi: $lagB"
note "Ölü mektuplara bak: kubectl -n $NS exec $rp -- rpk topic consume clicks-dlq -n 3"
note "Kural: bir tüketici, işleyemediği mesaj için bir ÇIKIŞ YOLU tanımlamak zorundadır —"
note "atla+say, DLQ'ya taşı ya da bilinçli olarak dur. 'Tanımlamamak' da bir seçimdir: sonsuza kadar dene."
# HÜKÜM: iddia "tek bozuk kayıt arkasındaki HER ŞEYİ durdurur". Düşebilmesi için: tuzak fazında
# tıklamalar işlendiyse (stuck > 0) iddia yanlıştır. Tuzak fazında durma VE DLQ fazında serbest
# kalma birlikte görülmeli; yalnızca durma, tüketicinin başka bir sebeple durduğu anlamına da gelebilir.
if (( stuck > 0 )); then
  not_reproduced "DLQ kapalıyken de bozuk kaydın arkasındaki tıklamalar işlendi ($stuck/$N) — tek kayıt boru hattını durdurmadı"
fi
if (( released < N )); then
  warn "ölçüm yapılamadı: DLQ açılınca da bekleyen tıklamalar işlenmedi ($released/$N) — durmanın sebebi bozuk kayıt olmayabilir."
  exit 2
fi
if (( lagA < N )) || (( retries <= 0 )); then
  warn "ölçüm yapılamadı: tıklamalar işlenmedi ama gecikme ($lagA) ya da yeniden deneme (+$retries) bunu doğrulamıyor."
  exit 2
fi
reproduced "tek bozuk kayıt arkasındaki $N tıklamayı rehin aldı (işlenen 0/$N, gecikme $lagA, aynı kayıt tekrar tekrar denendi); DLQ açılınca kayıt kenara alındı (${dlq%%.*}) ve $released/$N tıklama işlendi"
