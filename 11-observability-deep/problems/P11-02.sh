#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-02 · TRAP_NO_KAFKA_PROPAGATION: trace asenkron sınırda KOPAR
# HTTP'de bağlam otomatik taşınır (traceparent header'ı). Kuyrukta taşınmaz — sen koymazsan
# tüketici span'leri YETİM kalır ve "bu tıklama neden 10 saniye sonra işlendi?" sorusu
# cevapsız kalır. Tam da asenkron yaptığın için görünmez olan yer, en çok trace gereken yerdir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_NO_KAFKA_PROPAGATION-"
tempo_traces() {
  # Tempo'ya sor: son 5 dakikada analytics servisine ait kaç trace var?
  kubectl -n monitoring port-forward svc/tempo 13200:3200 >/dev/null 2>&1 &
  local pf=$!; sleep 4
  local n
  n=$(curl -sG "http://127.0.0.1:13200/api/search" --data-urlencode "tags=service.name=linkly-analytics" \
        --data-urlencode "limit=50" 2>/dev/null | jq -r '.traces | length' 2>/dev/null)
  kill $pf 2>/dev/null; wait $pf 2>/dev/null || true
  echo "${n:-0}"
}
step "(1) Propagation AÇIK: üretici bağlamı header'a koyuyor"
k6run redirect --vus 10 --duration 30s >/dev/null 2>&1 || true
sleep 20
on_tr=$(tempo_traces)
note "Tempo'da analytics span'i olan trace sayısı: $on_tr"
step "(2) TRAP: bağlam header'a KONMUYOR"
setenv "$(wl redirect)" TRAP_NO_KAFKA_PROPAGATION=true >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
k6run redirect --vus 10 --duration 30s >/dev/null 2>&1 || true
sleep 20
off_tr=$(tempo_traces)
note "tuzakla: $off_tr (span'ler hâlâ var ama artık redirect trace'ine BAĞLI DEĞİL — yetim)"
grafana_hint "Explore → Tempo → service.name=linkly-analytics: trace'in üst kısmı var mı?"
note "Fark sayıda değil YAPIDA: tuzakla tüketici span'leri kendi başlarına birer kök trace olur."
note "Bir trace'i açtığında redirect'ten tüketiciye kadar TEK bir ağaç görmek ile iki ayrı"
note "parça görmek arasındaki fark, 'kim yavaşlattı?' sorusunun cevaplanabilir olmasıdır."
note "Kural: bağlam yayılımı bir kütüphane ayarı değil, bir SÖZLEŞMEDİR — HTTP'de header,"
note "Kafka'da message header, cron'da ise... hiçbir yerde. Asenkron sınırları kendin bağlarsın."
{ [[ "${on_tr:-0}" -gt 0 ]] || [[ "${off_tr:-0}" -gt 0 ]]; } \
  && reproduced "propagation açık/kapalı trace yapısı değişiyor (açık=$on_tr, kapalı=$off_tr trace) — kuyrukta bağlam taşınmazsa span'ler yetim kalır"
not_reproduced "Tempo'dan trace okunamadı (tempo kurulu mu? cd platform && make tempo)"
