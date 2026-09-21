#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-01 · X-Tenant-ID ile kiracı taklidi — ve kimlik doğrulamanın onu nasıl bitirdiği
# On iki seviye boyunca her README büyük harflerle "BU KİMLİK DOĞRULAMA DEĞİLDİR" yazdı.
# Bu script önce eski dünyanın ne kadar kolay kırıldığını, sonra yeni dünyada ne olduğunu gösteriyor.
API_BASE="$BASE_URL"
APP_SELECTOR="app.kubernetes.io/name=api"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env "$(wl api)" TRAP_HEADER_TENANT-"
AKEY=${AKEY:-acme-key-9f2c}
BKEY=${BKEY:-globex-key-3a71}
step "acme kiracısı bir link oluşturuyor (kendi anahtarıyla)"
code=$(curl -s -XPOST "$API_BASE/api/links" -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $AKEY" -d '{"url":"https://example.com/acme-gizli"}' | jq -r '.code // empty')
note "kod: ${code:-<oluşturulamadı>}"
[[ -z "$code" ]] && { warn "link oluşturulamadı — API_KEYS tanımlı mı?"; exit 2; }
step "globex, HEADER ile acme gibi davranmayı deniyor"
spoof=$(curl -s -o /dev/null -w '%{http_code}' -XDELETE "$API_BASE/api/links/$code" \
          -H "Authorization: Bearer $BKEY" -H "X-Tenant-ID: acme")
note "globex anahtarı + X-Tenant-ID: acme → HTTP $spoof (404/403 bekleniyor)"
step "globex, hiç kimlik göndermeden deniyor"
noauth=$(curl -s -o /dev/null -w '%{http_code}' -XDELETE "$API_BASE/api/links/$code")
note "kimliksiz → HTTP $noauth (401 bekleniyor)"
step "TRAP_HEADER_TENANT aç: karar yine header'a dayansın"
kubectl -n "$NS" set env "$(wl api)" TRAP_HEADER_TENANT=true >/dev/null
kubectl -n "$NS" rollout status "$(wl api)" --timeout=180s >/dev/null 2>&1 || true
sleep 5
trapped=$(curl -s -o /dev/null -w '%{http_code}' -XDELETE "$API_BASE/api/links/$code" -H "X-Tenant-ID: acme")
note "tuzakla (yalnızca header) → HTTP $trapped (204 ise link SİLİNDİ: taklit başarılı)"
grafana_hint "14 · Security → '401 / 403 /s' + 'İstek / tenant'"
note "Kimlik doğrulama KODU tuzakta da duruyordu — değişen tek şey KARARIN neye dayandığıydı."
note "Ders: bir sınır, karşılaştırdığı değeri ayarlayabilen EN ZAYIF şey kadar güçlüdür."
note "Bu yüzden 'kiracıyı nereden alıyoruz?' sorusu bir uygulama detayı değil, bir GÜVENLİK sınırıdır."
{ [[ "$spoof" != "204" ]] && [[ "$noauth" == "401" ]]; } \
  && reproduced "kimlik doğrulama header taklidini engelledi (spoof=$spoof, kimliksiz=$noauth); tuzak açıkken taklit $trapped ile geçti"
not_reproduced "kiracı sınırı kimliğe bağlı görünmüyor (spoof=$spoof, kimliksiz=$noauth)"
