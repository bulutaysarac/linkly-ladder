#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P09-01 · Read-your-writes: kendi yazdığını okuyamamak
# Okumaları replikaya yönlendirdin. Replika, primary'nin DAHA ÖNCEKİ BİR ANA ait kopyasıdır.
# Bir kullanıcı link oluşturup hemen tıklarsa, okuma henüz o satırı almamış bir replikaya düşebilir
# ve 404 alır — hem de kendi az önce yarattığı link için. Dağıtık sistemlerin en sinsi sınıfı:
# sistem "çalışıyor", yalnızca ZAMAN farklı.
#
# GECİKMEYİ NASIL ÜRETİYORUZ — ve neden `replica-delay` chaos'u DEĞİL.
# `platform/chaos/replica-delay.yaml` replika pod'unun GÖNDERDİĞİ her paketi 3 sn geciktirir
# (`direction: to`, hedefsiz). Replikanın ALDIĞI WAL gecikmez: veri replikada zamanında uygulanır,
# yani replika BAYAT değil YAVAŞ olur — sorgu cevapları 3 sn geç gelir (3 sn'lik sorgu timeout'unda
# 503), WAL onayları geç gittiği için primary'nin gözünden gecikme ~3 sn görünür, replikanın kendi
# gecikme metriği (`cnpg_pg_replication_lag`) ~0 kalır. Sunucu sayacı zaman aşımlarını da "ihlal"
# saydığı için bu chaos'la karar, k6 tek bir 404 görmeden REPRODUCED çıkar — yanlış arıza ölçülür.
# Burada replikanın WAL UYGULAMASINI duraklatıyoruz (`pg_wal_replay_pause()`): WAL gelmeye devam
# eder ama uygulanmaz — replika gerçekten geçmişte kalır ve gecikme her saniye bir saniye büyür.
# EN: replica-delay delays what the replica SENDS (query answers, WAL acks), not the WAL it
# receives — it makes the replica SLOW, not STALE. Pausing WAL replay makes it genuinely stale.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
replica=$(dep_pod 'cnpg.io/cluster=pg,cnpg.io/instanceRole=replica') || exit 2   # CNPG rolü hazır değilse ölçüm anlamsız
rpsql() { kubectl -n "$NS" exec "$replica" -c postgres -- psql -U postgres -d linkly -tAc "$1" 2>/dev/null; }
on_cleanup "setenv "$(wl redirect)" TRAP_NO_STICKY- ; setenv "$(wl api)" TRAP_NO_STICKY-"
# Duraklatılmış bir replika sonraki HER deneyi bozar: temizlik onu ne olursa olsun devam ettirir.
on_cleanup "rpsql 'SELECT pg_wal_replay_resume()'"

# Faz başına pencere: sabit [3m] iki fazın ortasından geçer ve ikinci faz birincinin sayısını da okur.
phase() {
  local t0 dur
  t0=$(date +%s)
  k6run read-your-writes --vus 10 --duration 30s || true
  sleep 15                                   # uygulama metrikleri 10 sn'de bir kazınıyor
  dur=$(( $(date +%s) - t0 ))
  PH_VIOL=$(promq "sum(increase(ryw_violations_total{namespace=\"$NS\"}[${dur}s]))")
  PH_STICKY=$(promq "sum(increase(db_sticky_reads_total{namespace=\"$NS\"}[${dur}s]))")
  PH_K6=$(jq -r '.metrics.ryw_violations.count // 0' "$K6_SUMMARY" 2>/dev/null || echo 0)
}

step "(1) Yapışkan okuma AÇIK (varsayılan), replika güncel: oluştur → hemen oku"
note "replika: $replica · replay duraklatılmış mı: $(rpsql 'SELECT pg_is_wal_replay_paused()')"
phase
v_on=${PH_VIOL%%.*}; k6_on=$PH_K6
note "ihlal (sunucu)=$v_on · k6'nın gördüğü 404=$k6_on · primary'ye yapışan okuma=${PH_STICKY%%.*}"

step "(2) Yapışkan okumayı KAPAT + replikada WAL uygulamasını DURAKLAT"
setenv "$(wl redirect)" TRAP_NO_STICKY=true >/dev/null
setenv "$(wl api)" TRAP_NO_STICKY=true >/dev/null
settle_rollout "$(wl redirect)"
settle_rollout "$(wl api)"
rpsql 'SELECT pg_wal_replay_pause()' >/dev/null
paused=$(rpsql 'SELECT pg_is_wal_replay_paused()')
if [[ "$paused" != "t" ]]; then
  warn "replikada WAL uygulaması duraklatılamadı (pg_is_wal_replay_paused=${paused:-?}) — gecikme üretilemedi."
  warn "Bu bir hüküm değil, EKSİK ÖLÇÜMdür."
  exit 2
fi
note "replay DURAKLATILDI: replika bu andan itibaren geçmişte kalıyor"
phase
lag_now=$(rpsql "SELECT round(EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp()))")
rpsql 'SELECT pg_wal_replay_resume()' >/dev/null
v_off=${PH_VIOL%%.*}; k6_off=$PH_K6
lag_peak=$(promq "max_over_time(max(cnpg_pg_replication_lag{namespace=\"$NS\"})[3m:30s])")
grafana_hint "03 · App Business → 'Read-your-writes ihlali' · 15 · k6 → 'Senaryoya özel ölçüler' · 05 · Postgres → 'Replikasyon gecikmesi'"
note "yapışkan KAPALI + replika geride: ihlal (sunucu)=$v_off · k6'nın gördüğü 404=$k6_off"
note "replika, duraklatmanın sonunda son uygulanan işlemden ${lag_now:-?} sn geride idi"
note "  (Prometheus'taki tepe cnpg_pg_replication_lag=$(awk -v v="$lag_peak" 'BEGIN{printf "%.0f", v}') sn — 30 sn'de bir kazındığı için daha küçük görünebilir)"
note "Not: 404 gördüğü an kullanıcı için sistem BOZUKTUR — 'eventual consistency' açıklaması"
note "bir kullanıcıya yapılabilecek en kötü savunmadır. Üstelik bu 404 önbelleğe NEGATİF kayıt"
note "olarak yazılır: replika yetişse bile link CACHE_NEGATIVE_TTL boyunca 404 dönmeye devam eder."
note "Çözümler ve bedelleri:"
note "  (a) yapışkan okuma (uygulanmış): yazma sonrası N sn primary'den oku → okuma ölçeklenmesinden ödün"
note "  (b) senkron replikasyon: yazma gecikmesi replikanın hızına bağlanır"
note "  (c) LSN takibi: client yazmanın LSN'ini taşır, replika oraya yetişene kadar bekler (en doğru, en karmaşık)"
note "  (d) yeni kaydı önbelleğe yaz: ucuz ama yalnızca önbellek isabetinde çalışır (03'te bilerek yapmamıştık)"
awk -v a="$v_on" -v b="$v_off" 'BEGIN{exit !(b > a)}' \
  && reproduced "yapışkan okuma kapalı ve replika gerideyken RYW ihlali $v_on → $v_off (k6: $k6_on → $k6_off adet 404) — replika geçmişten okuyor"
not_reproduced "ihlal artışı ölçülemedi (ihlal $v_on → $v_off, k6 404 $k6_on → $k6_off; replika ${lag_now:-?} sn gerideydi) — okumalar replikaya gidiyor mu? (db_reads_routed_total{target=\"replica\"})"
