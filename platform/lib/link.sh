#!/usr/bin/env bash
# make link [URL=…]: kısa link oluştur, yönlendirmeyi dene, ikisinin sonucunu bas.
# Anahtar 13+'da kümeden okunur (apikey.sh); boş dizi deyimi macOS bash 3.2 için (smoke.sh'deki açıklama).
set -euo pipefail
: "${BASE_URL:?}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apikey.sh"
url=${LINK_URL:-https://example.com}

AUTH=(); key=$(ladder_api_key || true)
[[ -n "${key:-}" ]] && AUTH=(-H "Authorization: Bearer $key")

resp=$(curl -s -m 10 -w $'\n%{http_code}' -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' \
  ${AUTH[@]+"${AUTH[@]}"} -d "$(jq -nc --arg u "$url" '{url:$u}')" || true)
st=${resp##*$'\n'}; body=${resp%$'\n'*}; body=${body%$'\n'}
if [[ "$st" != 201 ]]; then
  echo "✘ POST $BASE_URL/api/links → ${st:-000} ${body}"
  case "$st" in
    000|"") echo "  seviyeye ulaşılamadı: make status · kurulu değilse make up · küme durmuşsa cd \"\$LADDER/platform\" && make start" ;;
    401)    echo "  API anahtarı reddedildi: kubectl -n ${NS:-lvlNN} get secret linkly-api-keys" ;;
    400)    echo "  adres kabul edilmedi; tam bir http(s) adresi ver: make link URL=https://example.com" ;;
  esac
  exit 1
fi
code=$(jq -r .code <<<"$body")

get=$(curl -s -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE_URL/$code" || true)
echo "✔ kısa link: $BASE_URL/$code"
echo "  hedef:     $url"
echo "  GET /$code → ${get% *} → ${get#* }"
