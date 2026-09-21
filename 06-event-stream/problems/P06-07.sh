#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-07 · Şema evrimi: yeni sürüm bir olay yazdığında eski tüketici ne yapıyor?
# Üretici ve tüketici AYRI dağıtılır; bir an gelir ikisi farklı sürümdedir. Tüketici bilmediği
# bir sürümde PATLARSA, üreticinin tek satırlık bir değişikliği tüm analitiği durdurur.
ensure_healthy
rp=$(dep_pod app.kubernetes.io/name=redpanda) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
code=$(create_link "https://example.com/schema")
before=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
step "Geleceğin sürümünden bir olay bas (v=99, bilinmeyen alanlar)"
future='{"v":99,"event_id":"future-1","code":"'"$code"'","at":"2030-01-01T00:00:00Z","new_field":{"nested":true},"another":42}'
kubectl -n "$NS" exec "$rp" -- sh -c "echo '$future' | rpk topic produce clicks" >/dev/null 2>&1 || true
step "Ardından normal tıklamalar — eski tüketici bunları işleyebilmeli"
N=${N:-150}
for i in $(seq 1 "$N"); do status_of "$code" >/dev/null; done
sleep 20
after=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
unknown=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"unknown_version\"}[10m]))")
restarts=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=analytics -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null) || true
grafana_hint "08 · Stream → 'consumer records by result' (unknown_version)"
note "bilinmeyen sürüm sayacı: ${unknown%%.*} · tüketici restart: ${restarts:-0}"
note "sonraki normal tıklamalar: $(( after - before )) / $N (boru hattı akmaya devam etti mi?)"
note "Tüketici v99'u ATLADI ve SAYDI — patlamadı. Bu, şema evriminin birinci kuralıdır:"
note "  tüketici bilmediği alanları yok saymalı, bilmediği SÜRÜMÜ ise görünür biçimde atlamalı."
note "İkinci kural: alan SİLME ve alan ANLAMI DEĞİŞTİRME geriye dönük uyumsuzdur; yeni alan eklemek uyumludur."
note "Üçüncü kural: üreticiyi yeni sürüme geçirmeden ÖNCE tüketicileri hazırla (sıra önemlidir)."
note "Daha güçlü çözüm: şema kayıt defteri (Schema Registry) + uyumluluk kuralları — 14'te opsiyonel."
{ awk -v u="${unknown%%.*}" 'BEGIN{exit !(u>0)}' && (( after - before > 0 )); } \
  && reproduced "bilinmeyen sürüm (${unknown%%.*} kayıt) atlandı, tüketici çökmedi ve $(( after - before ))/$N normal olay işlendi"
not_reproduced "bilinmeyen sürüm etkisi ölçülemedi (rpk produce çalışmamış olabilir)"
