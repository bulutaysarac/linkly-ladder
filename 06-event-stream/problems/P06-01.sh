#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P06-01 · En az bir kez: tüketici yazdıktan sonra commit'ten önce ölürse aynı olaylar TEKRAR gelir
# Dayanıklılığı kazandık (P05-01 çözüldü) ama artık farklı bir sorun var: ÇİFT SAYMA.
# İdempotency (processed_events tablosu) bunu emiyor; TRAP_COMMIT_BEFORE_WRITE ise ters ucu
# (commit önce → veri KAYBI) gösteriyor. "Tam bir kez" yok; seçtiğin şey hangi hatayı yaşayacağın.
ensure_healthy
CONSUMER=analytics
need_confirm "tüketici pod'u öldürülecek"
DELAY_MS=${COMMIT_DELAY_MS:-30000}
DELAY_S=$(( DELAY_MS / 1000 ))
on_cleanup "kubectl -n \"$NS\" scale "$(wl $CONSUMER)" --replicas=1"
on_cleanup "setenv "$(wl $CONSUMER)" TRAP_COMMIT_DELAY_MS- TRAP_COMMIT_BEFORE_WRITE-"

# Tüketici pod'unun KENDİ sayacı (Prometheus'a değil pod'a sor: öldürülen pod kazınmayı beklemez).
consumer_metric() {   # consumer_metric <pod> <awk-deseni> → değer (ulaşılamazsa 0; tek satır)
  { kubectl --request-timeout=5s -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$1:8080/proxy/metrics" 2>/dev/null || true; } \
    | awk -v pat="$2" '$0 ~ pat {s += $2} END {print s + 0}'
}
consumer_pods() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=$CONSUMER --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}
stats_clicks() { curl -s --max-time 5 "$BASE_URL/api/links/$1/stats" | jq -r '.clicks // 0' 2>/dev/null || echo 0; }

# NEDEN BİR "PENCERE" TUZAĞI VAR.
# EN: the window we need is "the batch is written, its offset is not committed yet". Left alone it
#     is the few milliseconds of one offset commit, and a 2000-record backlog is fetched in ONE
#     poll, written in one transaction and committed right after — well under a second once the
#     consumer owns the partition. A kill on a fixed timer (say 35 s after start) lands after the
#     backlog is written AND committed: no redelivery can happen, yet `counted == N` passes
#     because a healthy consumer also counts exactly N. Slowing the broker or Postgres is no
#     substitute: it stalls the whole pipeline instead of opening one gap. TRAP_COMMIT_DELAY_MS
#     keeps the write-then-commit ORDER and only holds the gap open long enough to hit on purpose:
#     we watch the click count, and the moment the first batch is visible in the database we kill
#     the pod — its offset is still uncommitted.
# TR: ihtiyacımız olan pencere "parti yazıldı, offset'i henüz commit edilmedi". Kendi hâlinde bu,
#     tek bir offset commit'inin birkaç milisaniyesi; 2000 kayıtlık birikim TEK poll'da okunur,
#     tek transaction'da yazılır ve hemen ardından commit edilir — tüketici partition'ı aldıktan
#     sonra bir saniyeden kısa. Sabit bir zamanlayıcıyla (ör. başladıktan 35 sn sonra) öldürmek,
#     birikim yazılıp commit edildikten SONRA gelir: tekrar teslim OLAMAZ, ama `sayım == N` yine
#     de geçer, çünkü sağlıklı bir tüketici de tam N sayar. Broker'ı ya da Postgres'i yavaşlatmak
#     bunun yerini tutmaz: tek bir boşluğu açmak yerine bütün boru hattını durdurur.
#     TRAP_COMMIT_DELAY_MS yaz→commit SIRASINI korur, yalnızca aradaki boşluğu bilerek
#     vurulabilecek kadar açık tutar: tıklama sayısını izliyoruz ve ilk parti veritabanında
#     göründüğü an pod'u öldürüyoruz — offset'i hâlâ commit edilmemiş.
step "Yazma ile commit arasına ${DELAY_S} sn koy (TRAP_COMMIT_DELAY_MS=$DELAY_MS)"
setenv "$(wl $CONSUMER)" TRAP_COMMIT_DELAY_MS="$DELAY_MS" >/dev/null
settle_rollout "$(wl $CONSUMER)"

# DENEY KURULUMU: tüketiciyi ÖNCE durdurup birikim yarat, SONRA aç. Tıklamalar üretilirken tüketici
# de çalışıyorsa olaylar geldikçe işlenir ve deney, ölçmek istediği birikimi hiç kurmaz.
step "Tüketiciyi durdur ve birikim yarat"
kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=0 >/dev/null
# Kapanmakta olan pod da tüketir: gerçekten gidene kadar bekle.
kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=$CONSUMER --timeout=90s >/dev/null 2>&1 || true
code=$(create_link "https://example.com/dedup")
[[ -n "$code" ]] || { warn "link oluşturulamadı"; exit 2; }
N=${N:-2000}
before=$(stats_clicks "$code")
clicks "$code" "$N" 20
note "$N tıklama üretildi, hepsi topic'te bekliyor (tüketici kapalı)"

# ÖLÇÜM PENCERESİ DENEYİN KENDİSİ KADAR OLMALI.
# EN: a fixed `increase(...[10m])` also counts whatever ran in this namespace just before (e.g. the
#     previous level's scripts replayed by verify-prev) and then describes the neighbours, not
#     this experiment. The window starts at T0.
# TR: sabit bir `increase(...[10m])`, hemen öncesinde bu namespace'te koşan her şeyi de sayar (ör.
#     verify-prev'in koştuğu önceki seviye scriptleri) ve bu deneyi değil KOMŞULARINI anlatır.
#     Pencere T0'da başlar.
T0=$(date +%s)
step "Tüketiciyi aç; ilk parti veritabanında görünür görünmez ÖLDÜR (commit ${DELAY_S} sn sonra gelecekti)"
kubectl -n "$NS" scale "$(wl $CONSUMER)" --replicas=1 >/dev/null
tw=0; victim=""
for _ in $(seq 1 180); do
  cur=$(stats_clicks "$code")
  if (( ${cur:-0} > before )); then tw=$(date +%s); break; fi
  sleep 1
done
if (( tw == 0 )); then
  warn "ölçüm yapılamadı: tüketici 3 dk içinde birikimden tek bir parti bile yazmadı."
  exit 2
fi
victim=$(consumer_pods | head -1)
[[ -n "$victim" ]] || { warn "yazan tüketici pod'u bulunamadı"; exit 2; }
# KANIT: öldürme anında bu pod HİÇ commit etmemiş olmalı — yazdığı her şey "commit edilmemiş".
commits_at_kill=$(consumer_metric "$victim" '^consumer_commits_total')
written_at_kill=$(stats_clicks "$code")
kubectl -n "$NS" delete pod "$victim" --force --grace-period=0 >/dev/null 2>&1 || true
tk=$(date +%s)
note "öldürülen pod: $victim · yazma görüldükten $(( tk - tw )) sn sonra · o an yazılmış $(( written_at_kill - before ))/$N · pod'un commit sayısı=${commits_at_kill%%.*}"

# Yeni pod partition'ı hemen ALAMAZ: sert öldürülen üye, oturum zaman aşımı dolana kadar grupta
# sayılır (franz-go varsayılanı 45 sn). O yüzden sabit bir bekleme değil, yeni pod'un gerçekten
# iş yaptığını gösteren KENDİ sayacını bekliyoruz. Sayım burada DURULMA ölçüsü olamaz: birikim zaten
# yazılmıştı, sayı N'de sabit durur ve "durulmuş" görünür — tekrar teslim daha gelmeden.
step "Yeni tüketici aynı partileri yeniden alıyor mu?"
kubectl -n "$NS" rollout status "$(wl $CONSUMER)" --timeout=120s >/dev/null 2>&1 || true
seen=0
for _ in $(seq 1 60); do
  seen=0
  for p in $(consumer_pods); do
    [[ "$p" == "$victim" ]] && continue
    v=$(consumer_metric "$p" '^consumer_records_total.*result="(ok|duplicate)"')
    seen=$(awk -v a="$seen" -v b="$v" 'BEGIN{print a + b}')
  done
  awk -v s="$seen" 'BEGIN{exit !(s > 0)}' && break
  sleep 3
done
# Sayım DURULANA kadar bekle (birden çok parti olabilir).
prev=-1; stable=0
for _ in $(seq 1 60); do
  cur=$(stats_clicks "$code")
  if [[ "$cur" == "$prev" ]]; then stable=$(( stable + 1 )); else stable=0; fi
  (( stable >= 4 )) && break
  prev=$cur; sleep 3
done
after=$(stats_clicks "$code")
counted=$(( after - before ))
dup=0; ok=0
for p in $(consumer_pods); do
  [[ "$p" == "$victim" ]] && continue
  dup=$(awk -v a="$dup" -v b="$(consumer_metric "$p" '^consumer_records_total.*result="duplicate"')" 'BEGIN{print a + b}')
  ok=$(awk -v a="$ok" -v b="$(consumer_metric "$p" '^consumer_records_total.*result="ok"')" 'BEGIN{print a + b}')
done
# Temizlik tuzağı kapatıp tüketiciyi yeniden başlatacak. Yeni pod'un commit'ini BEKLE: yoksa onun da
# yazıp commit edemediği parti bir sonraki pod'a tekrar gelir ve sonraki deney bizim tekrarlarımızı görür.
for _ in $(seq 1 $(( DELAY_S / 3 + 10 ))); do
  c=0
  for p in $(consumer_pods); do c=$(awk -v a="$c" -v b="$(consumer_metric "$p" '^consumer_commits_total')" 'BEGIN{print a + b}'); done
  awk -v c="$c" 'BEGIN{exit !(c > 0)}' && break
  sleep 3
done
WIN=$(( $(date +%s) - T0 + 30 ))   # deney süresi + kazıma payı (uygulama ServiceMonitor'ları 10 sn)
prom_dup=$(promq "sum(increase(consumer_records_total{namespace=\"$NS\",result=\"duplicate\"}[${WIN}s]))")
grafana_hint "08 · Stream → 'Tüketilen kayıtlar (sonuca göre)' (duplicate) + 'Üretilen ve tüketilen olaylar (toplam)'"
note "üretilen: $N · sayılan: $counted · yeni tüketici: ok=${ok%%.*} duplicate=${dup%%.*} (Prometheus: duplicate≈${prom_dup%%.*})"
note "duplicate>0: aynı olay İKİ KEZ teslim edildi — öldürülen pod yazmıştı ama commit etmemişti."
note "Sayım yine TAM $N ise idempotency tekrarı yuttu: en-az-bir-kez teslimat + idempotent yazma."
note "Ters uç için: setenv "$(wl $CONSUMER)" TRAP_COMMIT_BEFORE_WRITE=true"
note "  → commit yazmadan önce yapılır; tüketici ölürse o kayıtlar bir daha GELMEZ (veri kaybı)."
note "Dağıtık sistemlerde 'tam bir kez teslimat' yoktur; olan şey en-az-bir-kez + idempotency'dir."
# DENEY HİÇ ÇALIŞMADIYSA HÜKÜM VERME: eksik ölçüm yeşil bir sonuç değildir.
if (( counted <= 0 )); then
  warn "ölçüm yapılamadı: tüketici hiçbir tıklama yazmadı (sayılan=$counted)."
  exit 2
fi
if (( counted > N )); then
  reproduced "ÇİFT SAYMA: $counted > $N — tekrar teslim edilen olaylar iki kez işlendi, idempotency yok"
fi
# ÖLDÜRME PENCEREYE DENK GELDİ Mİ? Gelmediyse tekrar teslim OLAMAZDI; "yok" demek eksik ölçümü
# sonuç sanmaktır.
if (( tk - tw >= DELAY_S - 3 )); then
  warn "öldürme pencereyi kaçırdı: yazmadan $(( tk - tw )) sn sonra (pencere ${DELAY_S} sn) — COMMIT_DELAY_MS'i büyüt."
  exit 2
fi
if awk -v s="$seen" 'BEGIN{exit !(s <= 0)}'; then
  warn "ölçüm yapılamadı: öldürmeden sonra yeni tüketici hiçbir kayıt işlemedi (grup yeniden dengelenmedi mi?)."
  exit 2
fi
# HÜKÜM TEKRAR TESLİMİN KANITINA DAYANIR, "tüketici çalıştı"ya değil. Tek başına `sayım == N`
# yetmez: sağlıklı ama hiç öldürülmemiş bir tüketici de tam N sayar — düşemeyen bir deney olur.
# EN: the verdict rests on evidence of REDELIVERY, not on "the consumer worked". `counted == N`
#     alone is also what a consumer that was never killed produces.
if awk -v d="${dup%%.*}" 'BEGIN{exit !(d > 0)}' && (( counted == N )); then
  reproduced "yazılmış ama commit edilmemiş parti yeniden teslim edildi (duplicate=${dup%%.*}) ve sayım TAM $counted/$N kaldı — en az bir kez teslimat + idempotent yazma"
fi
if (( counted < N )); then
  not_reproduced "sayım $counted/$N: öldürme sonrası kayıt KAYBOLDU — teslimat en-az-bir-kez değil (commit yazmadan önce mi yapılıyor?)"
fi
not_reproduced "öldürülen pod yazmıştı (commit sayısı ${commits_at_kill%%.*}) ama yeni tüketici aynı olayları yeniden ALMADI (duplicate=${dup%%.*}) — commit yazmadan önce yapılıyor olabilir (en fazla bir kez)"
