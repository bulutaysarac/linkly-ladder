#!/usr/bin/env bash
# POST /api/links → GET /{code} 30x. Ingress'in host'u çözmesi birkaç saniye alabilir → retry.
set -euo pipefail
: "${BASE_URL:?}"
for i in $(seq 1 30); do
  code=$(curl -sf -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' -d '{"url":"https://example.com/smoke"}' 2>/dev/null | jq -r .code 2>/dev/null || true)
  [[ -n "$code" && "$code" != "null" ]] && break
  sleep 2
done
[[ -n "${code:-}" && "$code" != "null" ]] || { echo "smoke: link oluşturulamadı ($BASE_URL)"; exit 1; }
# GET'i de YENİDEN DENE: 09'dan sonra okuma yolu ayrı bir havuzdan (pg-pooler-ro) ve bir
# replikadan geçiyor; yazma hazır olduğunda okuma birkaç saniye daha hazır olmayabiliyor.
# Smoke bir HAZIRLIK KAPISI, ölçüm değil — ilk denemede 503 görüp seviyeyi düşürmek,
# gerçek bir arızayı değil bir yarışı raporlamak olur (09 gece turunda tam olarak böyle düştü).
for i in $(seq 1 20); do
  st=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/$code")
  [[ "$st" == 30* ]] && break
  sleep 3
done
[[ "$st" == 30* ]] || { echo "smoke: GET /$code → $st (30x bekleniyordu, 60 sn denendi)"; exit 1; }
echo "smoke ✔  POST /api/links → $code, GET /$code → $st"
