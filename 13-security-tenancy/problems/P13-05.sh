#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-05 · DNS ile gizlenen iç adresler — ve kapatılamayan TOCTOU boşluğu
# 01'deki kontrol yalnızca URL'deki DÜZ IP'lere bakıyordu. Saldırgan http://10.0.0.1 yazmaz;
# evil.example.com'u 169.254.169.254'e işaret eden bir A kaydıyla kaydeder. Çözümleme bu deliği
# kapatır — ve yerine kaçınılmaz bir yarış bırakır: biz ŞİMDİ çözüyoruz, tarayıcı SONRA çözecek.
APP_SELECTOR="app.kubernetes.io/name=api"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/api TRAP_NO_DNS_CHECK-"
AKEY=${AKEY:-acme-key-9f2c}
try() {
  curl -s -o /dev/null -w '%{http_code}' -XPOST "$BASE_URL/api/links" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $AKEY" -d "{\"url\":\"$1\"}"
}
step "(1) DNS kontrolü AÇIK (varsayılan)"
note "  düz özel IP           → $(try 'http://169.254.169.254/latest/meta-data/')"
note "  localhost             → $(try 'http://localhost:8080/admin')"
note "  özel ağa çözülen ad   → $(try 'http://localtest.me/')   (localtest.me → 127.0.0.1)"
note "  normal public adres   → $(try 'https://example.com/ok')"
step "(2) TRAP_NO_DNS_CHECK: yalnızca düz IP kontrolü (01'deki hâli)"
kubectl -n "$NS" set env deploy/api TRAP_NO_DNS_CHECK=true >/dev/null
kubectl -n "$NS" rollout status deploy/api --timeout=180s >/dev/null 2>&1 || true
sleep 5
trapped=$(try 'http://localtest.me/')
note "  özel ağa çözülen ad   → $trapped  (201 ise kontrol atlatıldı)"
rej=$(promq "sum(increase(create_rejected_unsafe_total{namespace=\"$NS\"}[5m]))")
grafana_hint "14 · Security → 'unsafe URL reddi by reason' (private_address_resolved)"
note "toplam güvenlik reddi: ${rej%%.*}"
note "KAPATILAMAYAN BOŞLUK (TOCTOU): biz oluşturma anında çözüyoruz, tarayıcı tıklama anında"
note "çözecek. Arada DNS kaydı değişebilir — DNS rebinding. Azaltmalar var ve hiçbiri bedava değil:"
note "  · çözülen IP'yi SABİTLE ve yönlendirmede onu kullan (ama CDN/load balancer'ları kırar)"
note "  · yönlendirme anında YENİDEN kontrol et (her redirect'e bir DNS sorgusu — gecikme)"
note "  · egress ağ politikası (uygulama zaten hedefi çekmiyor, ama tarayıcı senin ağında olabilir)"
note "Dürüst ifade: 'riski AZALTTIK', 'yok ettik' değil. Bir güvenlik kontrolünün sınırını"
note "bilmemek, onu hiç yapmamaktan tehlikelidir — çünkü yanlış bir güven duygusu üretir."
{ awk -v r="${rej%%.*}" 'BEGIN{exit !(r>0)}' || [[ "$trapped" == "201" ]]; } \
  && reproduced "DNS çözümü özel adrese işaret eden adları engelledi (${rej%%.*} ret); kontrol kapatılınca aynı adres geçti ($trapped)"
not_reproduced "fark ölçülemedi (API anahtarı ve DNS ayarlarını kontrol et)"
