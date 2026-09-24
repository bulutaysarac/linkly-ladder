#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-02 · TRAP_NO_KAFKA_PROPAGATION: trace asenkron sınırda KOPAR
# HTTP'de bağlam otomatik taşınır (traceparent header'ı). Kuyrukta taşınmaz — sen koymazsan
# tüketici span'leri YETİM kalır ve "bu tıklama neden 10 saniye sonra işlendi?" sorusu
# cevapsız kalır. Tam da asenkron yaptığın için görünmez olan yer, en çok trace gereken yerdir.
#
# HER KOŞULDA "REPRODUCED" DİYEN BİR DENEYİN İKİ YOLU VAR — ikisi de kapalı.
# (1) Handler tıklamayı isteğin bağlamıyla kaydeder (`Record(r.Context(), code)`). Bağlamsız
#     kaydedilse üretici context.Background() enjekte eder, header'a hiç trace yazılmaz ve
#     tüketici trace'leri tuzak AÇIK da KAPALI da yetim olur — tuzağın kapatacağı bir şey kalmaz.
# (2) "İki fazdan birinde analytics trace'i var mı?" (on>0 || off>0) diye soran bir hüküm,
#     tracing çalıştığı sürece yapıdan bağımsız hep geçer.
# Bu yüzden hüküm İKİ MODUN YAPISINI karşılaştırır: tüketici span'li trace'lerin KÖKÜ kim?
# `linkly-redirect` → bağlı (tek ağaç); `linkly-analytics` → yetim.
# EN: the handler records clicks WITH the request context — without it consumer traces would be
# orphaned in BOTH modes — and a verdict like (on>0 || off>0) passes whenever tracing works at
# all. So the verdict compares the ROOT of consumer traces between the two modes.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_NO_KAFKA_PROPAGATION-"

TEMPO_PORT=${TEMPO_PORT:-13200}
kubectl -n monitoring port-forward svc/tempo "$TEMPO_PORT:3200" >/dev/null 2>&1 &
tempo_pf=$!
on_cleanup "kill $tempo_pf"
for _ in $(seq 1 15); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$TEMPO_PORT/ready" && break; sleep 1; done
if ! curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:$TEMPO_PORT/ready"; then
  warn "Tempo'ya ulaşılamadı (kurulu mu? cd platform && make tempo) — trace yapısı ölçülemez."
  warn "Bu bir hüküm değil, EKSİK ÖLÇÜMdür."
  exit 2
fi

# consumer_roots BAŞ SON → "bağlı yetim diğer": tüketici span'i (consume-batch) taşıyan trace'lerin
# kök servislerine göre sayısı. "diğer" = kök span Tempo'ya henüz ulaşmamış trace'ler.
consumer_roots() {
  local out
  out=$(curl -sG "http://127.0.0.1:$TEMPO_PORT/api/search" \
          --data-urlencode 'q={ resource.service.name = "linkly-analytics" && name = "consume-batch" }' \
          --data-urlencode "start=$1" --data-urlencode "end=$2" --data-urlencode "limit=500" 2>/dev/null || true)
  [[ -n "$out" ]] || out='{}'
  jq -r '[.traces[]?.rootServiceName] as $r
         | "\([$r[] | select(. == "linkly-redirect")] | length) \([$r[] | select(. == "linkly-analytics")] | length) \([$r[] | select(. != "linkly-redirect" and . != "linkly-analytics")] | length)"' \
     <<<"$out" 2>/dev/null || echo "0 0 0"
}
# Faz başına ZAMAN PENCERESİ: iki fazın trace'leri birbirine karışmasın.
phase() {
  local t0 t1
  t0=$(date +%s)
  k6run redirect --vus 10 --duration 30s >/dev/null 2>&1 || true
  sleep 20                                   # span gönderimi (2 sn batch) + Alloy + Tempo ingester
  t1=$(date +%s)
  read -r PH_LINKED PH_ORPHAN PH_OTHER <<< "$(consumer_roots "$t0" "$t1")"
}

step "(1) Propagation AÇIK: üretici isteğin bağlamını Kafka header'ına koyuyor"
phase
on_l=$PH_LINKED; on_o=$PH_ORPHAN; on_x=$PH_OTHER
note "tüketici span'li trace: kökü linkly-redirect (bağlı)=$on_l · kökü linkly-analytics (yetim)=$on_o · kök henüz yok=$on_x"
step "(2) TRAP: bağlam header'a KONMUYOR (başka hiçbir şey değişmiyor)"
setenv "$(wl redirect)" TRAP_NO_KAFKA_PROPAGATION=true >/dev/null
settle_rollout "$(wl redirect)"
phase
off_l=$PH_LINKED; off_o=$PH_ORPHAN; off_x=$PH_OTHER
note "tuzakla: bağlı=$off_l · yetim=$off_o · kök henüz yok=$off_x"
grafana_hint "08 · Stream (Redpanda) → 'Tüketilen kayıtlar (sonuca göre)' · Explore → Tempo: { resource.service.name = \"linkly-analytics\" } → sonuç listesinde kök servis"
note "Fark sayıda değil YAPIDA: açıkken tüketici span'i redirect trace'inin bir dalı (kök: redirect);"
note "tuzakla aynı span'ler kendi başlarına birer kök trace olur — ve %5 sampling'i KENDİLERİ"
note "yeniden çektikleri için, örneklenen redirect'lerle örneklenen tüketiciler artık aynı istekler değildir."
note "Kural: bağlam yayılımı bir kütüphane ayarı değil, bir SÖZLEŞMEDİR — HTTP'de header,"
note "Kafka'da message header, cron'da ise... hiçbir yerde. Asenkron sınırları kendin bağlarsın."
if (( on_l + on_o + off_l + off_o == 0 )); then
  warn "iki fazda da Tempo'da tüketici trace'i bulunamadı (tracing açık mı? Alloy OTLP alıcısı kurulu mu?)."
  warn "Bu bir hüküm değil, EKSİK ÖLÇÜMdür."
  exit 2
fi
(( on_l > on_o && off_o > off_l )) \
  && reproduced "bağlam taşınınca tüketici trace'lerinin $on_l/$((on_l + on_o))'i redirect'e bağlı; tuzakla $off_o/$((off_l + off_o))'i yetim kök — trace kuyrukta koptu"
not_reproduced "iki modun yapısı ayrışmadı (açık: bağlı=$on_l yetim=$on_o · tuzak: bağlı=$off_l yetim=$off_o)"
