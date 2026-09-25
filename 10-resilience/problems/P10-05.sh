#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-05 · Yavaş bir bağımlılık, ölü bir bağımlılıktan BETERDİR
# Ölü bağımlılık hızlı hata verir: bağlantı reddedilir, istek biter. Yavaş bağımlılık ise her
# isteği bekletir: goroutine'ler, bağlantılar ve bellek birikir. Sistem "çalışıyor" görünür ve
# yavaşça boğulur. Timeout'suz bir çağrı, sınırsız bir kuyruktur (P05-02'nin bağımlılık hâli).
#
# TUZAK NEYİ KALDIRIYOR — ve neden İKİ süre sınırını birden.
# Bir Redis çağrısının iki süre sınırı var: guard'ın 2 sn'lik timeout'u ve Redis istemcisinin kendi
# 500 ms'lik soket süre sınırları. Yalnızca guard'ınki kalksa `redis-delay-3s` altında her çağrı
# İKİ fazda da 0,5 sn'de düşer ve "timeout'suz" yol hiç sınanmaz. Bu yüzden TRAP_NO_DEP_TIMEOUT
# istemcinin süre sınırlarını da kaldırır (cmd/*/main.go) ve Redis kendi guard'ının (dep="redis")
# arkasındadır: timeout VARKEN çağrılar 0,5 sn'de düşer, Redis devresi açılır ve istekler önbelleği
# atlayıp DB'ye gider (degrade "no_cache"). Timeout YOKKEN çağrılar ~3 sn sürer ve BAŞARILI olur —
# devre kesici için yavaş bir cevap hata değildir, yani o da kördür.
# EN: a Redis call has two deadlines — the guard's timeout and the Redis client's own 500 ms socket
# deadline. Removing only the first leaves the second cutting every call, so the "no timeout" path
# is never exercised. The trap removes both.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRAP_NO_DEP_TIMEOUT-"
# GECİKME HER FAZIN POD'LARINA AYRICA UYGULANIR. redis-delay-3s yalnızca Redis'ten uygulama pod'larına
# giden paketleri yavaşlatır ve Chaos Mesh hedef pod'ları enjeksiyon anında sabitler: tuzak açılınca
# yeniden başlayan pod'lar eski enjeksiyonun hedefinde değildir. Bu yüzden gecikme, fazın pod'ları
# kalktıktan sonra yeniden uygulanır.
# EN: the delay targets application pods and Chaos Mesh fixes its targets at injection time, so it is
#     re-applied after the trap phase's pods are up.

# Faz başına pencere: sabit [3m] ikinci fazda birincinin tepesini de okur.
run_phase() {
  local t0 dur
  t0=$(date +%s)
  # SABİT GELİŞ HIZI (steady, açık model). Kapalı döngüde (N sanal kullanıcı) her kullanıcı cevabı
  # bekler: servis yavaşlayınca istek de yavaşlar ve eşzamanlı istek N'i hiç geçemez — birikim
  # ölçülemez. Gerçek trafik sen yavaşladın diye yavaşlamaz: eşzamanlı istek ≈ geliş hızı × gecikme.
  # EN: a closed model caps concurrency at N VUs; real traffic keeps arriving, so in-flight grows
  #     as rate × latency — that growth is the failure mode measured here.
  RATE=${RATE:-60} k6run steady --duration 45s >/dev/null 2>&1 || true
  sleep 15                                   # uygulama metrikleri 10 sn'de bir kazınıyor
  dur=$(( $(date +%s) - t0 ))
  PH_G=$(promq "max_over_time(sum(go_goroutines{namespace=\"$NS\",pod=~\"redirect.*\"})[${dur}s:10s])")
  PH_M=$(peak_working_set_mb "${dur}s")
  PH_INF=$(promq "max_over_time(sum(http_in_flight_requests{namespace=\"$NS\",pod=~\"redirect.*\"})[${dur}s:10s])")
  PH_P99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\",route=\"/{code}\"}[${dur}s])) by (le))")
  PH_R99=$(promq "histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{namespace=\"$NS\",dep=\"redis\"}[${dur}s])) by (le))")
  PH_CUT=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"redis\",result=~\"timeout|open\"}[${dur}s]))")
}
ms() { awk -v v="$1" 'BEGIN{printf "%.0f", v*1000}'; }

step "(1) Timeout VAR (varsayılan): Redis çağrısı 500 ms'de kesilir — Redis'e 3 sn gecikme (ölmedi, YAVAŞLADI)"
chaos_apply redis-delay-3s
sleep 5
run_phase
g_on=${PH_G%%.*}; m_on=$PH_M; inf_on=${PH_INF%%.*}; p99_on=$PH_P99; r99_on=$PH_R99; cut_on=${PH_CUT%%.*}
note "timeout var: tepe goroutine=$g_on · tepe bellek=${m_on}MB · tepe in-flight=$inf_on · redirect p99=$(ms "$p99_on") ms"
note "  Redis çağrısı p99=$(ms "$r99_on") ms · kesilen/devre-açık Redis çağrısı=$cut_on"

step "(2) TRAP_NO_DEP_TIMEOUT: guard'da VE Redis istemcisinde süre sınırı yok"
chaos_cleanup redis-delay-3s
setenv "$(wl redirect)" TRAP_NO_DEP_TIMEOUT=true >/dev/null
settle_rollout "$(wl redirect)"
chaos_apply redis-delay-3s
sleep 5
run_phase
g_off=${PH_G%%.*}; m_off=$PH_M; inf_off=${PH_INF%%.*}; p99_off=$PH_P99; r99_off=$PH_R99; cut_off=${PH_CUT%%.*}
restarts=$(restarts)
grafana_hint "01 · Pods & Resources → 'Goroutine sayısı' + 'Bellek kullanımı' · 11 · Resilience → 'Şu an işlenen istek (pod'a göre)' + 'Bağımlılık gecikmesi p99'"
note "timeout yok: tepe goroutine=$g_off · tepe bellek=${m_off}MB · tepe in-flight=$inf_off · redirect p99=$(ms "$p99_off") ms · restart=$restarts"
note "  Redis çağrısı p99=$(ms "$r99_off") ms · kesilen/devre-açık Redis çağrısı=$cut_off"
note "Okuma: timeout varken Redis çağrıları 0,5 sn'de kesilir, Redis devresi açılır ve istekler"
note "önbelleği atlayıp DB'den hızlıca döner (degrade no_cache) — ölü bir bağımlılık gibi. Timeout"
note "yokken her çağrı ~3 sn bekler ve BAŞARIYLA biter: devre kesici yavaşlığı hata saymaz, açılmaz."
note "Birikimi sınırlayan artık yalnızca bulkhead (pod başına DEP_MAX_CONCURRENT eşzamanlı Redis"
note "çağrısı); o da olmasa sınır, istemcinin sabrı olurdu."
note "Kural: bir bağımlılığa yapılan HER çağrının bir süre sınırı olmalı; 'genelde hızlıdır'"
note "bir gerekçe değildir, çünkü sorun tam da 'genelde' olmadığı anda başlar."
# Tuzak GERÇEKTEN timeout'u kaldırdı mı? Kaldırmadıysa iki faz da aynı sistemi ölçer — hüküm yok.
if ! awk -v a="$r99_on" -v b="$r99_off" 'BEGIN{exit !(b > 1 && b > a)}'; then
  warn "timeout'suz faz Redis çağrılarını uzatmadı (p99 $(ms "$r99_on") → $(ms "$r99_off") ms): tuzak etkili değil ya da chaos enjekte edilmedi."
  warn "Bu bir hüküm değil, EKSİK ÖLÇÜMdür."
  exit 2
fi
# KARAR TUZAĞI: ">=" / "<=" iki taraf da 0 iken GEÇER.
# EN: "b >= a" is true when nothing was measured at all (0 >= 0). That turns a failed measurement
#     into a passing experiment — the loudest possible false positive, because it looks like proof.
#     Guard the comparison with "we actually measured something".
# TR: "b >= a", hiçbir şey ölçülmediğinde de doğrudur (0 >= 0). Yani başarısız bir ölçüm, GEÇEN
#     bir deneye dönüşür — mümkün olan en gürültülü yanlış pozitif, çünkü kanıt gibi görünür.
#     Karşılaştırmayı "gerçekten bir şey ölçtük mü?" koşuluyla koru.
#     Aynı sebeple ">=" de yetmez: eşitlikte HİÇ BÜYÜME YOKTUR, oysa hüküm "büyüttü" diyor.
# EN: ">=" is not enough either — at equality nothing grew, yet the verdict says it did.
#     Assert growth only if you measured growth.
awk -v a="$g_on" -v b="$g_off" 'BEGIN{exit !(a > 0 && b > 0 && b > a)}' \
  && reproduced "timeout'suz yavaş bağımlılık goroutine'leri $g_on → $g_off ve in-flight'ı $inf_on → $inf_off büyüttü (Redis çağrısı p99 $(ms "$r99_on") → $(ms "$r99_off") ms · tepe bellek ${m_on} → ${m_off} MB)"
not_reproduced "goroutine birikimi ölçülemedi ($g_on → $g_off) — Redis çağrıları uzadı ama istekler birikmedi"
