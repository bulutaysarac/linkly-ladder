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
step "Tarama yükü ver (var olmayan rastgele kodlar)"
k6run scan --vus 30 --duration 40s >/dev/null 2>&1 || true
sleep 12
nf=$(promq "sum(increase(redirect_total{namespace=\"$NS\",result=\"not_found\"}[3m]))")
neg=$(promq "sum(increase(cache_ops_total{namespace=\"$NS\",result=\"negative_hit\"}[3m]))")
dbget=$(promq "sum(increase(db_queries_total{namespace=\"$NS\",op=\"get\"}[3m]))")
rej=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\"}[3m]))")
n429=$(k6_429)
grafana_hint "14 · Security → '404 taraması (scan) /s' · 04 · Cache → 'negative_hit' · 10 · Rate limit"
note "404 sayısı=${nf%%.*} · negatif önbellek isabeti=${neg%%.*} · DB okuma=${dbget%%.*} · limit reddi=${rej%%.*} (k6 429=$n429)"
note "Üç katman taramayı ucuzlatıyor:"
note "  1. rastgele 7 karakter (01) → tahmin edilemez"
note "  2. negatif önbellek (03)    → 'yok' cevabı DB'ye inmiyor"
note "  3. hız sınırı (08)          → tarama hızı sınırlanıyor"
note "Eksik olan DÖRDÜNCÜ katman: 404 ORANINA göre özel limit. Normal bir client'ın 404 oranı"
note "düşüktür; tarayan bir client'ınki ~%100. Bu ORANI bir sinyal olarak kullanmak, meşru"
note "trafiği etkilemeden tarayıcıyı ayırır (NOT_FOUND_LIMIT bunun için ayrıldı, uygulanmadı)."
note "Not: enumeration'ı tamamen engellemek genelde MÜMKÜN DEĞİLDİR; amaç onu PAHALI ve GÖRÜNÜR"
note "kılmaktır. Görünürlük burada asıl kazanç: yukarıdaki 404 oranı bir alarm eşiği olabilir."
awk -v n="${nf%%.*}" 'BEGIN{exit !(n>0)}' \
  && reproduced "tarama ${nf%%.*} adet 404 üretti; negatif önbellek (${neg%%.*}) ve limit (${rej%%.*}) maliyeti düşürdü ama 404 oranına özel bir kural YOK"
not_reproduced "tarama etkisi ölçülemedi"
