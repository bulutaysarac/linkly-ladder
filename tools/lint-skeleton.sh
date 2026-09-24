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
# ÇALIŞTIĞI DİZİNE bırakır — her lint koşusu seviyenin içine 8 MB'lık bir ikili yazar ve o
# dosya kolayca depoya girer.
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
grep -qF "make up            # profil → Grafana'yı temizle → build → push → deploy → rollout wait → smoke" "$D/README.md" || err "README §4 sabit metin değişmiş"
grep -q 'Her seviyede aynı: \[docs/API.md\]' "$D/README.md" || err "README §5 sabit metin değişmiş"
# 6a. Giriş bloğu: okuyucu §1'den önce ne yaşayacağını, seviye olmasa ne olacağını ve yeni araçları görür.
for m in '> **Bu seviyede ne yaşayacaksın?**' '> **Bu seviye olmasa ne olur?**' '> **Yeni gelen teknolojiler:**'; do
  n=$(grep -n -F -- "$m" "$D/README.md" | head -1 | cut -d: -f1 || true)
  s1=$(grep -n -F '## 1. Bu seviye ne?' "$D/README.md" | head -1 | cut -d: -f1 || true)
  [[ -n "$n" && -n "$s1" ]] && (( n < s1 )) || err "README giriş bloğu eksik ya da §1'den sonra: $m"
done
# 6b. Yabancı biri için giriş kapısı: §4 kök rehbere bağlanmalı, §7 alıştırmaların NASIL uygulanacağını söylemeli.
grep -q 'README.md#sıfırdan-başlangıç' "$D/README.md" || err "README §4: Sıfırdan başlangıç bağlantısı yok"
grep -q '\*\*Nasıl uygulanır:\*\* aç .make set' "$D/README.md" || err "README §7: 'Nasıl uygulanır' (make set/unset) notu yok"

# 7. Her problems/P*.sh README'de "### PNN-XX" bölümüne sahip mi, ve tersi
for f in "$D"/problems/P*.sh; do id=$(basename "${f%.sh}"); grep -q "^### $id" "$D/README.md" || err "README'de bölüm yok: ### $id"; done
for id in $(grep -o '^### P[0-9][0-9]-[0-9][0-9]' "$D/README.md" | cut -c5-); do [[ -f "$D/problems/$id.sh" ]] || err "script yok: problems/$id.sh"; done
# 7b. SOLVES: ilk seviye dışında BOŞ OLAMAZ. Boş bir SOLVES, `make verify-prev`'i sessizce
#     etkisiz kılar: her sonuç "açık kalabilir" sayılır ve regresyon yakalanmaz. Boş dosya kolay
#     oluşur: onu yazan zincir yarıda kalırsa (zsh'de `rm -f P0X-*.sh &&` boş eşleşmede zinciri
#     kırar) dosya hiç yazılmaz.
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
    # reproduce olur ve doğrulamayı kalıcı olarak kırar.
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
# EN: this is the most expensive kind of silent failure. A trap declared in config and read
#     nowhere means the experiment flips a flag, nothing changes, and the script still prints a
#     verdict — usually "REPRODUCED", judged by some other number that drifts on its own. Several
#     traps can drift into this state at once without any test failing; a lint is cheaper than
#     finding them by measurement.
#     A field that is only PRINTED (main's trap-status map) does not count as read — that line
#     contains the literal "TRAP_", so it is excluded.
# TR: en pahalı sessiz arıza sınıfı bu. Config'de tanımlı, kodda okunmayan bir tuzak: deney
#     bayrağı açar, hiçbir şey değişmez ve script yine karar basar — genelde kendi başına oynayan
#     başka bir sayıya bakarak "REPRODUCED". Birden çok tuzak, hiçbir test kırılmadan aynı anda bu
#     hâle düşebilir; bir lint, onları ölçerek bulmaktan ucuzdur.
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
#     direction: the README's exercise table tells the reader to set a flag that does not exist
#     at all. They set it, nothing happens, and they conclude the technique does not work — the
#     same failure as documenting an endpoint that is never registered.
#     Only the exercise table is checked (a row whose first cell is `TRAP_…`), so prose that
#     EXPLAINS why a flag does not exist stays legal — and that prose is usually the right thing to write.
# TR: 9. kural config'de olup kimsenin okumadığı bayrağı yakalar. Bu, ters yönü yakalar: README'nin
#     alıştırma tablosu, HİÇ var olmayan bir bayrağı ayarlamayı söyler. Okuyucu ayarlar, hiçbir
#     şey olmaz ve tekniğin çalışmadığı sonucuna varır — belgelenip hiç kaydedilmeyen bir uçla
#     aynı arıza.
#     Yalnızca alıştırma tablosu denetlenir (ilk hücresi `TRAP_…` olan satır); bir bayrağın neden
#     olmadığını AÇIKLAYAN düzyazı serbest kalır — ki yazılması gereken şey genelde odur.
if [[ -f "$cfg" && -f "$D/README.md" ]]; then
  while read -r t; do
    [[ -z "$t" ]] && continue
    grep -q "\"$t\"" "$cfg" || err "README var olmayan tuzağı öneriyor: $t (config'de yok)"
  done < <(grep -oE '^\| `(TRAP_[A-Z0-9_]+)`' "$D/README.md" | grep -oE 'TRAP_[A-Z0-9_]+' | sort -u)
fi

# 11. YEREL SARMALAYICI KENDİ ADINI ÇAĞIRMASIN.
# EN: `setenv() { setenv ...; }` recurses until the stack blows up and the script hangs instead of
#     measuring. The usual cause is a bulk rename that rewrites the wrapper's body along with the
#     call sites. Only single-line wrappers whose body starts with a SHELL
#     word equal to the function name are flagged, so `psql() { kubectl exec ... psql ...; }` —
#     where the inner `psql` is a binary inside the container — stays legal.
# TR: `setenv() { setenv ...; }` yığın taşana kadar özyineler ve script ölçüm yapmak yerine asılır.
#     Tipik sebep: toplu bir yeniden adlandırma, çağrı yerleriyle birlikte sarmalayıcının
#     GÖVDESİNİ de değiştirir. Yalnızca gövdesi fonksiyon adıyla BAŞLAYAN tek
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
#     the API. Otherwise `a.rdb` stays nil and a Redis-dependent trap such as
#     `TRAP_READY_CHECKS_REDIS` (P10-02) reads its flag, sees nil and does nothing. The experiment
#     runs, measures no difference and reports "readiness is fine" — the opposite of the lesson.
#     Rule 9 cannot catch it: the flag IS read. A flag behind a nil dependency is not
#     disabled, it is invisible — nothing fails and nothing logs.
# TR: Redis istemcisi VE httpapi kuran her `cmd/*/main.go`, istemciyi API'ye de vermek zorundadır.
#     Vermezse `a.rdb` nil kalır ve Redis'e bağlı bir tuzak — ör. `TRAP_READY_CHECKS_REDIS`
#     (P10-02) — bayrağını okur, nil görür ve hiçbir şey yapmaz. Deney koşar, fark bulamaz ve
#     "readiness sorunsuz" der — dersin tam tersi. 9. kural bunu yakalayamaz, çünkü bayrak
#     OKUNUYOR. Nil bir bağımlılığın arkasındaki bayrak kapalı değil GÖRÜNMEZdir.
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
#     the experiment compares zeros — "p99=0 ms" for BOTH phases, a verdict built on a baseline
#     of zero. The pattern looks harmless and spreads by copy-paste. Call it plainly:
#     `x=$(promq "...")` — promq already normalises NaN/Inf, so the `num` wrapper is redundant.
# TR: `num "$(promq "...")"` göründüğü şeyi GEÇİRMEZ. `"$( ... )"` içinde iç `\"` kaçışları iç
#     tırnaklamayı bitirir, `{a,b}` tırnaksız kalır ve bash onu SÜSLÜ PARANTEZ GENİŞLETMESİne
#     sokar: parantezler kaybolur, seçici ikiye bölünür. Prometheus `parse error` der, `promq` 0
#     döndürür ve deney sıfırları karşılaştırır — iki fazda da "p99=0 ms", sıfır bir tabanın
#     üstüne kurulmuş bir hüküm. Kalıp zararsız görünür ve kopyala-yapıştırla yayılır. Düz çağır:
#     `x=$(promq "...")` — promq zaten NaN/Inf normalleştiriyor, `num` sarmalayıcısı gereksiz.
for f in "$D"/problems/P*.sh; do
  [[ -e "$f" ]] || continue
  # Genel biçim: `"$( ... \" ... )"` — yani çift tırnak içindeki bir komut ikamesinin İÇİNDE
  # kaçışlı tırnak. Zararsız olanlar (`"$(dirname "$0")"`, `"$(status_of "$code")"`) kaçış
  # içermediği için elenmez.
  if grep -Eq '"\$\([^)]*\\"' "$f"; then
    err "$(basename "$f"): iç içe tırnaklı komut ikamesi (\"\$( ... \\\" ... )\") — süslü parantezler genişler, sorgu/argüman bozulur"
  fi
done

# 14. `${var:-varsayılan}` İÇİNDEKİ KESME İŞARETİ TIRNAK AÇAR.
# EN: bash processes quotes inside the `word` of `${var:-word}` even within double quotes, so an
#     apostrophe ("Endpoint'e", "ingress'in") opens a single-quoted section that swallows the
#     closing brace: `bad substitution: no closing '}'`. It fires ONLY when the variable is empty
#     — i.e. only on the path the fallback exists for — so it survives every run where the value
#     is present. Turkish prose is full of apostrophes, which is why this is a rule.
# TR: bash `${var:-kelime}` içindeki kelimede tırnakları çift tırnak içinde bile işler; bir kesme
#     işareti tek tırnak açıp kapanış süslü parantezini yutar. Yalnızca değişken BOŞKEN patlar,
#     yani yalnızca varsayılanın var olma sebebi olan yolda — değer doluyken hiç görünmez.
for f in "$D"/problems/P*.sh; do
  [[ -e "$f" ]] || continue
  if grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*'"'"'[^}]*\}' "$f"; then
    err "$(basename "$f"): \${var:-...} varsayılanında kesme işareti — değişken boşken tırnak açar ve script ölür"
  fi
done

# 15. `x=$(... | grep ...)` KORUMASIZ: BULAMAMAK HATA DEĞİLDİR.
# EN: `grep` exits 1 when it matches nothing; with `set -o pipefail` the pipeline fails, and a
#     failing command substitution in an ASSIGNMENT trips `set -e` and kills the script — with no
#     verdict printed. It bites only when there is nothing to find, which is usually the HEALTHY
#     path: `last_reason` at a level where nothing crashes, a "Seq Scan" grep once the index is
#     in place, a plaintext-secret grep when there is no plaintext secret.
#     The good news kills the script. Add `|| true` and let an empty result be a result.
# TR: `grep` hiçbir şey bulamazsa 1 döner; `pipefail` ile boru hattı düşer ve ATAMADA başarısız
#     bir komut ikamesi `set -e`yi tetikleyip scripti hüküm basmadan öldürür. Yalnızca bulunacak
#     bir şey yokken ısırır — ki bu genelde SAĞLIKLI yoldur: hiçbir şeyin çökmediği bir seviyede
#     `last_reason`, indeks yerindeyken "Seq Scan" araması, düz metin sır yokken sır araması.
#     İyi haber scripti öldürür. `|| true` ekle; boş bir sonuç da bir sonuçtur.
for f in "$D"/problems/P*.sh; do
  [[ -e "$f" ]] || continue
  while IFS= read -r line; do
    err "$(basename "$f"): korumasız \$(... | grep ...) ataması — bulamazsa pipefail scripti öldürür: ${line:0:60}"
  done < <(grep -nE '^[a-z_]+=\$\(.*\| *grep' "$f" | grep -vE '\|\| *true|\|\| *echo|grep -c' || true)
done

# 16. HÜKÜM SÖZCÜĞÜNÜ AÇIKLAMA METNİNDE KULLANMA.
# EN: the sweep decides a script's result by grepping its OUTPUT for REPRODUCED / NOT-REPRODUCED.
#     A `warn` line that says "this is not a NOT-REPRODUCED, it is a missing measurement" contains
#     the token, so a sweep that scans the whole output reads the explanation as the verdict — a
#     script that exits 2 (SKIPPED) is recorded as NOT-REPRODUCED. Explaining a word is not the
#     same as saying it.
# TR: tur, bir scriptin sonucunu ÇIKTISINDA REPRODUCED / NOT-REPRODUCED arayarak belirler.
#     "Bu bir NOT-REPRODUCED değil, eksik ölçümdür" diyen bir `warn` satırı token'ı içerdiği için
#     tur AÇIKLAMAYI hüküm sanar: script 2 ile çıkıp ATLANDI olması gerekirken NOT-REPRODUCED
#     kaydedilir. Bir sözcüğü açıklamak, onu söylemekle aynı şey değildir.
for f in "$D"/problems/P*.sh; do
  [[ -e "$f" ]] || continue
  if grep -qE '^[[:space:]]*(warn|note)[[:space:]]+".*(NOT-)?REPRODUCED' "$f"; then
    err "$(basename "$f"): warn/note metni içinde REPRODUCED geçiyor — tur bunu hüküm sanar"
  fi
done

# 17. LİMİTER'I SINAYAN SCRIPT `limits_enforced` ÇAĞIRMALI.
# EN: from level 08 on, k6 goes through a load entrance with an exemption token by default
#     (platform/lib/loadtest.sh), because a single-IP load generator through the public entrance
#     measures the limiters instead of the system (availability of a few percent while the app's
#     own 5xx ≈ 0). The default cuts both ways: a script that TESTS a limiter and forgets to opt out
#     never meets the limiter and concludes "the limit does not work". Signals of a limiter test:
#     the abuser scenario, k6_429, RATE_LIMIT_*, X-RateLimit headers, or living in
#     08-rate-limiting. NOT ratelimit_* metrics: reading decision="exempt" to PROVE the exemption
#     worked (P14-05) is the opposite of testing the limiter.
# TR: 08'den itibaren k6 varsayılan olarak yük girişinden ve muafiyet jetonuyla gider, çünkü tek
#     IP'li bir yük üreteci herkese açık girişte sistemi değil limiter'ları ölçer. Bu
#     varsayılan iki yönlü keser: limiter'ı SINAYAN ve muafiyetten çıkmayı unutan bir script
#     limiter'ı hiç görmez ve "limit çalışmıyor" der.
for f in "$D"/problems/P*.sh; do
  [[ -e "$f" ]] || continue
  if { [[ "$name" == 08-* ]] || grep -qE 'k6run abuser|k6_429|RATE_LIMIT|X-RateLimit' "$f"; } \
     && ! grep -qE '^limits_enforced\b' "$f"; then
    err "$(basename "$f"): limiter'ı sınıyor ama limits_enforced çağırmıyor — k6 muafiyet jetonuyla gider ve limiter'ı hiç görmez"
  fi
done

# 18. HER SORUN, OKUYANA GRAFANA'DA NEREYE BAKACAĞINI VE NE GÖRECEĞİNİ SÖYLEMELİ.
# EN: a problem section that names panels that do not exist ("DB CPU", "rps vs pod sayısı"), or
#     none at all, leaves the reader asking someone where to look. Every `### PNN-XX` needs one
#     "**Grafana'da gör:**" block: links to existing dashboards with the level preselected and
#     bullets naming panels that exist, or "Grafana'da görünmez" + the terminal evidence.
# TR: var olmayan panelleri anan ya da hiç panel anmayan bir sorun bölümü, okuyanı nereye
#     bakacağını sormak zorunda bırakır. Ayrıntı: tools/lint-grafana.py.
if ! out=$(python3 "$ROOT/tools/lint-grafana.py" "$D"); then
  while IFS= read -r line; do echo "$line"; done <<<"$out"; fail=1
fi

# 19. HER SORUN, YAPIŞTIRILIP ÇALIŞTIRILABİLECEK SIRALI KOMUTLAR TAŞIMALI.
# Okuyan, "link oluştur → pod'u sil → aynı kodu iste" gibi bir özeti komuta çevirmek zorunda kalmamalı:
# §4'te seviyenin rehberi, her sorunda `make fresh` ile başlayan "Elle" blokları ve "Terminalde ne
# görmelisin". Bloklarda yorum yoktur (varsayılan zsh'da `#` komutun argümanı olur). Ayrıntı:
# tools/lint-guide.py.
if ! out=$(python3 "$ROOT/tools/lint-guide.py" "$D"); then
  while IFS= read -r line; do echo "$line"; done <<<"$out"; fail=1
fi

[[ $fail == 0 ]] && echo "  ✔ $name iskelet OK"
exit $fail
