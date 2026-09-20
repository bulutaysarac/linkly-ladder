#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-01 · Silinen link diğer pod'larda TTL boyunca yaşamaya devam ediyor
# Her pod'un kendi önbelleği var. DELETE isteği YALNIZCA bir pod'a düşüyor; o pod kendi kopyasını
# temizliyor, diğer N-1 pod hiçbir şey duymuyor. Kullanıcı "sildim" diyor, link hâlâ çalışıyor.
ensure_healthy
reps=$(replicas_of)
ttl=$(kubectl -n "$NS" get deploy linkly -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="CACHE_TTL")]}{.value}{end}')
step "Bir link oluştur ve TÜM pod'ların önbelleğine girmesini sağla"
code=$(create_link "https://example.com/silinecek")
for i in $(seq 1 $(( reps * 12 ))); do status_of "$code" >/dev/null; done
note "kod=$code · replika=$reps · CACHE_TTL=${ttl:-60s} — artık her pod'un belleğinde bir kopya var"
step "Linki SİL (istek yalnızca bir pod'a düşer)"
curl -s -o /dev/null -XDELETE "$BASE_URL/api/links/$code"
db_gone=$(status_of "yoxxxxx")
step "Silmeden hemen sonra 60 kez oku — kaçı hâlâ yönlendiriyor?"
alive=0; tot=60
for i in $(seq 1 $tot); do [[ "$(status_of "$code")" == 30* ]] && alive=$((alive+1)); done
sleep 12
hitpods=$(curl -sG "$PROM_URL/api/v1/query" --data-urlencode \
  "query=count(count by (pod) (cache_ops_total{namespace=\"$NS\",result=\"hit\"}))" | jq -r '.data.result[0].value[1] // "0"')
grafana_hint "04 · Cache → 'hit ratio by pod' · 03 · App Business → 'redirect sonuçları'"
note "$tot okumadan $alive tanesi HÂLÂ yönlendiriyor (~%$(( alive * 100 / tot ))) — silinmiş bir linke"
note "önbellek tutan pod sayısı: ${hitpods%%.*} · beklenen süre: TTL dolana kadar (${ttl:-60s})"
note "Veritabanında kayıt YOK; gerçeğin N kopyası var ve N-1'i yanlış."
note "Çözüm yönü: (a) önbelleği PAYLAŞ (04, Redis) — geçersiz kılma tek yerde olur,"
note "            (b) ya da yayın yap (pub/sub): her pod'a 'bu anahtarı at' de. Kopya tutan herkes bir kanal borçlanır."
(( alive > 0 )) && reproduced "$alive/$tot istek silinmiş linke yönlendirdi — yerel önbellek geçersiz kılınamıyor"
not_reproduced "silme anında tüm pod'larda etkili oldu — paylaşılan önbellek (04)"
