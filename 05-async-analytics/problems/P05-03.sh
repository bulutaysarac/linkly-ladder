#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P05-03 · Analitik yazıcısı redirect ile AYNI süreçte ve AYNI bağlantı havuzunda
# Yazma istek yolundan çıktı ama SÜREÇTEN çıkmadı: aynı pod'un CPU'sunu, aynı bağlantı havuzunu
# ve aynı veritabanını paylaşıyor. Yani izolasyon kısmi.
#
# ÖLÇÜM NOTU — karşılaştırma TEK DEĞİŞKENLİ olmalı.
# İki faz AYNI yükü (hot-key, 80 VU, 45 sn) taze pod'larla koşar; değişen TEK şey yazıcının
# veritabanı işi. Senaryo ya da yük de değişseydi p99'daki fark yazıcıdan mı yükten mi geldi, ayırt
# edilemezdi; "yalnız okuma" tabanı da kendiliğinden olmaz, çünkü her redirect bir tıklamadır. A
# fazında flush aralığı 1 saate, parti boyu 100 milyona çekilir: tıklamalar yine kuyruğa girip
# toplanır (Record() ve toplama maliyeti aynı), yalnızca DB'ye YAZILMAZ. B varsayılan.
# Havuz beklemesi pgx'in her bağlantı alımının etrafında ölçülür (internal/store/postgres.go ·
# acquireTracer); iki fazın bekleme p99'u havuzun gerçek durumunu gösterir.
# Hüküm yapısal: B'de write_clicks sorguları redirect'i servis eden pod'lardan — onların havuzundan —
# çıkıyor mu, ve A'da sıfırlanıyor mu (ayırdığımız şey gerçekten yazıcı mı)? 06'da yazıcı ayrı bir
# deployment olunca uygulama pod'larından çıkan write_clicks iki fazda da sıfırdır.
# Bedel (redirect p99, havuz bekleme p99) iki faz için basılır ama hükme BAĞLANMAZ: okumalar Redis'ten
# dönüyor ve yazıcı pod başına tek bir bağlantı tutuyor; bu ölçekte fark gürültü mertebesinde
# kalabilir ve gürültüye hüküm bağlamak, düşemeyen bir deney kurmanın öbür yüzüdür (bkz. P14-01).
# EN: both phases run the same load on fresh pods and the only difference is the writer's database
#     work (paused in A, on in B); changing scenario or load as well would make any p99 difference
#     unattributable. The verdict is structural — do the redirect pods issue write_clicks through
#     their own pool in B, and does that stop in A? — while the cost (p99, pool wait) is printed
#     but not judged, because at this scale it may be noise.
ensure_healthy
PHASE=${PHASE:-45s}
on_cleanup "setenv $(app_workload) ANALYTICS_FLUSH_INTERVAL- ANALYTICS_BATCH_SIZE-"

# Bu fazın pod'ları: yalnızca TAZE, hazır uygulama pod'ları. Ölçü onlarla sınırlanır, yoksa önceki fazın
# ölen pod'larının son yazmaları pencereye sızar.
phase_pods() {
  kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$(app_name)" -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)
              | select(any(.status.containerStatuses[]?; .ready)) | .metadata.name] | join("|")'
}
# Faz ölçüsü → "p99 acq wq batch" (saniye, saniye, sorgu/s, saniye)
read_phase() {
  local sel="namespace=\"$NS\",pod=~\"$1\"" p99 acq wq batch
  p99=$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{$sel,route=\"/{code}\"}[1m])) by (le))")
  acq=$(promq "histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{$sel}[1m])) by (le))")
  wq=$(promq "sum(rate(db_queries_total{$sel,op=\"write_clicks\"}[1m]))")
  batch=$(promq "histogram_quantile(0.99, sum(rate(analytics_batch_duration_seconds_bucket{$sel}[1m])) by (le))")
  printf '%s %s %s %s\n' "$p99" "$acq" "$wq" "$batch"
}
ms() { awk -v v="$1" 'BEGIN{printf "%.2f", v * 1000}'; }

step "A · yazıcının DB işi DURDURULDU (flush 1 sa, parti 100 M) — aynı yük: hot-key 80 VU, $PHASE"
setenv "$(app_workload)" ANALYTICS_FLUSH_INTERVAL=1h ANALYTICS_BATCH_SIZE=100000000 >/dev/null
settle_rollout "$(app_workload)"
podsA=$(phase_pods || true)
[[ -n "$podsA" ]] || { warn "A fazı için hazır uygulama pod'u yok"; exit 2; }
k6run hot-key --vus 80 --duration "$PHASE" >/dev/null 2>&1 || true
reqA=$(k6_reqs)
sleep 12
read -r p99A acqA wA batchA <<< "$(read_phase "$podsA")"

step "B · yazıcı VARSAYILAN hâlinde (flush 1 sn, parti 500) — aynı yük, taze pod'lar"
setenv "$(app_workload)" ANALYTICS_FLUSH_INTERVAL- ANALYTICS_BATCH_SIZE- >/dev/null
settle_rollout "$(app_workload)"
podsB=$(phase_pods || true)
[[ -n "$podsB" ]] || { warn "B fazı için hazır uygulama pod'u yok"; exit 2; }
k6run hot-key --vus 80 --duration "$PHASE" >/dev/null 2>&1 || true
reqB=$(k6_reqs)
sleep 12
read -r p99B acqB wB batchB <<< "$(read_phase "$podsB")"

grafana_hint "05 · Postgres → 'Veritabanı sorguları (türe göre)' + 'Uygulama havuzu: bağlantı bekleme (p99)' · 02 · App RED → 'p99 süre (uç noktaya göre)'"
note "A (yazıcı durdu):     istek ${reqA%%.*} · redirect p99 $(ms "$p99A") ms · havuz bekleme p99 $(ms "$acqA") ms · uygulama pod'larından write_clicks/s $(awk -v v="$wA" 'BEGIN{printf "%.2f", v}')"
note "B (yazıcı çalışıyor): istek ${reqB%%.*} · redirect p99 $(ms "$p99B") ms · havuz bekleme p99 $(ms "$acqB") ms · uygulama pod'larından write_clicks/s $(awk -v v="$wB" 'BEGIN{printf "%.2f", v}') · toplu yazma p99 $(ms "$batchB") ms"
# Yük üreteci koşmadıysa iki faz da "0" okunur ve fark yok sanılır (kural 14).
if [[ "${reqA%%.*}" == 0 || "${reqB%%.*}" == 0 ]]; then
  warn "k6 fazlardan birinde koşmadı (A=${reqA%%.*}, B=${reqB%%.*} istek) — ölçüm yok"; exit 2
fi
# A'da yazma sürüyorsa ayırdığımız şey yazıcı değildir: iki değişkenli bir deneyden hüküm çıkmaz.
if awk -v w="$wA" 'BEGIN{exit !(w >= 0.01)}'; then
  warn "A fazında uygulama pod'ları hâlâ write_clicks atıyor ($(awk -v v="$wA" 'BEGIN{printf "%.2f", v}')/s) — yazıcı durdurulamadı, karşılaştırma tek değişkenli değil"; exit 2
fi
note "Paylaşılan üç kaynak: pod CPU'su, DB bağlantı havuzu, veritabanının kendisi. Bu ölçekte bedel küçük"
note "kalabilir (okumalar Redis'ten, yazıcı pod başına tek bağlantı) — ama yazıcıyı AYRI ölçekleyemez,"
note "ayrı sınırlayamaz, redirect'e dokunmadan yeniden başlatamazsın. Çözüm 06+07: tüketici ayrı bir"
note "süreç ve ayrı bir deployment. İzolasyon bir arayüz meselesi değil, bir SÜREÇ meselesidir."
awk -v w="$wB" 'BEGIN{exit !(w > 0)}' \
  && reproduced "yazıcı redirect'i servis eden süreçte: B'de aynı pod'lardan ve aynı havuzdan $(awk -v v="$wB" 'BEGIN{printf "%.2f", v}') write_clicks/s, yazıcı durunca 0 (bedel: redirect p99 $(ms "$p99A")→$(ms "$p99B") ms, havuz bekleme p99 $(ms "$acqA")→$(ms "$acqB") ms)"
not_reproduced "uygulama pod'larından write_clicks çıkmıyor (B: $(awk -v v="$wB" 'BEGIN{printf "%.2f", v}')/s) — yazıcı ayrı süreçte (06)"
