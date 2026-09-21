#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P09-01 · Read-your-writes: kendi yazdığını okuyamamak
# Okumaları replikaya yönlendirdin. Replika, primary'nin DAHA ÖNCEKİ BİR ANA ait kopyasıdır.
# Bir kullanıcı link oluşturup hemen tıklarsa, okuma henüz o satırı almamış bir replikaya düşebilir
# ve 404 alır — hem de kendi az önce yarattığı link için. Dağıtık sistemlerin en sinsi sınıfı:
# sistem "çalışıyor", yalnızca ZAMAN farklı.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env "$(wl redirect)" TRAP_NO_STICKY- ; kubectl -n \"$NS\" set env "$(wl api)" TRAP_NO_STICKY-"
step "Replikasyon gecikmesi şu an ne kadar?"
lag=$(promq "max(cnpg_pg_replication_lag{namespace=\"$NS\"})")
note "cnpg replikasyon gecikmesi: $(awk -v v="$lag" 'BEGIN{printf "%.3f", v}') sn"
step "(1) Yapışkan okuma AÇIK (varsayılan): oluştur → hemen oku"
k6run read-your-writes --vus 10 --duration 30s || true
v_on=$(promq "sum(increase(ryw_violations_total{namespace=\"$NS\"}[3m]))")
sticky=$(promq "sum(increase(db_sticky_reads_total{namespace=\"$NS\"}[3m]))")
note "ihlal=${v_on%%.*} · primary'ye yapışan okuma=${sticky%%.*}"
step "(2) Yapışkan okumayı KAPAT + replikasyona gecikme enjekte et"
kubectl -n "$NS" set env "$(wl redirect)" TRAP_NO_STICKY=true >/dev/null
kubectl -n "$NS" set env "$(wl api)" TRAP_NO_STICKY=true >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
kubectl -n "$NS" rollout status "$(wl api)" --timeout=180s >/dev/null 2>&1 || true
chaos_apply replica-delay
sleep 8
k6run read-your-writes --vus 10 --duration 30s || true
v_off=$(promq "sum(increase(ryw_violations_total{namespace=\"$NS\"}[3m]))")
k6viol=$(jq -r '.metrics.ryw_violations.count // 0' "$K6_SUMMARY" 2>/dev/null)
grafana_hint "03 · App Business → 'Read-your-writes ihlali' · 05 · Postgres → 'replication lag'"
note "yapışkan KAPALI: ihlal=${v_off%%.*} (k6 tarafı: ${k6viol:-?})"
note "Not: 404 gördüğü an kullanıcı için sistem BOZUKTUR — 'eventual consistency' açıklaması"
note "bir kullanıcıya yapılabilecek en kötü savunmadır."
note "Çözümler ve bedelleri:"
note "  (a) yapışkan okuma (uygulanmış): yazma sonrası N sn primary'den oku → okuma ölçeklenmesinden ödün"
note "  (b) senkron replikasyon: yazma gecikmesi replikanın hızına bağlanır"
note "  (c) LSN takibi: client yazmanın LSN'ini taşır, replika oraya yetişene kadar bekler (en doğru, en karmaşık)"
note "  (d) yeni kaydı önbelleğe yaz: ucuz ama yalnızca önbellek isabetinde çalışır (03'te bilerek yapmamıştık)"
awk -v a="${v_on%%.*}" -v b="${v_off%%.*}" 'BEGIN{exit !(b > a)}' \
  && reproduced "yapışkan okuma kapalıyken RYW ihlali ${v_on%%.*} → ${v_off%%.*} arttı — replika geçmişten okuyor"
not_reproduced "ihlal artışı ölçülemedi (gecikme yeterince büyük olmayabilir: replica-delay chaos uygulandı mı?)"
