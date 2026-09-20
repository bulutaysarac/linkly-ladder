#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-06 · Giriş doğrulaması yok: tehlikeli şema, iç ağ adresi, dev body
ensure_healthy
bad=0
step "javascript: şeması kabul ediliyor mu?"
c=$(create_link "javascript:alert(1)"); loc=$(header_of "$c" Location)
note "kod=$c → Location: ${loc:-<yok>}"
[[ "$loc" == javascript:* ]] && { warn "KABUL EDİLDİ — open redirect / XSS yüzeyi"; bad=1; }

step "iç ağ / metadata adresi kabul ediliyor mu?"
c=$(create_link "http://169.254.169.254/latest/meta-data/"); loc=$(header_of "$c" Location)
note "kod=$c → Location: ${loc:-<yok>}"
[[ "$loc" == *169.254.169.254* ]] && { warn "KABUL EDİLDİ — güvenilir görünen link tarayıcıyı iç adrese yollar"; bad=1; }

step "boş ve bozuk URL kabul ediliyor mu?"
for u in "" "not-a-url" "   "; do
  c=$(create_link "$u")
  [[ -n "$c" && "$c" != null ]] && { warn "KABUL EDİLDİ: '<$u>' → kod $c"; bad=1; }
done

step "Büyük gövde: önce ingress üzerinden, sonra DOĞRUDAN pod'a"
big=$(mktemp); { printf '{"url":"https://e.com/'; head -c 5000000 /dev/zero | tr '\0' 'a'; printf '"}'; } > "$big"
via_ing=$(curl -s -o /dev/null -w '%{http_code}' -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' --data-binary @"$big")
note "ingress üzerinden 5 MB → HTTP $via_ing"
[[ "$via_ing" == 413 ]] && note "413'ü UYGULAMA değil ingress-nginx verdi (varsayılan proxy-body-size: 1m). Koruma tasarlamadığın bir katmandan geldi — buna güvenemezsin."
# Uygulamanın kendi davranışı: ingress'i atlayıp doğrudan pod'a git.
pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=linkly -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" port-forward "pod/$pod" 18080:8080 >/dev/null 2>&1 &
pf=$!; sleep 3
direct=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -XPOST "http://127.0.0.1:18080/api/links" -H 'Content-Type: application/json' --data-binary @"$big")
kill $pf 2>/dev/null; wait $pf 2>/dev/null; rm -f "$big"
note "doğrudan pod'a 5 MB → HTTP $direct (uygulamanın kendi cevabı)"
[[ "$direct" == 201 ]] && { warn "Uygulama 5 MB'ı belleğe aldı — MaxBytesReader yok"; bad=1; }

grafana_hint "14 · Security → 'unsafe URL reddi' (00'da hep 0 — hiçbir şey reddedilmiyor) · 01 · Pods & Resources → working set sıçraması"
(( bad )) && reproduced "doğrulama yok: tehlikeli hedefler, bozuk URL'ler ve sınırsız gövde kabul ediliyor"
not_reproduced "girişler doğrulanıyor (01)"
