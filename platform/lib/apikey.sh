#!/usr/bin/env bash
# Bu seviyede API anahtarı zorunlu mu? Zorunluysa hangisi?
#
# EN: From level 13 on, `POST /api/links` requires `Authorization: Bearer <key>`. Everything that
#     drives the app from outside has to know that: without the key `make up`'s smoke test gets
#     401 and reports "could not create a link", and every k6 scenario that creates links produces
#     a wall of 401s that the scripts read as "the level is broken". The lesson is small and
#     expensive: when you put a gate in front of the app, every tool that is not a browser —
#     smoke tests, load generators, probes, runbooks — is now a client that must authenticate,
#     and each one fails in a way that does not mention authentication.
#     The key is read FROM THE CLUSTER, never hardcoded: the manifest stays the single source.
# TR: 13'ten itibaren `POST /api/links` `Authorization: Bearer <anahtar>` istiyor. Uygulamayı
#     dışarıdan süren her şey bunu bilmek zorunda: anahtar olmadan `make up`'ın smoke testi 401
#     alıp "link oluşturulamadı" der ve link oluşturan her k6 senaryosu, scriptlerin "seviye bozuk"
#     diye okuduğu bir 401 duvarı üretir. Ders küçük ve pahalı: uygulamanın önüne bir kapı
#     koyduğunda, tarayıcı olmayan HER araç — smoke testleri, yük üreteçleri, probe'lar,
#     runbook'lar — artık kimlik doğrulaması gereken bir istemcidir ve her biri, kimlik
#     doğrulamadan HİÇ BAHSETMEYEN bir biçimde başarısız olur.
#     Anahtar KÜMEDEN okunur, koda gömülmez: tek kaynak manifest olarak kalır.
# [Topic · Konu: Kimlik doğrulama, araç zincirinin görünmez istemcileri]
ladder_api_key() {
  local ns=${1:-$NS} spec
  spec=$(kubectl -n "$ns" get secret linkly-api-keys -o jsonpath='{.data.API_KEYS}' 2>/dev/null | base64 -d 2>/dev/null) || return 0
  [[ -z "$spec" ]] && return 0
  # biçim: tenant:tier:key,... → ilk girdinin anahtarı
  printf '%s' "${spec%%,*}" | awk -F: '{print $3}'
}
