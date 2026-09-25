#!/usr/bin/env bash
# Ortak reproduce kütüphanesi. Her problems/PNN-XX.sh şöyle başlar:
#   source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# Kontrat: env NS, BASE_URL, PROM_URL, GRAFANA_URL, LADDER_ROOT. Son satır REPRODUCED (exit 0) ya da NOT-REPRODUCED (exit 1).
set -euo pipefail
: "${NS:?NS gerekli}" "${BASE_URL:?BASE_URL gerekli}"
PROM_URL=${PROM_URL:-http://prometheus.localtest.me}
GRAFANA_URL=${GRAFANA_URL:-http://grafana.localtest.me}
LADDER_ROOT=${LADDER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
APP_SELECTOR=${APP_SELECTOR:-app.kubernetes.io/part-of=linkly-ladder}
PROBLEM_ID=$(basename "${0%.sh}")

# --explain: README'deki "### PNN-XX" bölümünü bas ve çık
if [[ "${1:-}" == "--explain" ]]; then
  awk -v id="### $PROBLEM_ID" 'index($0,id)==1{p=1;print;next} p&&/^### /{exit} p{print}' "$(dirname "$0")/../README.md"
  exit 0
fi

step()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
note()  { printf '  \033[2m%s\033[0m\n' "$*"; }
warn()  { printf '  \033[33m%s\033[0m\n' "$*"; }
# TEMİZLİKTEN DE DUYULAN UYARI. `run_cleanup` her komutu `>/dev/null 2>&1` ile çalıştırır (kubectl
# gürültüsü kararın altını doldurmasın diye) — ama bu, temizlik sırasında ORTAYA ÇIKAN gerçek bir
# sorunu da yutar: "chaos kaldırıldı, ortam toparlanmadı" satırı hiç görünmez ve bedelini bir
# sonraki script öder. Kütüphane yüklenirken gerçek stderr'i 9. tanımlayıcıya kopyalıyoruz;
# warn_hard oraya yazar. (bash 3.2'de `{fd}>&2` yok, sabit numara kullanmak zorundayız.)
# EN: run_cleanup silences every hook so kubectl noise cannot bury the verdict — but that also
# swallows real problems discovered DURING cleanup, and the next script pays for them. We dup the
# real stderr onto fd 9 at load time; warn_hard writes there.
exec 9>&2
warn_hard() { printf '  \033[33m%s\033[0m\n' "$*" >&9; }
reproduced()     { printf '\n\033[1;31mREPRODUCED\033[0m %s — %s\n' "$PROBLEM_ID" "$*"; exit 0; }
not_reproduced() { printf '\n\033[1;32mNOT-REPRODUCED\033[0m %s — %s\n' "$PROBLEM_ID" "$*"; exit 1; }
need_confirm()   { [[ "${CONFIRM:-}" == 1 ]] || { warn "yıkıcı adım ($*): CONFIRM=1 ile çalıştır"; exit 2; }; }
grafana_hint()   { note "Grafana → $GRAFANA_URL/dashboards?query=Ladder → $1  (level=$NS)"; }

# Prometheus anlık sorgu → ilk sonucun değeri (yoksa "0").
# DAYANIKLILIK: `curl -sf` bağlantı düşünce 52 ("empty reply") ile çıkar ve `promq` komut
# ikamesi içinde çağrıldığı için `set -e` scripti ORADA öldürür — ölçüm bitmiş olsa bile
# sonuç "HATA" görünür. Ölçüm ALTYAPISININ tökezlemesi, deneyi iptal etmemeli.
# Ama sessizce 0 da dönmemeli: iki denemede de alamazsa STDERR'e uyarı basar (stdout'a basarsa
# değeri kirletir — bu fonksiyon hep `$( )` içinde çağrılıyor).
# POST kullanılıyor, GET değil: uzun sorgular (histogram_quantile + birden çok etiket) URL
# sınırlarına takılır. Ve `-f` YOK: `-f` gövdeyi ATAR, geriye yalnızca "curl 22" kalır —
# Prometheus'un "parse error at char 61" gibi gerçek mesajı kaybolur. Ölçüm aracının kendi
# hatası da bir ölçümdür; onu sessizleştirmek, yanlış sonucu doğru sanmanın en kısa yoludur.
# EN: POST, not GET: long queries hit URL limits. And no `-f`: it discards the body, leaving
# only "curl 22" while Prometheus's actual message ("parse error at char 61") is lost. The
# measurement tool's own failure is also a measurement.
_promq_raw() {
  local body code crc=0
  # BAŞARISIZLIĞIN SEBEBİNİ DE YAZ. curl hatasında sessizce 1 dönmek ekranda "Prometheus
  # sorgusu başarısız → " diye BOŞ bir sebep bırakır ve bağlantı hatası ile sorgu hatası ayırt
  # edilemez. Bir ölçüm neden yapılamadığını söyleyemiyorsa, o ölçümün yokluğu da teşhis edilemez.
  # EN: returning 1 silently on a curl failure leaves an EMPTY reason on screen and makes a
  # connection error indistinguishable from a query error.
  body=$(curl -s --max-time 15 -w $'\n%{http_code}' -XPOST "$PROM_URL/api/v1/query" \
           --data-urlencode "query=$1" 2>/dev/null) || crc=$?
  if (( crc != 0 )); then printf 'curl hatası %s (%s ulaşılabilir mi?)' "$crc" "$PROM_URL" >&2; return 1; fi
  code=${body##*$'\n'}; body=${body%$'\n'*}
  [[ "$code" == "200" ]] || { printf 'HTTP %s · %s' "$code" "$body" >&2; return 1; }
  printf '%s' "$body"
}
promq() {
  # GEÇİCİ BİR HATA, BİR ÖLÇÜM SONUCU DEĞİLDİR.
  # Tek bir yeniden deneme yetmez: Prometheus kısa süre meşgulse (kazıma, compaction, pod
  # yeniden başlatma) iki deneme de aynı pencereye denk gelir, `promq` 0 döner ve deney sıfırı
  # GERÇEK bir ölçüm sanır — bir deneyin tabanı böyle "0" olur. Artan beklemeyle dört deneme,
  # geçici bir tökezlemeyi deneyin sonucuna dönüşmekten çıkarır.
  # EN: one retry is not enough — if Prometheus is briefly busy both attempts land in the same
  # window, `promq` returns 0 and the experiment mistakes that zero for a real measurement.
  local out err rc=0 attempt
  err=$(mktemp)
  for attempt in 1 2 3 4; do
    rc=0; out=$(_promq_raw "$1" 2>"$err") || rc=$?
    (( rc == 0 )) && break
    (( attempt < 4 )) && sleep $(( attempt * 2 ))
  done
  if (( rc != 0 )); then
    # SORGUNUN TAMAMINI BAS. Kırpılmış bir sorguyla (ör. `%.70s`) iki FARKLI bozuk sorgu ekranda
    # birebir aynı görünür ve hatanın nerede olduğu — Prometheus sütun numarasını verdiği hâlde —
    # okunamaz. Bir hata mesajı, neyin başarısız olduğunu göstermelidir.
    # EN: a truncated query (e.g. `%.70s`) makes two DIFFERENT malformed queries look identical on
    # screen, and the column number Prometheus helpfully returns points into text nobody can see.
    # An error message must show what actually failed.
    printf '  \033[33mPrometheus sorgusu başarısız, 0 sayıldı: %s\033[0m\n' "$1" >&2
    printf '  \033[33m  → %s\033[0m\n' "$(jq -r '.error // .' "$err" 2>/dev/null | head -c 200)" >&2
    rm -f "$err"; echo 0; return 0
  fi
  rm -f "$err"
  # NaN/Inf TEK YERDE ETKİSİZLEŞTİRİLİR.
  # EN: `histogram_quantile` over an empty window returns the string "NaN", and a histogram with
  #     an open top bucket can return "+Inf". Passed to awk these are not numbers: BSD awk reads
  #     them as 0 (so every comparison quietly fails), while gawk keeps them as STRINGS and
  #     "NaN" > "0" is TRUE lexicographically — the same script would reach opposite verdicts on
  #     macOS and Linux. 190 call sites cannot each remember this; normalise at the source.
  # TR: boş pencerede `histogram_quantile` "NaN" döner, üst kovası açık bir histogram "+Inf"
  #     dönebilir. awk'a verildiğinde bunlar sayı değildir: BSD awk 0 okur (her karşılaştırma
  #     sessizce yanlış olur), gawk ise METİN olarak tutar ve "NaN" > "0" sözlük sırasına göre
  #     DOĞRUdur — aynı script macOS'ta ve Linux'ta ZIT hükümlere varır. 190 çağrı yerinin her
  #     biri bunu hatırlayamaz; kaynağında normalleştir.
  num "$(printf '%s' "$out" | jq -r '.data.result[0].value[1] // "0"')"
}
# Sorgu hiç seri döndürmüyor mu? (metrik yok)
prom_absent() {
  local out
  out=$(_promq_raw "$1") || { sleep 2; out=$(_promq_raw "$1") || { echo "prom_absent: sorgu yapılamadı" >&2; return 1; }; }
  [[ "$(printf '%s' "$out" | jq -r '.data.result | length')" == "0" ]]
}

source "$LADDER_ROOT/platform/lib/apikey.sh"
# API anahtarı bir kez okunur (her create_link'te kubectl çağırmak ölçümün kendisini yavaşlatır).
# Boşsa dizi BOŞ kalır ve 13 öncesi davranış birebir korunur.
AUTH_HDR=(); _k=$(ladder_api_key 2>/dev/null || true)
[[ -n "${_k:-}" ]] && AUTH_HDR=(-H "Authorization: Bearer $_k")
unset _k

# limits_enforced — bu deney hız sınırlayıcıları SINIYOR: k6 herkese açık girişten, jetonsuz gitsin.
# Varsayılan tersidir (loadtest.sh): 08'den itibaren limiter'ı sınamayan deneyler yük girişinden ve
# jetonla koşar, yoksa tek IP'lik k6 sistemi değil limiter'ları ölçer (erişilebilirlik yüzde birkaça
# düşer, uygulamanın kendi 5xx sayısı ≈0). Limiter'ı sınayıp bunu çağırmayan script ise ters yönde yanılır:
# limiter'ı hiç görmez ve "limit çalışmıyor" der. Lint kuralı 17 bu çağrıyı zorunlu tutar.
# EN: this experiment TESTS the limiters, so k6 must use the public entrance without the token.
limits_enforced() {
  export LIMITS_ENFORCED=1
  note "hız sınırları bu deneyde UYGULANIYOR: k6 herkese açık girişten, muafiyet jetonu olmadan"
}

# create_link: BAŞARISIZLIK NORMALDİR. Bir üst seviye aynı isteği bilerek reddedebilir (01'de
# javascript: → 400). `curl -f` böyle bir durumda 22 ile çıkar ve `set -e` scripti öldürür; script
# "NOT-REPRODUCED" diyemez, ERROR verir. Bu yüzden kod yoksa BOŞ döner.
create_link() {
  local body
  body=$(curl -s -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' ${AUTH_HDR[@]+"${AUTH_HDR[@]}"} \
           -d "{\"url\":\"$1\"}" 2>/dev/null) || true
  printf '%s' "$body" | jq -r '.code // empty' 2>/dev/null || true
}
# Oluşturma denemesinin HTTP durumu (reddedildi mi, neden?) — doğrulama testleri bunu okur.
create_status() {
  curl -s -o /dev/null -w '%{http_code}' -XPOST "$BASE_URL/api/links" \
    -H 'Content-Type: application/json' ${AUTH_HDR[@]+"${AUTH_HDR[@]}"} -d "{\"url\":\"$1\"}" 2>/dev/null || echo 000
}
status_of()   { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/$1"; }
header_of()   { curl -sI --max-time 5 "$BASE_URL/$1" | tr -d '\r' | awk -v h="$2" 'tolower($1)==tolower(h)":"{ $1=""; sub(/^ /,""); print }'; }

# Pod'un kendi /metrics ucunu SANİYEDE BİR örnekle → saniyelik fark dizisi (dosyaya, satır başına bir sayı).
#   sample_series <pod> <saniye> <çıktı-dosyası> <awk-deseni> [atlanacak-ilk-saniye]
#
# Neden var: Prometheus bu kurulumda 15 sn'de bir örnekliyor ve `rate(...[30s])` 1-2 saniyelik bir
# darbeyi 30 saniyeye yayıp düzlüyor. Tepe/ortalama oranını ölçmek istiyorsan ölçüm çözünürlüğün
# olaydan İNCE olmalı. (Aynı sorun 11'de yüksek çözünürlük/exemplar başlığıyla dönüyor.)
#
# Neden port-forward DEĞİL: `kubectl port-forward` tüneli 150 saniyelik örnekleme boyunca
# düşebilir; curl 28 (timeout) / 52 (empty reply) döner ve `pipefail` altında scripti öldürür —
# ölçüm aracının kendisi deneyi bozar. API sunucusunun pod
# proxy'si (`/proxy/metrics`) kalıcı bir tünel gerektirmez. Yine de tek tük hata olabilir:
# başarısız örnek ATLANIR, sayaç farkı bir sonraki başarılı örnekte doğru kapanır.
sample_series() {
  local pod=$1 secs=$2 out=$3 pattern=$4 skip=${5:-0}
  local prev="" cur i fails=0 raw rc firsterr=""
  : > "$out"
  for (( i = 0; i < secs; i++ )); do
    rc=0
    raw=$(kubectl --request-timeout=3s -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$pod:8080/proxy/metrics" 2>&1) || rc=$?
    if (( rc != 0 )); then
      # Tek bir anlık hata örnekleme serisini delik deşik etmesin: bir kez hemen tekrar dene.
      rc=0
      raw=$(kubectl --request-timeout=3s -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$pod:8080/proxy/metrics" 2>&1) || rc=$?
    fi
    if (( rc != 0 )); then
      # İlk hatayı SAKLA ve bas: "144/150 örnek kayboldu" tek başına teşhis değil, semptomdur.
      [[ -z "$firsterr" ]] && firsterr=$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-160)
      fails=$(( fails + 1 )); prev=""; sleep 1; continue
    fi
    cur=$(printf '%s\n' "$raw" | awk -v pat="$pattern" '$0 ~ pat {s += $2} END {print s + 0}')
    if [[ -n "$prev" && $i -gt $skip ]]; then
      awk -v a="$prev" -v b="$cur" 'BEGIN{d=b-a; print (d<0?0:d)}' >> "$out"
    fi
    prev=$cur
    sleep 1
  done
  if (( fails > secs / 5 )); then
    # TEŞHİS METNİ, ÖLÇÜLEN DEĞERE KARIŞMAMALI. `warn` STDOUT'a yazar; bu fonksiyonun çağrıldığı
    # yer `$( ... )` ile YAKALANIYORSA uyarı sayının yanına yapışır ve ölçülen değer "örnekleme"
    # kelimesi olur.
    # EN: `warn` writes to stdout; when this function's caller captures it with `$( ... )` the
    # warning is glued onto the number and the measured value becomes the word "örnekleme".
    warn "örnekleme kayıpları: $fails/$secs — ilk hata: ${firsterr:-<yok>}" >&2
  fi
  return 0
}
# "tepe ortalama oran" üçlüsü — kapasite tepeye göre planlanır, ortalamaya göre değil.
peak_avg() {
  awk '{n++; s+=$1; if ($1>p) p=$1} END{if (n==0||s==0){print "0 0 0"; exit} printf "%d %.1f %.1f", p, s/n, p/(s/n)}' "$1"
}

# Komutu ZAMAN SINIRIYLA çalıştır (macOS'ta `timeout` yok).
# Neden: bir node'u dondurup çözen bir deneyde (P07-07) k6 bitse bile bir adım asılı kalabilir.
# Bir deneyin adımları SINIRLI sürmeli; süresiz bekleyen bir adım, arkasındaki turun tamamını
# durdurur ve hangi adımda takıldığını bile söylemez.
# Süreç AĞACINI öldür. Neden: bir bash alt kabuğuna TERM göndermek, o kabuk ön plandaki
# çocuğunu (k6 gibi) beklerken İŞE YARAMAZ — bash sinyali çocuk bitene kadar erteler ve
# watchdog "öldürdüm" sanarken komut saatlerce asılı kalır. Çocukları önce, ebeveyni sonra öldür.
kill_tree() {
  local p=$1 c
  for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
  kill -KILL "$p" 2>/dev/null || true
}
with_timeout() {
  local secs=$1; shift
  ( "$@" ) & local pid=$!
  # >/dev/null ŞART: watchdog stdout'u MİRAS ALIR. Bu fonksiyon `$( )` içinde çağrıldığında
  # komut ikamesi EOF bekler ve watchdog borusu açık kaldığı için ASILI KALIR — komut çoktan
  # bitmiş olsa bile — ve tur, hiçbir şey basmadan durur. Arka plana attığın her şeyin
  # çıktısını KAPAT.
  ( sleep "$secs"; kill_tree "$pid" ) >/dev/null 2>&1 & local watchdog=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

# NaN'i sayıya çevir. histogram_quantile BOŞ pencerede NaN döner; awk'ta NaN ile yapılan HER
# karşılaştırma yanlış çıkar ve script sessizce "etki yok" der ("tepe p99=nan ms" basıp "burst
# latency'yi bozmadı" diye). Sayı bekleyen yere sayı ver.
num() { local v=${1:-}; case "$v" in ""|NaN|nan|+Inf|-Inf|null) printf '0' ;; *) printf '%s' "$v" ;; esac; }

# SATIR SAY — VE SIFIRDA DA TEK BİR SAYI DÖNDÜR.
# `grep -c` eşleşme bulamayınca "0" BASAR ve yine de 1 ile çıkar. Alışkanlıkla eklenen
# `|| echo 0` de bu yüzden çalışır ve değişken "0\n0" olur. Ardından `(( got >= want ))`
# aritmetik SÖZDİZİM HATASI verir, koşul sessizce yanlış sayılır ve bekleme döngüsü asla
# sağlanmayacak bir koşulu bekler — yani "0 endpoint" durumu, tam da beklemenin gerektiği an,
# ölçülemez hâle gelir. Hata ekranda da görünmez çünkü stderr bastırılmıştır.
# EN: `grep -c` PRINTS "0" and still exits 1, so the habitual `|| echo 0` also fires and the
# variable becomes "0\n0". The next `(( got >= want ))` is an arithmetic SYNTAX ERROR, the
# condition is silently treated as false and the wait loop waits for a condition that can never
# hold — precisely in the "zero endpoints" case where waiting matters most.
count_lines() { local n; n=$(grep -c "${1:-.}" || true); n=${n//[^0-9]/}; printf '%d' "${n:-0}"; }

# BİR SAYAÇ DELTASI, KAZIMA ARALIĞINDAN HIZLI OKUNAMAZ.
# Prometheus bu kurulumda uygulama metriklerini 10 sn'de, küme metriklerini 30 sn'de bir kazır. Bir sayacı bir işlemin hemen ÖNCESİNDE okursan
# elindeki değer o işlemden önceki kazımadır; hemen SONRASINDA okursan işlem henüz kazınmamıştır.
# İki uç da aynı anda yanlış olabilir ve fark gürültü çıkar. Daha kötüsü: araya bir rollout
# girdiyse ölen pod'un serisi `sum()`dan düşer, fark NEGATİF olur ve "0'a kırp" satırı bunu
# sessizce gizler — ölçüm "hiç olmadı" gibi görünür (ör. "61 → 0").
# Kural: sayaç deltası ölçen her ölçüm, iki ucunda da en az iki kazıma aralığı beklemelidir.
# EN: a counter delta cannot be read faster than the scrape interval (10s for app metrics, 30s for cluster metrics here). Read the counter
# immediately before an operation and you get the scrape from before it; read it immediately
# after and the operation has not been scraped yet. Worse, if a rollout happened in between, the
# dying pod's series drops out of `sum()`, the delta goes negative and a "clip to 0" line hides
# it — the measurement looks like it never happened. Wait two scrape intervals at BOTH ends.
SCRAPE_SETTLE=${SCRAPE_SETTLE:-40}
settle_scrape() { sleep "$SCRAPE_SETTLE"; }

# Bir arka plan işini sessizce bekle (ölmüşse hemen dön). `wait` doğrudan çağrıldığında
# with_timeout içinde farklı bir kabukta olduğu için işe yaramaz.
wait_pid_quiet() { local p=$1; while kill -0 "$p" 2>/dev/null; do sleep 2; done; return 0; }

# Bir metrik YOKSA ölçüme başlama.
# `promq` serisi olmayan bir sorguya "0" döndürür; yani var olmayan bir metrik ile gerçekten
# sıfır olan bir metrik aşağı akışta AYNI görünür: eksik bir ServiceMonitor, ekrana
# `max_connections=0` basıp "sorun yok" diyen bir deney üretir.
# Kural: bir ölçüm, dayandığı metriğin VARLIĞINI önce doğrulamalı.
need_metric() {
  local m=$1 hint=${2:-}
  # HENÜZ GELMEMİŞ BİR METRİK, YOK OLAN BİR METRİK DEĞİLDİR.
  # `make up` döndükten hemen sonra Prometheus yeni pod'ları daha kazımamış olur; üstelik bazı
  # sayaçlar (örn. `ratelimit_decisions_total`) İLK İSTEK değerlendirilene kadar hiç oluşmaz.
  # Tek atışta bakıp `exit 2` veren bir kontrol, metriğin birkaç saniye sonra geleceği bir
  # seviyeyi "metrik YOK" diye atlar. Bekle; sonra karar ver.
  # EN: right after `make up` Prometheus has not scraped the new pods yet, and some counters do
  # not exist until the first request is evaluated. A single-shot check would skip a level
  # seconds before the metric appears. Wait, then decide.
  local waited=0 budget=${METRIC_WAIT:-120}
  while (( waited < budget )); do
    prom_absent "$m{namespace=\"$NS\"}" && prom_absent "$m" || return 0
    sleep 10; waited=$(( waited + 10 ))
  done
  warn "metrik YOK: $m — ${budget} sn beklendi, ölçüm anlamsız${hint:+ ($hint)}"
  exit 2
}

# Chaos uygula ve temizliğini kaydet; UYGULANAMADIYSA scripti DURDUR.
# Neden: yaygın `|| warn "Chaos Mesh yok"` kalıbı iki farklı durumu aynı kefeye koyar —
#   (2) Chaos Mesh kurulu değil
#   (3) bu seviyede hedef pod YOK (etiket uyuşmuyor)
# İkincisi bir YAPILANDIRMA HATASIDIR. Sessizce geçilirse script arızayı hiç enjekte etmeden
# ölçüm yapar ve "sorun yok" der. Örnek: 09'dan itibaren Postgres'i CNPG yönetir ve pod
# etiketlerini operatör koyar; `app.kubernetes.io/name=postgres` etiketini `inheritedMetadata`
# vermese, pg-loss/pg-delay deneylerinin hepsi sessizce arızasız koşardı.
# Ölçemediğin şeyi "yok" sanma; enjekte edemediğin arızayı da.
# `setenv` SONRASI `rollout status` YENİ NESLİ BEKLEMEYEBİLİR.
# EN: `kubectl rollout status` reports on what the controller has OBSERVED. Called immediately
#     after a `set env`, it can see the PREVIOUS generation — already complete — and return at
#     once, so the script measures the OLD pods and concludes the trap "had no effect".
#     The symptom is a line like "301 modunda: durum=302": the flag is set, the measurement is
#     taken before any new pod exists, and the verdict blames the feature. Wait for
#     observedGeneration to catch up FIRST, then wait for the rollout.
# TR: `kubectl rollout status` denetleyicinin GÖZLEDİĞİ duruma bakar. `set env`in hemen ardından
#     çağrılırsa ÖNCEKİ nesli — zaten tamamlanmış — görüp anında döner; script eski pod'ları ölçer
#     ve tuzağın "etkisi yok" sonucuna varır. Belirtisi "301 modunda: durum=302" gibi bir satırdır.
#     Önce observedGeneration'ın yetişmesini bekle, sonra rollout'u.
# ARGO ROLLOUT'TA "HAZIR" CANARY BİTİNCE GELİR. 12+'da redirect bir Rollout: bir ayar değişikliği
# canary adımlarından ve analizden geçer (~4 dk). `kubectl rollout status` Rollout'u tanımaz, hazır
# replika sayısı ise canary sürerken de tamdır — ölçüm eski ve yeni sürümün karışımını okur. Beklenen
# durum: aşama Healthy ve stable sürüm = güncel sürüm. Canary iptal edildiyse pod'lar ESKİ sürümdedir;
# ölçüm anlamsızdır, script hüküm vermez.
# EN: for an Argo Rollout, ready means the canary finished: phase Healthy and stableRS == currentPodHash.
#     An aborted canary leaves the OLD version running, so the measurement is skipped.
settle_argo_rollout() {
  local w=$1 gen ph st cu i
  gen=$(kubectl -n "$NS" get "$w" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)
  for i in $(seq 1 30); do
    [[ "$(kubectl -n "$NS" get "$w" -o jsonpath='{.status.observedGeneration}' 2>/dev/null)" == "$gen" ]] && break
    sleep 2
  done
  for i in $(seq 1 240); do
    ph=$(kubectl -n "$NS" get "$w" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    st=$(kubectl -n "$NS" get "$w" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)
    cu=$(kubectl -n "$NS" get "$w" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)
    [[ "$ph" == Healthy && -n "$st" && "$st" == "$cu" ]] && break
    if [[ "$ph" == Degraded ]]; then
      warn "canary İPTAL edildi: $(kubectl -n "$NS" get "$w" -o jsonpath='{.status.message}' 2>/dev/null | head -c 160) — pod'lar ESKİ sürümde, ölçüm anlamsız"
      exit 2
    fi
    (( i == 1 )) && note "  canary adımları sürüyor ($ph) — yeni sürüm stable olana kadar bekleniyor (analiz ~4 dk)"
    sleep 2
  done
  for i in $(seq 1 30); do serving && break; sleep 2; done
}
settle_rollout() {
  local w=$1 gen obs i
  [[ "$w" == rollout/* ]] && { settle_argo_rollout "$w"; return 0; }
  gen=$(kubectl -n "$NS" get "$w" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)
  for i in $(seq 1 30); do
    obs=$(kubectl -n "$NS" get "$w" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo 0)
    (( ${obs:-0} >= ${gen:-0} )) && break
    sleep 2
  done
  kubectl -n "$NS" rollout status "$w" --timeout=180s >/dev/null 2>&1 || true
  for i in $(seq 1 30); do serving && break; sleep 2; done
}

chaos_cleanup() {
  local c=$1 kind name
  "$LADDER_ROOT/platform/lib/chaos.sh" delete "$c" >/dev/null 2>&1 || true
  # SİLMEYİ DOĞRULA. Chaos Mesh nesnelerinde finalizer vardır: `kubectl delete` dönse bile nesne
  # ayakta kalabilir ve ARIZA UYGULANMAYA DEVAM EDER: kümede kalan bir `pg-loss-30`, ardından
  # gelen her scripti kendi ölçümüyle ilgisi olmayan bir sebepten düşürür. Temizliğin başarısız
  # olduğunu söylemeyen bir temizlik, başarısızlığı bir sonraki deneye taşır.
  # EN: Chaos Mesh objects carry finalizers, so `kubectl delete` can return while the object — and
  # the injected fault — survives. A leftover `pg-loss-30` fails every following script for a
  # reason that has nothing to do with what it measures. A cleanup that cannot say it failed
  # hands the failure to the next experiment.
  kind=$(awk '/^kind:/{print tolower($2); exit}' "$LADDER_ROOT/platform/chaos/$c.yaml" 2>/dev/null)
  name=$(sed -n 's/.*name: *\([a-z0-9-]*\).*/\1/p' "$LADDER_ROOT/platform/chaos/$c.yaml" 2>/dev/null | head -1)
  if [[ -n "${kind:-}" && -n "${name:-}" ]]; then
    local i
    for i in $(seq 1 15); do
      kubectl -n "$NS" get "$kind" "$name" >/dev/null 2>&1 || break
      kubectl -n "$NS" patch "$kind" "$name" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      kubectl -n "$NS" delete "$kind" "$name" --wait=false >/dev/null 2>&1 || true
      sleep 2
    done
    kubectl -n "$NS" get "$kind" "$name" >/dev/null 2>&1 \
      && warn_hard "ARIZA HÂLÂ KÜMEDE: $kind/$name silinemedi — sonraki scriptler bozuk ortam bulacak"
  fi
  # Temizlik, ölçüm bütçesini yiyemez: kısa bir toparlanma penceresi bekle, olmazsa yüksek sesle söyle.
  wait_pods_ready_quiet "${CHAOS_RECOVER_TIMEOUT:-120}" \
    || warn_hard "chaos kaldırıldı ama ortam ${CHAOS_RECOVER_TIMEOUT:-120} sn'de toparlanmadı: $(not_ready_pods)"
}

chaos_apply() {
  local c=$1 out rc=0
  out=$("$LADDER_ROOT/platform/lib/chaos.sh" apply "$c" 2>&1) || rc=$?
  case $rc in
    0) # ARIZAYI KALDIRMAK, ETKİSİNİN GEÇMESİ DEMEK DEĞİLDİR.
       # NetworkChaos silindiğinde nesne gider ama durumlu bileşen hâlâ toparlanıyor olabilir:
       # 09'da replikaya gecikme enjekte edilip chaos temizlendiğinde CNPG replikayı yeniden
       # başlatabilir ve BİR SONRAKİ script "ortam bozuk" deyip çıkar. Bir deney, ortamı bulduğu hâlde
       # bırakmakla yükümlüdür; toparlanmayı bekleyecek yer, bozan scriptin kendisidir.
       # EN: deleting the chaos object does not mean its effect is gone — the stateful component
       # may still be recovering, and the NEXT script pays for it. The experiment that broke the
       # environment is the one that should wait for it to come back.
       on_cleanup "chaos_cleanup $c"
       # "Nesne oluştu" ile "arıza ENJEKTE EDİLDİ" aynı şey değil: chaos-daemon sağlıksızsa nesne
       # Run fazında kalır ve hiçbir şey olmaz. AllInjected koşulunu bekle, olmazsa yüksek sesle söyle.
       local kind name injected=""
       kind=$(awk '/^kind:/{print tolower($2); exit}' "$LADDER_ROOT/platform/chaos/$c.yaml")
       name=$(sed -n 's/.*name: *\([a-z0-9-]*\).*/\1/p' "$LADDER_ROOT/platform/chaos/$c.yaml" | head -1)
       for _ in $(seq 1 15); do
         injected=$(kubectl -n "$NS" get "$kind" "$name" -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}' 2>/dev/null || true)
         [[ "$injected" == "True" ]] && break
         sleep 2
       done
       if [[ "$injected" == "True" ]]; then note "chaos uygulandı ve enjekte edildi: $c"
       else warn "chaos nesnesi oluştu ama ENJEKTE EDİLMEDİ ($c, AllInjected=${injected:-bilinmiyor}) — chaos-daemon sağlıklı mı?"; fi
       return 0 ;;
    2) warn "Chaos Mesh kurulu değil: cd platform && make chaos"; exit 2 ;;
    3) warn "chaos hedefi bu seviyede yok ($c) — ETİKET UYUŞMUYOR, arıza enjekte edilemedi"; exit 2 ;;
    *) warn "chaos uygulanamadı ($c): $out"; exit 2 ;;
  esac
}

# Bilinen bir koda N tıklama üret (varsayılan 10 paralel).
# Neden paralel: sıralı `for + curl` döngüsü ~20-40 istek/s'te kalıyor. "Tampon/ kuyruk doluyken
# öldür" türü deneylerde bu hız yetersiz — tüketici üretimden hızlı çalışıyorsa hiç birikim olmaz
# ve deney, ölçmek istediği durumu HİÇ oluşturmadan "sorun yok" der.
clicks() {
  local code=$1 n=$2 par=${3:-10}
  seq 1 "$n" | xargs -P "$par" -I{} curl -s -o /dev/null --max-time 5 "$BASE_URL/$code" >/dev/null 2>&1 || true
}

kpods()       { kubectl -n "$NS" get pods -l "$APP_SELECTOR" "$@"; }
restarts()    { kpods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s+=$1} END{print s+0}'; }
# BULACAK BİR ŞEY OLMAMASI, HATA DEĞİLDİR.
# EN: no pod has terminated → `grep -v '^$'` matches nothing → exit 1 → `set -o pipefail` makes
#     the whole pipeline fail → `reason=$(last_reason)` is a failing assignment → `set -e` kills
#     the script WITHOUT printing a verdict. It only bites when nothing crashed, i.e. exactly on
#     the healthy path: P00-01 would pass at level 00 (where the process really does crash) and
#     die silently at level 01 (where the map is protected) — the one place its NOT-REPRODUCED
#     is the whole point. An empty result is a result; return it.
# TR: hiçbir pod sonlanmadıysa `grep -v '^$'` hiçbir şey bulmaz → 1 döner → `pipefail` boru
#     hattını düşürür → `reason=$(last_reason)` başarısız bir atama olur → `set -e` scripti
#     HÜKÜM BASMADAN öldürür. Yalnızca hiçbir şey çökmediğinde, yani tam olarak SAĞLIKLI yolda
#     ısırır: P00-01 00'da (süreç gerçekten çöker) geçer, 01'de (map korunur) sessizce ölürdü
#     — oysa oradaki NOT-REPRODUCED işin ta kendisidir. Boş bir sonuç da bir sonuçtur.
last_reason() { kpods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}' | grep -v '^$' | sort -u | paste -sd, - || true; }
# rollout status, İZLEDİĞİ nesne watch sırasında silinirse "error: object has been deleted" der.
# Bu bir arıza değil bir yarıştır: ensure_healthy pod'u force-delete ederken ya da bir deney
# rollout restart atarken denk gelir; script, kendi sorunuyla ilgisiz bir hatayla düşmemeli.
# Bir kez tekrar dene, sonra yoluna devam et.
wait_ready() {
  local d r want got
  for d in $(kubectl -n "$NS" get deploy -o name 2>/dev/null); do
    # 60 sn × 2: 180×2 ile takılı bir rollout tek başına 18 dakika yer (namespace'te üç
    # deployment var). Bu bir BEKLEME, ölçüm değil: kısa tut, sonraki `serving` kontrolü
    # gerçek hazır olmayı zaten sınıyor.
    kubectl -n "$NS" rollout status "$d" --timeout=60s >/dev/null 2>&1 \
      || kubectl -n "$NS" rollout status "$d" --timeout=60s >/dev/null 2>&1 || true
  done
  # Argo Rollout'u `kubectl rollout status` TANIMIYOR (o yalnızca yerleşik türleri bilir) ve
  # `kubectl argo rollouts` eklentisi burada kurulu değil. 12+'da hazır olmayı beklemezsek
  # ölçüm, henüz trafiğe girmemiş pod'larla başlar. Hazır replika sayısını kendimiz sayıyoruz.
  for r in $(kubectl -n "$NS" get rollout -o name 2>/dev/null); do
    want=$(kubectl -n "$NS" get "$r" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
    for _ in $(seq 1 90); do
      got=$(kubectl -n "$NS" get "$r" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      (( ${got:-0} >= ${want:-1} )) && break
      sleep 2
    done
  done
}

# Bağımlı bileşenin (redis/postgres/redpanda/...) HAZIR pod'unu ver; yoksa gelmesini bekle.
# Neden: önceki bir deney o pod'u silmiş olabilir (P04-01 Redis'i öldürüyor). O pencerede
# `get pod -o jsonpath` boş liste üzerinde patlar ve script, kendi sorunuyla ilgisiz bir
# hatayla düşer. Bağımlılığın hazır olması ÖLÇÜMÜN ÖNKOŞULUDUR, ölçümün kendisi değil.
dep_pod() {
  local sel=$1 p ready
  for _ in $(seq 1 90); do
    p=$(kubectl -n "$NS" get pod -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$p" ]]; then
      ready=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
      [[ "$ready" == "true" ]] && { echo "$p"; return 0; }
    fi
    sleep 2
  done
  warn "bağımlı bileşen hazır olmadı: $sel"
  return 1
}

# Deney sonrası temizlik GARANTİSİ. Bir reproduce scripti yarıda hata verirse cluster'ı bozuk
# bırakmamalı: cordon'lu node, düşük replika, açık kalmış TRAP env'i sonraki deneyleri sessizce
# çürütür: drain'de hata verip uncordon'a ulaşamayan bir script node'ları cordon'lu bırakır ve
# sıradaki deney "rollout timeout" ile patlar — sebebi kendi kodunda değil, ÖNCEKİ deneydedir.
CLEANUP_CMDS=()
on_cleanup() { CLEANUP_CMDS+=("$1"); }
run_cleanup() {
  local c
  # ARKA PLANDA BAŞLATILAN YÜK ÜRETECİ SCRIPTLE BİRLİKTE ÖLMEZ. Birçok script k6'yı
  # `( k6run ... ) &` ile başlatır; script erken çıkarsa (chaos uygulanamadı → exit 2) k6
  # dakikalarca kümeyi dövmeye devam eder: script "ATLANDI" der ama 300 rps'lik yük sürer, API
  # sunucusu cevap veremez hâle gelir ve bir SONRAKİ deney bozuk bir kümede başlar. k6run her süreci bu scriptin PID'iyle
  # işaretler (LADDER_OWNER, metrik etiketi DEĞİL); temizlik ilk iş onları öldürür.
  # EN: a background load generator does not die with the script that started it; kill ours first.
  pkill -f "LADDER_OWNER=$$ " 2>/dev/null || true
  for (( i=${#CLEANUP_CMDS[@]}-1 ; i>=0 ; i-- )); do
    c="${CLEANUP_CMDS[i]}"
    eval "$c" >/dev/null 2>&1 || true
  done
  CLEANUP_CMDS=()
  # ORTAMI BULDUĞUN GİBİ BIRAK — ve bıraktığından EMİN OL.
  # Temizlik komutlarını çalıştırmak, sistemin geri geldiği anlamına gelmez: 09'da P09-02 bir
  # failover koşuyor, temizliği dönüyor ve script bitiyor; ama uygulama henüz hizmet vermiyor.
  # Sıradaki script `ensure_healthy`de "uygulama hizmet vermiyor" deyip ÇIKIYOR — kendi ölçümüyle
  # ilgisi olmayan bir sebepten. Bekleyecek yer, bozan scriptin kendisidir; bu yüzden bekleme
  # TEMİZLİĞİN SONUNDA ve her script için geçerli.
  # EN: running the cleanup commands is not the same as the system being back. The next script
  # exits at `ensure_healthy` for a reason that has nothing to do with what it measures. The place
  # to wait is the script that broke it, so the wait lives at the END of cleanup, for every script.
  if [[ "${CLEANUP_WAIT:-1}" == "1" ]]; then
    wait_pods_ready_quiet "${CLEANUP_RECOVER_TIMEOUT:-150}" \
      || warn_hard "temizlik bitti ama ortam ${CLEANUP_RECOVER_TIMEOUT:-150} sn'de toparlanmadı: $(not_ready_pods)"
    local i
    for i in $(seq 1 30); do serving && break; sleep 2; done
  fi
}
trap run_cleanup EXIT INT TERM

# Gerçekten hizmet veriyor mu? (Running olmak yetmez: crashloop'taki pod da anlık Running görünür.)
serving() {
  local c
  c=$(curl -sf --max-time 4 -XPOST "$BASE_URL/api/links" -H 'Content-Type: application/json' ${AUTH_HDR[@]+"${AUTH_HDR[@]}"} \
        -d '{"url":"https://example.com/healthprobe"}' 2>/dev/null | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')
  [[ -n "$c" ]]
}

# Seviyenin İLAN ETTİĞİ replika sayısına dön. Önceki bir deney ölçeği değiştirip bıraktıysa (P00-03 gibi)
# sonraki deney yanlış tabandan başlar ve başka bir sorunu ölçtüğünü sanır.
# Deneyin KOŞTUĞU seviyenin deploy/ klasörü. Script dosyasının yeri değil: verify-prev önceki seviyenin
# scriptlerini bu seviyede koşar ve script'in yanındaki manifest o ÖNCEKİ seviyenindir. Oradan okunan
# taban (01'de 1 replika) bu seviyeye (02'de 3) uygulanırsa deney, seviyenin çözdüğü sorunu kendisi geri
# getirir ve "çözüldü" iddiası yanlışlıkla düşer.
level_deploy_dir() {
  local d; d=$(ls -d "$LADDER_ROOT/${LEVEL:-}"-*/ 2>/dev/null | head -1)
  if [[ -n "${LEVEL:-}" && -d "${d%/}/deploy" ]]; then echo "${d%/}/deploy"; else echo "$(dirname "$0")/../deploy"; fi
}
ensure_baseline_scale() {
  local want live svc; svc=$(app_name)
  # Manifest'teki replika sayısını, BU scriptin ilgilendiği iş yükünden oku.
  # "İlk Deployment" yetmez: 07'den sonra deploy/ içinde birden çok iş yükü var (redirect,
  # api, analytics) ve alfabetik sırada gelen başkasının sayısını redirect'e uygulamak sessizce
  # yanlış bir tabandan başlamak demek. 12'den sonra redirect Deployment bile değil (Argo
  # Rollout) — kind listesi ona göre.
  want=$(kubectl kustomize "$(level_deploy_dir)" 2>/dev/null | awk -v want_name="$svc" '
    /^kind: (Deployment|Rollout|StatefulSet)$/ { kind=$2; name=""; reps=""; next }
    /^kind: /                                  { kind="";  name=""; reps=""; next }
    kind != "" && /^  name: /                  { if (name == "") name=$2 }
    kind != "" && /^  replicas: /              { reps=$2 }
    kind != "" && name == want_name && reps != "" { print reps; exit }
  ')
  # Ada göre bulunamadıysa: ilk Deployment (tek servisli seviyeler)
  [[ -z "$want" ]] && want=$(kubectl kustomize "$(level_deploy_dir)" 2>/dev/null \
          | awk '/^kind: Deployment$/{d=1} d&&/^  replicas:/{print $2; exit}')
  [[ -z "$want" ]] && return 0
  live=$(replicas_of)
  if [[ "$live" != "$want" ]]; then
    note "replika sayısı tabana döndürülüyor: $live → $want (manifest'te ilan edilen)"
    scale "$want"
    wait_endpoints "$want"
  fi
}

# Temiz başlangıç noktası — ölçüm yapan her script buradan geçer.
# Neden gerekli: pod CrashLoopBackOff'a düştüğünde kubelet'in geri çekilme süresi 5 dk'ya kadar çıkar;
# o pencerede yeni restart OLMAZ ve "restart arttı mı?" ölçümü yanlış negatif verir. Ayrıca pod'u
# `delete` etmek (rollout restart değil) backoff sayacını sıfırlar: taze bir konteyner, restartCount=0.
# Bu namespace'teki HER iş yükü pod'u hazır mı? (Completed job'lar hariç)
# Neden: CrashLoopBackOff'taki bir broker'ı hiçbir script sormazsa bütün stream deneyleri ÖLÜ
# bir broker'ı ölçer ve "75 bin üretici hatası" gibi sonuçlar bulgu sanılır. Bir deneyin ön
# koşulu da ölçülmesi gereken bir şeydir.
# Hazır olmayan pod'ların adı (tek yerde: ensure_deps_ready ve chaos temizliği aynı tanımı kullansın)
not_ready_pods() {
  kubectl -n "$NS" get pods -o json 2>/dev/null | jq -r '
    [ .items[]
      | select(.status.phase != "Succeeded")
      | select(.metadata.deletionTimestamp == null)
      | select(any(.status.containerStatuses[]?; .ready | not))
      | .metadata.name ] | join(", ")'
}

# ÖLÜMCÜL OLMAYAN bekleyici: temizlik yolunda kullanılır. `ensure_deps_ready` başarısızlıkta
# exit 2 verir; bunu bir temizlik kancasından çağırmak, deneyin HÜKMÜNÜ ezip scripti 2 ile
# bitirir — yani ölçüm doğru yapılmışken sonuç "hata" görünür. Temizlik, sonucu değiştirmemeli.
# EN: the fatal variant would override the experiment's verdict from a cleanup hook and report an
# error for a measurement that actually succeeded. Cleanup must not change the result.
wait_pods_ready_quiet() {
  local budget=${1:-300} waited=0
  while (( waited < budget )); do
    [[ -z "$(not_ready_pods)" ]] && return 0
    sleep 3; waited=$(( waited + 3 ))
  done
  return 1
}

ensure_deps_ready() {
  local bad
  # BEKLE, hemen patlama: bir önceki deneyin rollout'u hâlâ sürüyor olabilir ve "şu an hazır
  # değil" ile "hiç hazır olmayacak" farklı şeylerdir. Hemen exit 2 vermek, normal bir rollout
  # penceresini sonraki TÜM scriptler için zincirleme SKIPPED'e çevirir.
  # BÜTÇE DURUMLU BİLEŞENE GÖRE SEÇİLİR. 2 dakika stateless bir rollout için bol, bir CNPG
  # replikası için AZDIR: 09'da replikaya gecikme enjekte edildikten sonra CNPG replikayı
  # yeniden başlatabilir ve toparlanma 2 dakikayı aşabilir; o bütçeyle sıradaki script "ortam
  # bozuk" deyip çıkar — oysa bu ortamın değil ÖNCEKİ DENEYİN etkisidir. Bekleme bütçesi,
  # beklediğin şeyin doğal toparlanma süresinden kısa olmamalı — yoksa komşu scriptleri
  # zincirleme düşürürsün.
  # EN: two minutes is plenty for a stateless rollout and too little for a CNPG replica: after a
  # replication-delay experiment CNPG may restart the replica and recovery can outlast that
  # budget, so the next script would exit with "environment is broken" — describing the PREVIOUS
  # EXPERIMENT, not the environment. A wait budget must not be shorter than the natural recovery
  # time of the thing you are waiting for.
  local waited=0 budget=${DEPS_TIMEOUT:-300} told=0
  while (( waited < budget )); do
    bad=$(not_ready_pods)
    [[ -z "${bad:-}" ]] && { (( told )) && note "ortam toparlandı (${waited} sn beklendi)"; return 0; }
    if (( waited >= 30 && told == 0 )); then
      note "hazır olmayan pod(lar) bekleniyor: $bad (bütçe ${budget} sn — DEPS_TIMEOUT ile değiştir)"
      told=1
    fi
    sleep 3; waited=$(( waited + 3 ))
  done
  warn "${budget} sn sonra hâlâ hazır olmayan pod(lar): $bad — ortam bozukken ölçüm yapılmaz (kubectl describe)"
  exit 2
}

ensure_healthy() {
  ensure_deps_ready
  ensure_baseline_scale
  for attempt in 1 2 3; do
    if serving; then
      # Eski/terminating pod'lar gidene kadar bekle: ölçüm tek pod üzerinden yapılacak.
      for _ in $(seq 1 30); do
        [[ "$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" --no-headers 2>/dev/null | grep -c .)" -le "$(replicas_of)" ]] && return 0
        sleep 2
      done
      return 0
    fi
    # SINADIĞIN YOLU SUNAN SERVİSİ YENİDEN BAŞLAT. `serving` YAZMA yolunu (POST /api/links) sınar;
    # 07'den itibaren o istek `api` servisine gider. Her durumda $APP_SELECTOR pod'larını
    # (redirect) silmek, api'nin breaker'ı açıkken SAĞLIKLI redirect pod'larını siler ve sorunlu
    # api'ye hiç dokunmaz — görülen "düzelme" bir yan etki olur.
    # EN: restart the workload that serves the path `serving` tests (api from 07 on), not redirect.
    local sel="$APP_SELECTOR"
    kubectl -n "$NS" get deploy/api >/dev/null 2>&1 && sel="app.kubernetes.io/name=api"
    warn "uygulama hizmet vermiyor (önceki deneyden crashloop olabilir) — $sel pod'ları siliniyor, backoff sıfırlanıyor ($attempt/3)"
    kubectl -n "$NS" delete pod -l "$sel" --force --grace-period=0 >/dev/null 2>&1
    wait_ready
    sleep 3
  done
  serving || { warn "uygulama hâlâ ayağa kalkmıyor — önce 'make up' çalıştır"; exit 2; }
}

# Taze pod: backoff sıfırlanır, restartCount 0'dan başlar. Ölçümü restart sayacına dayandıran
# scriptler bunu kullanır — crashloop'taki bir pod'da sayaç DONAR (backoff 5 dk'ya kadar çıkar).
ensure_fresh_pod() {
  kubectl -n "$NS" delete pod -l "$APP_SELECTOR" --force --grace-period=0 >/dev/null 2>&1 || true
  wait_ready
  # İKİ ARDIŞIK BAŞARI: zorla silinen pod'un yerine gelen hazır olmadan, `serving` bir an ölen pod'un
  # açık bağlantısından ya da ingress'in henüz güncellenmemiş endpoint'inden cevap alabilir. Tek bir
  # başarıya güvenen kontrol hemen ardından düşer ve deney hiç başlamadan "ayağa kalkmadı" der.
  local ok=0
  for _ in $(seq 1 45); do
    if serving; then ok=$((ok + 1)); (( ok >= 2 )) && return 0; else ok=0; fi
    sleep 2
  done
  warn "uygulama ayağa kalkmadı — önce 'make up'"; exit 2
}

# Ölümcül hata kanıtı: konteyner şu an ölüyse kendi logunda, yeniden başladıysa --previous logunda ara.
fatal_evidence() {
  local pod=$1 pattern=$2
  kubectl -n "$NS" logs "$pod" --previous --tail=400 2>/dev/null | grep -qF "$pattern" && return 0
  kubectl -n "$NS" logs "$pod" --tail=400 2>/dev/null | grep -qF "$pattern"
}
fatal_line() {
  local pod=$1 pattern=$2
  kubectl -n "$NS" logs "$pod" --previous --tail=400 2>/dev/null | grep -m1 -F "$pattern" \
    || kubectl -n "$NS" logs "$pod" --tail=400 2>/dev/null | grep -m1 -F "$pattern"
}

# 12'den sonra redirect bir Deployment değil, Argo Rollout. Ölçek/okuma yardımcıları iş yükünün
# TÜRÜNÜ sormak zorunda; "deploy" varsaymak "error: no objects passed to scale" ile patlar.
workload_kind() {
  if kubectl -n "$NS" get "rollout/$(app_name)" -o name 2>/dev/null | grep -q .; then
    printf 'rollout'
  else
    printf 'deploy'
  fi
}
# Yalnızca BU scriptin iş yükünü ölçekle, etiketle eşleşen HER ŞEYİ değil.
# 06'dan sonra tüketici (analytics) de `part-of=linkly-ladder` taşır; `scale deploy -l
# "$APP_SELECTOR"` uygulamayla birlikte onu da ölçekler — deney, ölçtüğünü sandığı şeyden
# başka bir şeyi değiştirir.
scale()       { kubectl -n "$NS" scale "$(workload_kind)/$(app_name)" --replicas="$1" >/dev/null; wait_ready; }
# Service endpoint'leri ölçeğe yetişene kadar bekle. rollout status "pod hazır" der ama ingress'in
# upstream listesi birkaç saniye geriden gelir; o pencerede tüm istekler TEK pod'a düşer ve
# yük dağılımına dayanan deneyler (P00-03 gibi) yanlış negatif verir.
# Bu scriptin ilgilendiği iş yükünün ADI. 00-06'da tek servis var (linkly); 07'den sonra
# uygulama redirect/api diye BÖLÜNÜYOR ve scriptler APP_SELECTOR'ü buna göre değiştiriyor.
# Servis adını sabit "linkly" varsaymak, 07+ seviyelerde wait_endpoints'i her seferinde
# 60 saniye boş bekletip uyarı bastırır — sessiz ama her deneye 1 dakika ekleyen bir hata.
app_name() {
  case "$APP_SELECTOR" in
    *app.kubernetes.io/name=*) printf '%s' "${APP_SELECTOR##*app.kubernetes.io/name=}"; return ;;
  esac
  # APP_SELECTOR ad vermiyorsa KÜMEYE SOR. Neden: 06'nın scriptleri 07'nin `verify-prev`inde
  # koşar; orada uygulama redirect/api diye bölünmüştür ve sabit yazılmış bir `deploy/linkly`
  # "deployments.apps 'linkly' not found" ile ERROR verir. Merdivenin kontratı "bir sonraki
  # seviye bunu ÇÖZER" demek; scriptin çalışamaması bunu DOĞRULAMAZ, yalnızca gizler.
  local n
  for n in linkly redirect app; do
    kubectl -n "$NS" get "deploy/$n" >/dev/null 2>&1 && { printf '%s' "$n"; return; }
    kubectl -n "$NS" get "rollout/$n" >/dev/null 2>&1 && { printf '%s' "$n"; return; }
  done
  printf 'linkly'
}
# ADI VERİLEN iş yükünün tam referansı: `deploy/api` mi `rollout/api` mi?
# Neden: 12'den sonra redirect bir Argo Rollout. 11'in scriptleri 12'nin verify-prev'inde koşar;
# sabit bir `deploy/redirect` orada toptan ERROR verir — "bir sonraki seviye bunu çözer" iddiası
# doğrulanamaz, yalnızca gizlenir. Türü koda gömme, KÜMEYE sor.
wl() {
  local n=$1
  if kubectl -n "$NS" get "rollout/$n" >/dev/null 2>&1; then printf 'rollout/%s' "$n"
  else printf 'deploy/%s' "$n"; fi
}
# Bu seviyedeki uygulama iş yükünün tam adı: `deploy/linkly` ya da `rollout/redirect`.
app_workload() { printf '%s/%s' "$(workload_kind)" "$(app_name)"; }

# `kubectl set env` / `set resources` CRD'LERDE ÇALIŞMAZ.
# EN: These are client-side typed commands: kubectl needs the resource's Go type in its compiled
#     scheme. For an Argo Rollout it fails with `no kind "Rollout" is registered for version
#     "argoproj.io/v1alpha1"`. From level 12 on, `redirect` IS a Rollout — so a plain `set env`
#     (every TRAP toggle, every cleanup) dies there, and `verify-prev` on 12/13/14 would re-run
#     earlier levels' experiments that cannot change anything. The scripts would still print a
#     verdict; it would just be measuring an unchanged system.
#     A command that is silently type-specific is worse than one that is loudly unsupported.
# TR: Bunlar istemci tarafı TİPLİ komutlar: kubectl'in kaynağın Go tipini derlenmiş şemasında
#     görmesi gerekir. Argo Rollout'ta `no kind "Rollout" is registered ...` ile patlar.
#     12'den itibaren `redirect` bir Rollout — yani düz bir `set env` (her TRAP anahtarı, her
#     temizlik) orada ölür ve 12/13/14'ün `verify-prev`i HİÇBİR ŞEYİ değiştiremeyen deneyleri
#     yeniden koşar. Scriptler yine bir karar basar; yalnızca DEĞİŞMEMİŞ bir sistemi ölçerler.
#     Sessizce tipe bağlı olan bir komut, açıkça desteklenmeyenden daha kötüdür.
# Kullanım: setenv "$(wl redirect)" KEY=VAL OTHER-     (sonuna `-` → değişkeni SİL)
setenv() {
  local w=$1; shift
  # DİKKAT: burada `kubectl set env` yazmak ZORUNLU — `setenv` yazmak fonksiyonun KENDİSİNİ
  # çağırır: yardımcı sonsuz özyinelemeye girip "Segmentation fault: 11" ile çöker ve Deployment
  # hedefleyen HER deney (yani merdivenin çoğu) HATA verir; Rollout hedefleyenler diğer daldan
  # geçtiği için çalışmaya devam eder ve hata gizlenir. Çağrı yerlerini toplu değiştiren bir sed,
  # bu satırı da değiştirir.
  # EN: this must say `kubectl set env`, not `setenv` — otherwise the helper calls itself until
  # the stack blows up. A bulk sed over the call sites rewrites this line too.
  # Ders: toplu değiştirme, değiştirdiği şeyin TANIMINI de kapsar. Yeniden yazdığın fonksiyonun
  # kendi gövdesini her zaman gözle kontrol et.
  [[ "${w%%/*}" != "rollout" ]] && { kubectl -n "$NS" set env "$w" "$@" >/dev/null; return; }
  local cur a k v
  cur=$(kubectl -n "$NS" get "$w" -o json 2>/dev/null | jq -c '.spec.template.spec.containers[0].env // []') || return 1
  for a in "$@"; do
    if [[ "$a" == *- && "$a" != *=* ]]; then
      k=${a%-}; cur=$(jq -c --arg k "$k" 'map(select(.name != $k))' <<<"$cur")
    else
      k=${a%%=*}; v=${a#*=}
      cur=$(jq -c --arg k "$k" --arg v "$v" 'map(select(.name != $k)) + [{name:$k,value:$v}]' <<<"$cur")
    fi
  done
  # JSON Patch "add": var olan bir alanı DA değiştirir, yoksa yaratır — "replace" ikisini yapmaz.
  kubectl -n "$NS" patch "$w" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":$cur}]" >/dev/null
}
# Kullanım: setres "$(wl redirect)" --requests=cpu=100m --limits=cpu=50m
setres() {
  local w=$1; shift
  [[ "${w%%/*}" != "rollout" ]] && { kubectl -n "$NS" set resources "$w" "$@" >/dev/null; return; }
  local cur a kind spec key val
  cur=$(kubectl -n "$NS" get "$w" -o json 2>/dev/null | jq -c '.spec.template.spec.containers[0].resources // {}') || return 1
  for a in "$@"; do
    kind=${a%%=*}; kind=${kind#--}; kind=${kind%s}   # --requests → request
    spec=${a#*=}                                      # cpu=100m
    key=${spec%%=*}; val=${spec#*=}
    case "$kind" in
      request) cur=$(jq -c --arg k "$key" --arg v "$val" '.requests[$k]=$v' <<<"$cur") ;;
      limit)   cur=$(jq -c --arg k "$key" --arg v "$val" '.limits[$k]=$v'   <<<"$cur") ;;
    esac
  done
  kubectl -n "$NS" patch "$w" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/resources\",\"value\":$cur}]" >/dev/null
}
wait_endpoints() {
  local want=$1 got svc; svc=$(app_name)
  for _ in $(seq 1 30); do
    got=$(kubectl -n "$NS" get endpointslice -l "kubernetes.io/service-name=$svc" \
            -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[0]}{"\n"}{end}{end}' 2>/dev/null | count_lines)
    (( got >= want )) && { sleep 3; return 0; }
    sleep 2
  done
  warn "endpoint sayısı $want'e ulaşmadı (servis=$svc, şu an $got)"
}

replicas_of() { kubectl -n "$NS" get "$(workload_kind)/$(app_name)" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1; }
# cAdvisor bu ortamda `container` label'ı üretmiyor → konteyner serilerini image üzerinden seç (bkz. dashboards/gen.py).
# Örneklenen tepe bellek. DİKKAT: Prometheus 15 sn'de bir örnekler; hızlı dolup ölen bir konteynerin
# gerçek tepesini KAÇIRIR (örnekler arasında doldu, öldü, sıfırdan başladı). Yani bu değer daima
# gerçek tepenin altındadır — asıl kanıt OOMKilled/exit 137'dir. (Bu örnekleme sorunu 11'de geri gelir.)
peak_working_set_mb() { promq "max_over_time(max(container_memory_max_usage_bytes{namespace=\"$NS\",image!=\"\",image!~\".*pause.*\"})[${1:-15m}:15s]) / 1024 / 1024" | cut -d. -f1; }
exit_code_of() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null; }
working_set_mb() { promq "sum(container_memory_working_set_bytes{namespace=\"$NS\",image!=\"\",image!~\".*pause.*\"}) / 1024 / 1024" | cut -d. -f1; }

# Pod'a doğrudan bağlan (ingress'i atla): "korumayı kim veriyor, uygulama mı önündeki katman mı?"
# sorusunu ayırt etmek için şart. Temizlik ortak: `wait` öldürülen işin 143'ünü döndürür ve
# `set -e` altında scripti sessizce öldürür — bu yüzden her yerde `|| true`.
PF_PID=""
port_forward() {
  local pod=$1 lport=$2
  kubectl -n "$NS" port-forward "pod/$pod" "$lport:8080" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 15); do
    curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$lport/healthz" && break
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$lport/" && break
    sleep 1
  done
}
port_forward_stop() { [[ -n "$PF_PID" ]] && { kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; PF_PID=""; }; return 0; }

# HAZIR ve silinmekte OLMAYAN bir pod seç.
# `items[0]` rollout'tan sonra hâlâ listede duran TERMINATING pod'u verebilir; 150 saniyelik
# örnekleme boyunca her istek "connection refused" alır. Aynı kod başka bir anda çalışır — çünkü
# o an items[0] şansa canlı pod'dur. Şansa dayanan bir seçim, ölçümün bir parçası değildir.
pod_name() {
  kubectl -n "$NS" get pod -l "$APP_SELECTOR" -o json 2>/dev/null \
    | jq -r '[.items[]
              | select(.metadata.deletionTimestamp == null)
              | select(any(.status.containerStatuses[]?; .ready))
              | .metadata.name][0] // empty'
}
restarts_of() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0; }

# Çökme kanıtı: belirtilen pod'un ÖNCEKİ konteyner loglarında kalıp var mı?
crash_evidence_of() {
  local pod=$1 pattern=$2
  kubectl -n "$NS" logs "$pod" --previous --tail=300 2>/dev/null | grep -qF "$pattern"
}
crash_line_of() {
  kubectl -n "$NS" logs "$1" --previous --tail=300 2>/dev/null | grep -m1 -F "$2"
}

# k6: senaryo adı + ek argümanlar. Özet JSON'u $K6_SUMMARY'ye yazar.
K6_SUMMARY=${K6_SUMMARY:-/tmp/k6-$NS-$PROBLEM_ID.summary.json}
# Her yük koşusu ZAMAN SINIRLI: süre + 4 dk pay (setup/teardown). Bir k6 takılırsa yalnızca o
# adım düşer, arkasındaki turun tamamı değil.
k6run() {
  local s=$1; shift
  # NOT: döngü gövdesinin son komutu `[[ ]] && ...` olursa döngünün çıkış kodu 1 olur ve
  # `set -e` fonksiyonu orada bitirir — kolay gözden kaçan bir tuzak. `if` kullan.
  local args=("$@") dur="" secs=300 i
  for (( i=0; i<${#args[@]}; i++ )); do
    if [[ "${args[i]}" == "--duration" ]]; then dur="${args[i+1]:-}"; fi
  done
  if [[ -n "$dur" ]]; then
    case "$dur" in
      *m) secs=$(( ${dur%m} * 60 )) ;;
      *s) secs=${dur%s} ;;
      *)  secs=$dur ;;
    esac
  fi
  # --duration yoksa senaryo kendi aşamalarını (stages) tanımlıyordur: stairs ~200 sn,
  # burst ~70 sn. 300 sn taban + 240 sn pay, hepsini rahatça kapsar.
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=300
  # ESKİ ÖZET, BU KOŞUNUN ÖZETİNDEN AYIRT EDİLEMEZ.
  # `$K6_SUMMARY` problem başına sabit bir dosyadır ve koşular arasında DİSKTE KALIR. k6 bu kez
  # hiç başlamadıysa ya da özet yazmadan düştüyse, `_k6q` yalnızca "dosya var mı?" diye bakar ve
  # ÖNCEKİ TURDAN kalma sayıları bu turun sonucu sanır — ör. 897 istekte 73710 adet 5xx gibi
  # fiziksel olarak imkânsız bir sayı. Önce sil: dosyanın yokluğu "ölçemedik" demektir ve bu,
  # yanlış bir sayıdan iyidir.
  # EN: `$K6_SUMMARY` is a fixed per-problem path that SURVIVES between runs. If k6 never started
  # or died before exporting, `_k6q` only checks that the file exists and reads LAST ROUND's
  # numbers as this round's result — e.g. 73710 5xx out of 897 requests, physically
  # impossible. Delete first: an absent file means "we could not measure", which beats a number
  # that is quietly wrong.
  rm -f "$K6_SUMMARY"
  # Her fazın kanıtı SAKLANSIN: iki fazlı bir deneyde ikinci koşu birincinin özetini ezer ve
  # sonradan "o sayı nereden geldi?" diye bakacak hiçbir şey kalmaz.
  K6_RUN_SEQ=$(( ${K6_RUN_SEQ:-0} + 1 ))
  local rc=0
  K6_OWNER=$$ with_timeout $(( secs + 240 )) "$LADDER_ROOT/platform/lib/k6run.sh" "$s" --summary-export "$K6_SUMMARY" ${args[@]+"${args[@]}"} || rc=$?
  if [[ -s "$K6_SUMMARY" ]]; then cp "$K6_SUMMARY" "${K6_SUMMARY%.json}.$K6_RUN_SEQ.json" 2>/dev/null || true; fi
  return $rc
}
# k6 özeti YOKSA (koşu hiç başlamadıysa) jq dosya bulamayıp hata veriyor ve `set -e` scripti
# öldürüyor. Yokluk bir ölçüm sonucudur: 0 döndür ama STDERR'e söyle.
_k6q() {
  [[ -s "$K6_SUMMARY" ]] || { printf '  \033[33mk6 özeti yok (%s) — 0 sayıldı\033[0m\n' "$K6_SUMMARY" >&2; echo 0; return 0; }
  jq -r "$1" "$K6_SUMMARY" 2>/dev/null || echo 0
}
k6_failed_rate() { _k6q '.metrics.http_req_failed.value // .metrics.http_req_failed.rate // 0'; }
k6_reqs()        { _k6q '.metrics.http_reqs.count // 0'; }
# 5xx ve 404'ü ayrı oku: biri altyapı kesintisi, diğeri uygulamanın "yok" demesi (bkz. platform/k6/lib/ladder.js).
k6_5xx()         { _k6q '.metrics.http_5xx.count // 0'; }
k6_404()         { _k6q '.metrics.http_404.count // 0'; }
k6_429()         { _k6q '.metrics.http_429.count // 0'; }
