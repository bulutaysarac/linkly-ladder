#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-06 · Enumeration: var olmayan kodları taramak
# Kısa kodlar rastgele ve 7 karakter (01'de öyle yapmıştık) — yani tahmin edilemez. Ama tarama
# yine de bir MALİYETTİR: her 404 bir önbellek ıskası, bir DB sorgusu ya da en azından bir
# limit kontrolü demektir. Ve yeterince tarama, var olan kodları da ortaya çıkarır.
limits_enforced   # bu script limiter'ı sınıyor — yük girişi ve muafiyet jetonu KULLANILMAZ
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Kod uzayı ne kadar büyük?"
note "62^7 = 3.5 × 10^12. Saniyede 10.000 deneme ile tüm uzayı taramak ~11.000 YIL sürer."
note "Yani asıl risk 'kodu bulmak' değil, TARAMANIN MALİYETİ ve gürültüsü."
# İKİ FAZ, İKİ AYRI İDDİA.
# (1) Sınırsız tarama: her istek YENİ bir kod — enumeration budur ve 404 üretir. Ama bu yükte
#     negatif önbellek hiçbir şey yapamaz: aynı "yok" cevabı hiç tekrar sorulmaz. YALNIZCA bu faza
#     bakıp "negatif önbellek maliyeti düşürdü" demek, ~0 negatif isabetle bir iddia kurmak olurdu.
# (2) Sınırlı havuz (KEYS=N, scan.js): aynı N yok-olan kod tekrar tekrar — ölü linkler, yazım hataları,
#     tekrar eden botlar. Negatif önbelleğin maliyeti düşürdüğü yük BUDUR; iddia burada ölçülür.
# Her faz kendi penceresiyle ölçülür (başlangıç → ölçüm anı): [3m] gibi sabit bir pencere iki fazı
# birbirine karıştırırdı.
# EN: an unbounded scan never repeats a missing code, so the negative cache has nothing to serve
# (claiming it "lowers the cost" from this phase alone rests on ~0 negative hits). Phase 2
# replays N missing codes (KEYS=N) — the load where the negative cache actually pays; each phase
# gets its own window.
# KEYS fonksiyon çağrısının ÖNÜNE yazılır (`KEYS=60 phase k6run scan …`): bash, bir fonksiyonun
# önündeki atamaları o fonksiyonun içinde çalışan komutlara da verir; k6 onu __ENV.KEYS olarak okur.
phase() {
  local t0 win nf neg db rej
  t0=$(date +%s)
  k6run scan --vus 30 --duration 40s >/dev/null 2>&1 || true
  sleep 12
  win=$(( $(date +%s) - t0 ))s
  nf=$(promq "sum(increase(redirect_total{namespace=\"$NS\",result=\"not_found\"}[$win]))")
  neg=$(promq "sum(increase(cache_ops_total{namespace=\"$NS\",result=\"negative_hit\"}[$win]))")
  db=$(promq "sum(increase(db_queries_total{namespace=\"$NS\",op=\"get\"}[$win]))")
  rej=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\"}[$win]))")
  echo "$nf $neg $db $rej"
}
per404() { awk -v d="$1" -v n="$2" 'BEGIN{printf "%.2f", (n>0? d/n : 0)}'; }
step "(1) Tarama: her istek YENİ, var olmayan bir kod (enumeration)"
read -r nf neg dbget rej <<< "$(KEYS=0 phase)"
n429=$(k6_429)
note "404=${nf%%.*} · negatif isabet=${neg%%.*} · DB okuma=${dbget%%.*} (404 başına $(per404 "$dbget" "$nf")) · limit reddi=${rej%%.*} (k6 429=$n429)"
note "Negatif önbellek burada işe YARAMAZ: aynı 'yok' cevabı hiç tekrar sorulmuyor — her izin verilen istek DB'ye iner."
step "(2) Aynı ${SCAN_KEYS:-60} yok-olan kod tekrar tekrar (KEYS=${SCAN_KEYS:-60}: ölü linkler, tekrar eden botlar)"
read -r nf2 neg2 dbget2 rej2 <<< "$(KEYS=${SCAN_KEYS:-60} CODE_LEN=7 phase)"
note "404=${nf2%%.*} · negatif isabet=${neg2%%.*} · DB okuma=${dbget2%%.*} (404 başına $(per404 "$dbget2" "$nf2")) · limit reddi=${rej2%%.*}"
grafana_hint "14 · Security → 'Var olmayan kod istekleri / sn (tarama)' · 10 · Rate limit → 'Kararlar (anahtar türüne göre)' · 04 · Cache → 'Önbellek işlemleri (katman ve sonuca göre)'"
note "Üç katman taramayı ucuzlatıyor:"
note "  1. rastgele 7 karakter (01) → tahmin edilemez"
note "  2. negatif önbellek (03)    → TEKRAR sorulan 'yok' cevabı DB'ye inmiyor (faz 2); yeni kodda işe yaramaz (faz 1)"
note "  3. hız sınırı (08)          → tarama hızı sınırlanıyor (iki fazda da reddin çoğu limiter'dan)"
note "Eksik olan DÖRDÜNCÜ katman: 404 ORANINA göre özel limit. Normal bir client'ın 404 oranı"
note "düşüktür; tarayan bir client'ınki ~%100. Bu ORANI bir sinyal olarak kullanmak, meşru"
note "trafiği etkilemeden tarayıcıyı ayırır (NOT_FOUND_LIMIT bunun için ayrıldı, uygulanmadı)."
note "Not: enumeration'ı tamamen engellemek genelde MÜMKÜN DEĞİLDİR; amaç onu PAHALI ve GÖRÜNÜR"
note "kılmaktır. Görünürlük burada asıl kazanç: yukarıdaki 404 oranı bir alarm eşiği olabilir."
# NEGATİF ÖNBELLEK HİÇ İSABET ETMEDİYSE maliyet iddiası ölçülemedi — "fark yok" değil, "ölçemedik".
if awk -v n="${neg2%%.*}" 'BEGIN{exit !(n+0 == 0)}'; then
  warn "ölçüm yapılamadı: 2. fazda negatif isabet 0 — negatif önbellek hiç devreye girmedi."
  warn "Havuz yeterince küçük mü (SCAN_KEYS=${SCAN_KEYS:-60}) ve CACHE_NEGATIVE_TTL yükten uzun mu?"
  exit 2
fi
awk -v n="${nf%%.*}" 'BEGIN{exit !(n>0)}' \
  && reproduced "tarama ${nf%%.*} adet 404 üretti; tekrar eden kodlarda negatif önbellek DB okumasını 404 başına $(per404 "$dbget" "$nf") → $(per404 "$dbget2" "$nf2")'ye indirdi (${neg2%%.*} negatif isabet), limit ${rej%%.*} isteği reddetti — ama 404 oranına özel bir kural YOK"
not_reproduced "tarama etkisi ölçülemedi"
