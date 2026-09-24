#!/usr/bin/env bash
# POST /api/links → GET /{code} 30x. Ingress'in host'u çözmesi birkaç saniye alabilir → retry.
set -euo pipefail
: "${BASE_URL:?}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apikey.sh"
# 13'ten itibaren yazma ucu kimlik istiyor. Anahtar yoksa AUTH kapalıdır ve başlık boş kalır.
# BOŞ DİZİ + set -u = bash 3.2'de "unbound variable".
# EN: macOS ships bash 3.2, where `"${AUTH[@]}"` on an EMPTY array is an unbound-variable error
#     under `set -u` (bash 4.4+ made it legal). Levels 13 and 14 define API keys, so the array is
#     non-empty and the plain expansion works; below 13 there are no keys, the array is empty,
#     and the plain expansion kills smoke with a message that says nothing about authentication.
#     The safe idiom is `${AUTH[@]+"${AUTH[@]}"}`: expand only if the array is set.
#     A feature that only breaks in the EMPTY case is the kind you ship after testing the full one.
# TR: macOS bash 3.2 ile gelir; orada BOŞ bir dizinin `"${AUTH[@]}"` açılımı `set -u` altında
#     "unbound variable" hatasıdır (bash 4.4+ bunu serbest bıraktı). 13 ve 14 API anahtarı
#     tanımlar, dizi dolu, düz açılım çalışır; 13'ten önce anahtar yok, dizi boş ve düz açılım
#     smoke'u kimlik doğrulamadan HİÇ BAHSETMEYEN bir mesajla öldürür.
#     Güvenli deyim `${AUTH[@]+"${AUTH[@]}"}`: yalnızca dizi tanımlıysa aç.
#     Yalnızca BOŞ durumda kırılan bir özellik, dolu durumu test edip gönderdiğin özelliktir.
AUTH=(); key=$(ladder_api_key || true)
[[ -n "${key:-}" ]] && AUTH=(-H "Authorization: Bearer $key")
for i in $(seq 1 30); do
  code=$(curl -sf -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' ${AUTH[@]+"${AUTH[@]}"} -d '{"url":"https://example.com/smoke"}' 2>/dev/null | jq -r .code 2>/dev/null || true)
  [[ -n "$code" && "$code" != "null" ]] && break
  sleep 2
done
[[ -n "${code:-}" && "$code" != "null" ]] || { echo "smoke: link oluşturulamadı ($BASE_URL)"; exit 1; }
# GET'i de YENİDEN DENE: 09'dan sonra okuma yolu ayrı bir havuzdan (pg-pooler-ro) ve bir
# replikadan geçiyor; yazma hazır olduğunda okuma birkaç saniye daha hazır olmayabiliyor.
# Smoke bir HAZIRLIK KAPISI, ölçüm değil — ilk denemede 503 görüp seviyeyi düşürmek,
# gerçek bir arızayı değil bir yarışı raporlamak olur.
for i in $(seq 1 20); do
  st=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/$code")
  [[ "$st" == 30* ]] && break
  sleep 3
done
[[ "$st" == 30* ]] || { echo "smoke: GET /$code → $st (30x bekleniyordu, 60 sn denendi)"; exit 1; }
echo "smoke ✔  POST /api/links → $code, GET /$code → $st"
