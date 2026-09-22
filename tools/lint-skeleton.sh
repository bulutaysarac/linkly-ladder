#!/usr/bin/env bash
# Seviye iskeleti şablonla aynı mı? Sapma = hata. Kullanım: tools/lint-skeleton.sh 03-local-cache
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
L=${1:?seviye klasörü}; L=${L%/}; D="$ROOT/$(basename "$L")"; [[ -d "$D" ]] || D="$L"
name=$(basename "$D"); lvl=${name%%-*}; nm=${name#*-}
fail=0; err() { echo "  ✘ $name: $*"; fail=1; }

# 1. Zorunlu dosyalar
for f in README.md Makefile go.mod Dockerfile deploy/kustomization.yaml problems/SOLVES; do
  [[ -e "$D/$f" ]] || err "eksik: $f"
done
[[ -n "$(ls "$D"/cmd 2>/dev/null)" ]] || err "cmd/ boş"
[[ -n "$(ls "$D"/problems/P*.sh 2>/dev/null)" ]] || err "problems/ içinde P*.sh yok"

# 2. Makefile tam olarak 3 satır (LEVEL, NAME, include)
exp=$(printf 'LEVEL := %s\nNAME  := %s\ninclude ../ladder.mk\n' "$lvl" "$nm")
[[ "$(cat "$D/Makefile")" == "$exp" ]] || err "Makefile şablondan sapmış (LEVEL/NAME/include dışında satır olamaz)"

# 3. Dockerfile şablonla birebir aynı
diff -q "$ROOT/docs/skeleton/Dockerfile" "$D/Dockerfile" >/dev/null || err "Dockerfile docs/skeleton/Dockerfile ile aynı değil"

# 4. Yasaklı klasörler (seviyede olmaması gerekenler)
for x in dashboards load chaos charts helm; do [[ -e "$D/$x" ]] && err "seviyede olmamalı: $x/ (platform/'da tek kopya)"; done

# 5. go.mod modül yolu
grep -q "^module github.com/bulutaysarac/linkly-ladder/$name\$" "$D/go.mod" || err "go.mod modül adı: github.com/bulutaysarac/linkly-ladder/$name olmalı"

# 5b. go.work OLMADAN derlenebilmeli. Docker imajında go.work YOKTUR; yalnızca go.mod + go.sum
#     vardır. Yerelde go.work bağımlılıkları çözüp eksik go.sum girdilerini gizler ve hata ancak
#     `make up` sırasında, imaj derlenirken ortaya çıkar. Bu kural onu lint zamanına çeker.
# `-o <dizin>/` şart: tek bir main paketi olan modülde (00) düz `go build ./...` ikiliyi
# ÇALIŞTIĞI DİZİNE bırakıyor ve 8 MB'lık bir Mach-O bir kez depoya girdi.
_out=$(mktemp -d)
(cd "$D" && GOWORK=off go build -o "$_out/" ./... >/dev/null 2>&1) || err "GOWORK=off go build başarısız (go.sum eksik olabilir → go mod tidy)"
rm -rf "$_out"

# 6. README: 10 başlık sırayla + sabit metinler
heads=("## 1. Bu seviye ne?" "## 2. Mimari" "## 3. Önceki seviyeden çözülenler" "## 4. Ayağa kaldırma" "## 5. API" \
       "## 6. Reproduce edilebilir sorunlar" "## 7. Seviye içi alıştırmalar" "## 8. Gözlemlenebilirlik" "## 9. Bilerek bırakılanlar" "## 10. \`make diff-prev\`")
prev=0
for h in "${heads[@]}"; do
  n=$(grep -n -F "$h" "$D/README.md" | head -1 | cut -d: -f1 || true)
  [[ -n "$n" ]] || { err "README başlık eksik: $h"; continue; }
  (( n > prev )) || err "README başlık sırası bozuk: $h"; prev=$n
done
grep -q 'make up            # build → push → deploy → rollout wait → smoke' "$D/README.md" || err "README §4 sabit metin değişmiş"
grep -q 'Her seviyede aynı: \[docs/API.md\]' "$D/README.md" || err "README §5 sabit metin değişmiş"

# 7. Her problems/P*.sh README'de "### PNN-XX" bölümüne sahip mi, ve tersi
for f in "$D"/problems/P*.sh; do id=$(basename "${f%.sh}"); grep -q "^### $id" "$D/README.md" || err "README'de bölüm yok: ### $id"; done
for id in $(grep -o '^### P[0-9][0-9]-[0-9][0-9]' "$D/README.md" | cut -c5-); do [[ -f "$D/problems/$id.sh" ]] || err "script yok: problems/$id.sh"; done
# 7b. SOLVES: ilk seviye dışında BOŞ OLAMAZ. Boş bir SOLVES, `make verify-prev`'i sessizce
#     etkisiz kılar: her sonuç "açık kalabilir" sayılır ve regresyon yakalanmaz. Gerçekte oldu —
#     bir zsh glob hatası (`rm -f P0X-*.sh &&` boş eşleşmede zinciri kırar) dosyayı hiç yazmadı.
if [[ "$lvl" != "00" ]]; then
  # SOLVES tamamen BOŞ olamaz; ama bir seviye bir öncekinden hiçbir şey çözmüyor da olabilir
  # (08 dağıtık limiter getiriyor, 07'nin sorunlarından hiçbirini çözmüyor). O zaman dosyada
  # bunu YAZAN bir `#` yorumu olmalı: iddia yoksa gerekçe olsun. Sessiz boşluk yasak, çünkü
  # verify-prev'i sessizce etkisizleştiriyor.
  [[ -s "$D/problems/SOLVES" ]] || err "problems/SOLVES boş — ya çözülen ID'leri yaz ya da '#' ile gerekçesini"
  ids=0
  while read -r id; do
    [[ -z "$id" ]] && continue
    [[ "$id" == \#* ]] && continue
    ids=$((ids+1))
    [[ "$id" =~ ^P[0-9][0-9]-[0-9][0-9]$ ]] || err "SOLVES'ta geçersiz satır: '$id'"
    [[ "$id" == P$lvl-* ]] && err "SOLVES kendi seviyesinin sorununu içeremez: $id"
    # TRAP tabanlı sorun SOLVES'a yazılamaz: script tuzağı kendisi açtığı için her seviyede
    # reproduce olur ve doğrulamayı kalıcı olarak kırar (08, P07-06 ile bunu yaptı).
    prevdir=$(ls -d "$ROOT"/[0-9][0-9]-*/ | sort | awk -v cur="$D/" '$0==cur{print prev; exit}{prev=$0}')
    if [[ -n "$prevdir" && -f "$prevdir/problems/$id.sh" ]] && grep -qE 'setenv.*TRAP_' "$prevdir/problems/$id.sh"; then
      err "SOLVES'ta TRAP tabanlı sorun: $id — tuzak duruyorsa her seviyede reproduce olur"
    fi
  done < "$D/problems/SOLVES"
  (( ids == 0 )) && grep -q '^#' "$D/problems/SOLVES" \
    || (( ids > 0 )) || err "SOLVES'ta ne ID ne gerekçe var"
fi

# 8. Sorun ID'leri bu seviyenin numarasını taşımalı
for f in "$D"/problems/P*.sh; do id=$(basename "${f%.sh}"); [[ "$id" == P$lvl-* ]] || err "yabancı sorun ID'si: $id (P$lvl-XX olmalı)"; done

# 9. ÖLÜ TUZAK: config'de tanımlı ama kodda hiç OKUNMAYAN TRAP_*
# EN: this is the most expensive silent failure the ladder produced. A trap declared in config and
#     read nowhere means the experiment flips a flag, nothing changes, and the script still prints
#     a verdict — usually "REPRODUCED", judged by some other number that drifts on its own.
#     TRAP_TENANT_LABEL, TRAP_FIXED_WINDOW, TRAP_NO_SINGLEFLIGHT and TRAP_UNBOUNDED_QUEUE were all
#     in this state at once. A lint is cheaper than finding it again.
#     A field that is only PRINTED (main's trap-status map) does not count as read — that line
#     contains the literal "TRAP_", so it is excluded.
# TR: merdivenin ürettiği en pahalı sessiz arıza sınıfı bu. Config'de tanımlı, kodda okunmayan bir
#     tuzak: deney bayrağı açar, hiçbir şey değişmez ve script yine karar basar — genelde kendi
#     başına oynayan başka bir sayıya bakarak "REPRODUCED". Dört tuzak aynı anda bu hâldeydi.
#     Yalnızca BASTIRILAN bir alan (main'in tuzak durumu haritası) okunmuş SAYILMAZ: o satır
#     "TRAP_" dizgesini içerdiği için dışarıda bırakılıyor.
cfg="$D/internal/config/config.go"
if [[ -f "$cfg" ]]; then
  live=$(find "$D" -name '*.go' ! -name config.go -exec grep -h . {} + 2>/dev/null | grep -v '"TRAP_' || true)
  while read -r field env; do
    [[ -z "$field" ]] && continue
    grep -q "\.$field\b" <<< "$live" || err "ölü tuzak: $env (cfg.$field) config'de var, kodda okunmuyor"
  done < <(grep -oE '[A-Za-z]+:[[:space:]]*env[A-Za-z]*\("TRAP_[A-Z0-9_]+"' "$cfg" \
             | sed -E 's/([A-Za-z]+):[[:space:]]*env[A-Za-z]*\("(TRAP_[A-Z0-9_]+)"/\1 \2/')
fi

# 10. README, VAR OLMAYAN bir tuzağı ÖNERİYOR mu?
# EN: rule 9 catches a flag that exists in config but nothing reads. This catches the opposite
#     direction: the README's exercise table tells the reader to set a flag that no longer exists
#     at all. They set it, nothing happens, and they conclude the technique does not work — the
#     same failure as the pprof endpoint that was documented but never registered.
#     Only the exercise table is checked (a row whose first cell is `TRAP_…`), so prose that
#     EXPLAINS a removed flag stays legal — and that prose is usually the right thing to write.
# TR: 9. kural config'de olup kimsenin okumadığı bayrağı yakalar. Bu, ters yönü yakalar: README'nin
#     alıştırma tablosu, artık HİÇ var olmayan bir bayrağı ayarlamayı söylüyor. Okuyucu ayarlar,
#     hiçbir şey olmaz ve tekniğin çalışmadığı sonucuna varır — belgelenmiş ama hiç kaydedilmemiş
#     pprof ucuyla aynı arıza.
#     Yalnızca alıştırma tablosu denetlenir (ilk hücresi `TRAP_…` olan satır); kaldırılmış bir
#     bayrağı AÇIKLAYAN düzyazı serbest kalır — ki yazılması gereken şey genelde odur.
if [[ -f "$cfg" && -f "$D/README.md" ]]; then
  while read -r t; do
    [[ -z "$t" ]] && continue
    grep -q "\"$t\"" "$cfg" || err "README var olmayan tuzağı öneriyor: $t (config'de yok)"
  done < <(grep -oE '^\| `(TRAP_[A-Z0-9_]+)`' "$D/README.md" | grep -oE 'TRAP_[A-Z0-9_]+' | sort -u)
fi

# 11. YEREL SARMALAYICI KENDİ ADINI ÇAĞIRMASIN.
# EN: `setenv() { setenv ...; }` recurses until the stack blows up and the script hangs instead of
#     measuring. It happened twice tonight, both times because a bulk rename rewrote the wrapper's
#     body along with the call sites. Only single-line wrappers whose body starts with a SHELL
#     word equal to the function name are flagged, so `psql() { kubectl exec ... psql ...; }` —
#     where the inner `psql` is a binary inside the container — stays legal.
# TR: `setenv() { setenv ...; }` yığın taşana kadar özyineler ve script ölçüm yapmak yerine asılır.
#     Bu gece iki kez oldu; ikisinde de toplu bir yeniden adlandırma, çağrı yerleriyle birlikte
#     sarmalayıcının GÖVDESİNİ de değiştirdi. Yalnızca gövdesi fonksiyon adıyla BAŞLAYAN tek
#     satırlık sarmalayıcılar işaretlenir; `psql() { kubectl exec ... psql ...; }` gibi içteki ad
#     konteyner içindeki bir ikili olduğunda serbest kalır.
for f in "$D"/problems/P*.sh; do
  [[ -e "$f" ]] || continue
  while IFS= read -r line; do
    fn=${line%%(*}
    body=${line#*\{}
    body=$(printf '%s' "$body" | sed 's/^[[:space:]]*//')
    [[ "${body%% *}" == "$fn" ]] && err "$(basename "$f"): $fn() kendini çağırıyor (özyineleme)"
  done < <(grep -E '^[a-z_][a-z0-9_]*\(\)[[:space:]]*\{.*\}[[:space:]]*$' "$f" || true)
done

# 12. BAĞIMLILIK KURULDU AMA BAĞLANMADI: nil bir alanın arkasındaki tuzak GÖRÜNMEZdir.
# EN: every `cmd/*/main.go` that builds a Redis client AND an httpapi must also hand the client to
#     the API. Levels 04-06 did; 07-14 did not, so `a.rdb` stayed nil and
#     `TRAP_READY_CHECKS_REDIS` (P10-02) read its flag, saw nil and did nothing. The experiment
#     ran, measured no difference and reported "readiness is fine" — the opposite of the lesson.
#     Rule 9 could not catch it: the flag WAS read. A flag behind a nil dependency is not
#     disabled, it is invisible — nothing fails and nothing logs.
# TR: Redis istemcisi VE httpapi kuran her `cmd/*/main.go`, istemciyi API'ye de vermek zorundadır.
#     04-06 veriyordu, 07-14 vermiyordu; `a.rdb` nil kalıyor ve `TRAP_READY_CHECKS_REDIS` (P10-02)
#     bayrağını okuyup nil görüyor ve hiçbir şey yapmıyordu. Deney koşuyor, fark bulamıyor ve
#     "readiness sorunsuz" diyordu — dersin tam tersi. 9. kural bunu yakalayamazdı, çünkü bayrak
#     OKUNUYORDU. Nil bir bağımlılığın arkasındaki bayrak kapalı değil GÖRÜNMEZdir.
for f in "$D"/cmd/*/main.go; do
  [[ -e "$f" ]] || continue
  grep -q 'redis.NewClient' "$f" || continue
  grep -q 'httpapi.New(' "$f" || continue
  grep -q 'SetRedis(' "$f" || err "$(basename "$(dirname "$f")")/main.go: redis.NewClient var ama api.SetRedis çağrılmıyor — Redis'e bağlı tuzaklar sessizce ölü"
done

# 13. İÇ İÇE TIRNAKLI KOMUT İKAMESİ SORGUYU SESSİZCE BOZAR.
# EN: `num "$(promq "...{namespace=\"$NS\",code!=\"503\"}...")"` does NOT pass what it looks like.
#     Inside `"$( ... )"` the inner `\"` escapes end the inner quoting, the `{a,b}` is left
#     unquoted and bash BRACE-EXPANDS it: the braces disappear and the selector is cut in half.
#     Prometheus then answers `parse error: unexpected "=" in aggregation`, `promq` returns 0 and
#     the experiment compares zeros — P10-06 printed "p99=0 ms" for BOTH phases and P07-03 built a
#     verdict on a baseline of zero. 45 call sites in 26 files were affected. Call it plainly:
#     `x=$(promq "...")` — promq already normalises NaN/Inf, so the `num` wrapper is redundant.
# TR: `num "$(promq "...")"` göründüğü şeyi GEÇİRMEZ. `"$( ... )"` içinde iç `\"` kaçışları iç
#     tırnaklamayı bitirir, `{a,b}` tırnaksız kalır ve bash onu SÜSLÜ PARANTEZ GENİŞLETMESİne
#     sokar: parantezler kaybolur, seçici ikiye bölünür. Prometheus `parse error` der, `promq` 0
#     döndürür ve deney sıfırları karşılaştırır — P10-06 iki fazda da "p99=0 ms" bastı, P07-03
#     hükmünü sıfır bir tabanın üstüne kurdu. 26 dosyada 45 çağrı etkilenmişti. Düz çağır:
#     `x=$(promq "...")` — promq zaten NaN/Inf normalleştiriyor, `num` sarmalayıcısı gereksiz.
for f in "$D"/problems/P*.sh; do
  [[ -e "$f" ]] || continue
  if grep -Fq '"$(promq "' "$f"; then
    err "$(basename "$f"): iç içe tırnaklı \$(promq ...) — süslü parantezler genişler, sorgu bozulur"
  fi
done

[[ $fail == 0 ]] && echo "  ✔ $name iskelet OK"
exit $fail
