#!/usr/bin/env bash
# Yük testi kimliği (08+): jeton ve hız sınırı olmayan giriş — ikisi de KÜMEDEN okunur.
#
# EN: From level 08 on, the public ingress carries two limiters (nginx 400 rps answering 503,
#     the app's 30 rps per IP). Every load experiment in this ladder comes from ONE client IP, so
#     through the public entrance it measures the limiters, not the system: availability drops to
#     a few percent while the application itself returns almost no errors. Load goes to the
#     `linkly-load` ingress with the token from `linkly-loadtest`; scripts that TEST the limiters
#     call `limits_enforced` (repro.sh) and stay on the public entrance without the token.
#     Both values come from the level's manifest, never from here: an empty answer means "this
#     level has no load entrance" (before 08) and the public entrance is used unchanged.
# TR: 08'den itibaren herkese açık ingress'te iki limiter var (nginx 400 rps ve 503 döner,
#     uygulama IP başına 30 rps). Merdivendeki her yük deneyi TEK bir istemci IP'sinden gelir; bu
#     yüzden herkese açık girişten geçen deney sistemi değil limiter'ları ölçer: erişilebilirlik
#     yüzde birkaça düşer, uygulama ise neredeyse hiç hata dönmez. Yük `linkly-load`
#     ingress'ine, `linkly-loadtest` Secret'ındaki jetonla gider; limiter'ları SINAYAN scriptler
#     `limits_enforced` (repro.sh) çağırır ve jetonsuz, herkese açık girişte kalır.
#     İki değer de seviyenin manifest'inden gelir, buradan değil: boş cevap "bu seviyenin yük
#     girişi yok" (08 öncesi) demektir ve herkese açık giriş olduğu gibi kullanılır.
# [Topic · Konu: Ölçüm, yük testinin kimliği]
ladder_loadtest_token() {
  local ns=${1:-$NS}
  kubectl -n "$ns" get secret linkly-loadtest -o jsonpath='{.data.LOADTEST_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true
}
ladder_load_url() {
  local ns=${1:-$NS} host
  host=$(kubectl -n "$ns" get ingress linkly-load -o jsonpath='{.spec.rules[0].host}' 2>/dev/null) || true
  [[ -n "$host" ]] && printf 'http://%s' "$host"
  return 0
}
