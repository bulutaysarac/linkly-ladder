#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-03 · Varsayılan-reddet ağ: her pod veritabanına ulaşabiliyor mu?
# Kubernetes'in varsayılanı "herkes herkesle konuşabilir"dir. Ele geçirilmiş bir sidecar,
# yanlış yapılandırılmış bir job ya da meraklı bir debug konteyneri doğrudan Postgres'e bağlanabilir.
ensure_healthy
step "Tanımlı NetworkPolicy'ler"
kubectl -n "$NS" get networkpolicy --no-headers 2>/dev/null | awk '{print "    " $1}' || note "    (yok)"
step "Yetkisiz bir pod'dan Postgres'e bağlanmayı dene"
kubectl -n "$NS" delete pod netcheck --ignore-not-found --wait=true >/dev/null 2>&1
# TEST POD'U DA POLİTİKAYA UYMAK ZORUNDA.
# EN: the first version ran a plain `kubectl run busybox`. This level's own Kyverno policy
#     (memory limit + readinessProbe required) DENIED it, `kubectl run` returned non-zero and
#     `set -e` killed the script before it measured anything. The security test was blocked by
#     the security policy. That is not a bug in the policy — it is the policy working, and it is
#     the second time tonight this level stopped its own tooling (the first was CNPG's bootstrap
#     Job). The lesson generalises: after you install a gate, every tool you own becomes a client
#     of that gate, including the ones that test it.
# TR: ilk hâl düz bir `kubectl run busybox` koşuyordu. Bu seviyenin KENDİ Kyverno politikası
#     (bellek limiti + readinessProbe zorunlu) onu REDDETTİ, `kubectl run` sıfırdan farklı döndü
#     ve `set -e` scripti hiçbir şey ölçmeden öldürdü. Güvenlik testini güvenlik politikası
#     engelledi. Bu politikanın hatası değil, politikanın ÇALIŞMASIDIR — ve bu seviyenin kendi
#     araçlarını durdurmasının bu gece ikinci örneği (ilki CNPG'nin bootstrap Job'ıydı).
#     Genel ders: bir kapı koyduktan sonra sahip olduğun her araç o kapının müşterisi olur —
#     onu test edenler dahil.
ov='{"spec":{"containers":[{"name":"netcheck","image":"busybox:1.36","command":["sh","-c","nc -z -w 3 pg-pooler-rw 5432 && echo POSTGRES_ERISILEBILIR || echo POSTGRES_ENGELLENDI; nc -z -w 3 redis 6379 && echo REDIS_ERISILEBILIR || echo REDIS_ENGELLENDI"],"resources":{"limits":{"memory":"64Mi"}},"readinessProbe":{"exec":{"command":["true"]}}}]}}'
out=$(kubectl -n "$NS" run netcheck --image=busybox:1.36 --restart=Never --timeout=90s \
      --overrides="$ov" 2>&1) || true
printf '%s' "$out" | grep -qi 'denied\|blocked' && { warn "test pod'u admission tarafından reddedildi: $(printf '%s' "$out" | head -c 200)"; exit 2; }
# SABİT BEKLEME YERİNE POD'UN BİTMESİNİ BEKLE.
# EN: the first version slept 12s and read the logs. On a busy node the image pull alone can take
#     longer, so the logs came back EMPTY and the verdict read that as "the unauthorised pod
#     reached the database" — the exact opposite of what happened. An empty measurement is not a
#     negative measurement; wait for the thing you are measuring to actually finish.
# TR: ilk hâl 12 sn uyuyup log'u okuyordu. Yoğun bir node'da yalnızca imaj çekme bile daha uzun
#     sürebiliyor, log BOŞ dönüyor ve karar bunu "yetkisiz pod veritabanına ulaştı" diye okuyordu
#     — olanın tam tersi. Boş bir ölçüm, OLUMSUZ bir ölçüm değildir; ölçtüğün şeyin gerçekten
#     bitmesini bekle.
logs=""
for _ in $(seq 1 45); do
  ph=$(kubectl -n "$NS" get pod netcheck -o jsonpath='{.status.phase}' 2>/dev/null) || true
  case "${ph:-}" in Succeeded|Failed) break ;; esac
  sleep 2
done
logs=$(kubectl -n "$NS" logs netcheck 2>/dev/null) || true
[[ -z "${logs:-}" ]] && { warn "netcheck pod'u çıktı üretmedi (faz: ${ph:-yok}) — ölçüm yapılamadı"; exit 2; }
kubectl -n "$NS" delete pod netcheck --ignore-not-found --wait=false >/dev/null 2>&1
note "yetkisiz pod'dan sonuç:"; echo "${logs:-<log alınamadı>}" | sed 's/^/      /'
step "Yetkili bir pod (redirect) aynı şeyi yapabiliyor mu?"
rp=$(dep_pod app.kubernetes.io/name=redirect) || exit 2   # bağımlılık hazır değilse ölçüm anlamsız
note "redirect pod'u zaten DB'ye bağlı (uygulama çalışıyor) → izin listesi doğru"
grafana_hint "14 · Security → 'NetworkPolicy drop'"
note "Varsayılan-reddet, soruyu değiştirir: 'neyi engellemeliyim?' (sonsuz, hep birini kaçırırsın)"
note "yerine 'ne neyle konuşmalı?' (sonlu, gözden geçirilebilir ve mimariyi BELGELER)."
note "Dikkat: NetworkPolicy yalnızca CNI destekliyorsa çalışır — bu cluster Calico kullanıyor."
note "Politika yazıp CNI'ın desteklemediği bir cluster'da çalıştırmak, güvenlik YANILSAMASIDIR."
note "Eksik kalan: egress kuralları. Şu an pod'lar İNTERNETE serbestçe çıkabilir; gerçek bir"
note "sertleştirmede dışarı çıkış da beyaz listelenir (veri sızdırma yolu)."
{ echo "${logs:-}" | grep -q 'POSTGRES_ENGELLENDI'; } \
  && reproduced "yetkisiz pod Postgres'e ulaşamadı — varsayılan-reddet + izin listesi çalışıyor"
not_reproduced "yetkisiz pod veritabanına ULAŞABİLDİ (${logs:-log yok}) — NetworkPolicy eksik ya da CNI desteklemiyor"
