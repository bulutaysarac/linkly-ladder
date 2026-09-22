#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P05-01 · At-most-once: rollout/çökme sırasında tampondaki tıklamalar kaybolur
# Kuyruk süreç belleğinde. Süreç graceful kapanırsa drain eder (kayıp yok); SERT ölürse
# (OOM, kill -9, node arızası) tampondaki her şey gider. Teslimat garantisi bir TERCİHTİR
# ve bu seviyede "en fazla bir kez" seçildi — ucuz ve sayaçlar için yeterli, faturalama için değil.
ensure_healthy
on_cleanup "setenv "$(app_workload)" ANALYTICS_FLUSH_INTERVAL- ANALYTICS_BATCH_SIZE-"
# ÖLÇÜM NOTU: kaybedebileceğin şey, o an TAMPONDA olandır. Varsayılan flush 1 sn olduğu için
# tampon en fazla 1 saniyelik tıklama tutar; yavaş üreten bir döngüyle öldürdüğünde çoğu zaman
# tampon boş yakalanır ve deney "kayıp yok" der. Bu, tasarımın güvenli olduğunu DEĞİL, ölçümün
# şanslı olduğunu gösterir. Pencereyi 15 sn'ye açıyoruz: kaybın büyüklüğü artık tesadüf değil.
step "Tamponu görünür yap: flush aralığı 15s, batch 5000 (erken flush olmasın)"
setenv "$(app_workload)" ANALYTICS_FLUSH_INTERVAL=15s ANALYTICS_BATCH_SIZE=5000 >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null || true
for _ in $(seq 1 30); do serving && break; sleep 2; done
code=$(create_link "https://example.com/atmostonce")
step "Sayacı sıfırla ve bilinen sayıda tıklama üret"
before=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
N=${N:-400}
for i in $(seq 1 "$N"); do status_of "$code" >/dev/null; done
step "Kuyruk daha boşalmadan pod'ları SERT öldür (graceful DEĞİL)"
need_confirm "pod'lar --force ile öldürülecek"
kubectl -n "$NS" delete pod -l "$APP_SELECTOR" --force --grace-period=0 >/dev/null 2>&1 || true
wait_ready; for _ in $(seq 1 25); do serving && break; sleep 2; done
sleep 6
hard=$(curl -s "$BASE_URL/api/links/$code/stats" | jq -r '.clicks // 0')
lost_hard=$(( before + N - hard ))
note "sert ölüm: $N tıklama üretildi, kaydedilen $(( hard - before )) → KAYIP $lost_hard"
step "Karşılaştırma: aynı senaryo GRACEFUL kapanışla (drain devrede)"
code2=$(create_link "https://example.com/graceful")
b2=$(curl -s "$BASE_URL/api/links/$code2/stats" | jq -r '.clicks // 0')
for i in $(seq 1 "$N"); do status_of "$code2" >/dev/null; done
kubectl -n "$NS" rollout restart "$(app_workload)" >/dev/null
kubectl -n "$NS" rollout status "$(app_workload)" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 25); do serving && break; sleep 2; done
sleep 8
g=$(curl -s "$BASE_URL/api/links/$code2/stats" | jq -r '.clicks // 0')
lost_soft=$(( b2 + N - g ))
note "graceful: $N tıklama üretildi, kaydedilen $(( g - b2 )) → KAYIP $lost_soft"
grafana_hint "07 · Analytics → 'events by result' (dropped/written) + 'k6 tıklama − DB tıklama' farkı"
note "Fark şurada: drain, PLANLI kapanışı kurtarır; plansız ölümü kurtaramaz."
note "Kalıcı çözüm 06: olayı süreç belleğinden çıkar, dayanıklı bir loga yaz (en az bir kez) ve"
note "tüketiciyi idempotent yap. Orada yeni sorun 'çift sayma' olacak — garanti seçmek, sorun seçmektir."
# EŞİK NEDEN ORAN: "tamponu kaybetmek" ile "uçuştaki birkaç isteği kaybetmek" aynı şey değil.
# 06'da olaylar broker'a gidiyor ve üretici hemen gönderiyor; sert ölümde yine de birkaç kayıt
# uçuşta olabilir. Eşik 0 olursa bu script 06'da da "REPRODUCED" der ve merdivenin kontratını
# (bir sonraki seviye bunu ÇÖZER) yanlışlıkla kırar. Ölçtüğün şey bir TAMPON kaybı olmalı: %10.
loss_pct=$(awk -v l="$lost_hard" -v n="$N" 'BEGIN{printf "%.1f", (n>0? l*100/n : 0)}')
note "sert ölüm kaybı: %$loss_pct (eşik: %10 — altı 'uçuştaki istek', üstü 'tampon kaybı')"
awk -v l="$lost_hard" -v n="$N" 'BEGIN{exit !(n>0 && l*100/n > 10)}' \
  && reproduced "sert ölümde $lost_hard/$N tıklama (%$loss_pct) kayboldu — tampon süreç belleğindeydi (graceful kapanışta kayıp: $lost_soft)"
not_reproduced "sert ölümde kayıp %$loss_pct — tampon kaybı yok, olaylar dayanıklı bir yere yazılıyor (06)"
