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
out=$(kubectl -n "$NS" run netcheck --image=busybox:1.36 --restart=Never --command --timeout=90s \
      -- sh -c 'nc -z -w 3 pg-pooler-rw 5432 && echo POSTGRES_ERISILEBILIR || echo POSTGRES_ENGELLENDI; nc -z -w 3 redis 6379 && echo REDIS_ERISILEBILIR || echo REDIS_ENGELLENDI' 2>&1)
sleep 12
logs=$(kubectl -n "$NS" logs netcheck 2>/dev/null)
kubectl -n "$NS" delete pod netcheck --ignore-not-found --wait=false >/dev/null 2>&1
note "yetkisiz pod'dan sonuç:"; echo "${logs:-<log alınamadı>}" | sed 's/^/      /'
step "Yetkili bir pod (redirect) aynı şeyi yapabiliyor mu?"
rp=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=redirect -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
note "redirect pod'u zaten DB'ye bağlı (uygulama çalışıyor) → izin listesi doğru"
grafana_hint "14 · Security → 'NetworkPolicy drop'"
note "Varsayılan-reddet, soruyu değiştirir: 'neyi engellemeliyim?' (sonsuz, hep birini kaçırırsın)"
note "yerine 'ne neyle konuşmalı?' (sonlu, gözden geçirilebilir ve mimariyi BELGELER)."
note "Dikkat: NetworkPolicy yalnızca CNI destekliyorsa çalışır — bu cluster Calico kullanıyor."
note "Politika yazıp CNI'ın desteklemediği bir cluster'da çalıştırmak, güvenlik YANILSAMASIDIR."
note "Eksik kalan: egress kuralları. Şu an pod'lar İNTERNETE serbestçe çıkabilir; gerçek bir"
note "sertleştirmede dışarı çıkış da beyaz listelenir (veri sızdırma yolu)."
echo "${logs:-}" | grep -q 'POSTGRES_ENGELLENDI' \
  && reproduced "yetkisiz pod Postgres'e ulaşamadı — varsayılan-reddet + izin listesi çalışıyor"
not_reproduced "yetkisiz pod veritabanına ULAŞABİLDİ (${logs:-log yok}) — NetworkPolicy eksik ya da CNI desteklemiyor"
