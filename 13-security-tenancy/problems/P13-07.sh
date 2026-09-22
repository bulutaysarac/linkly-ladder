#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-07 · Kyverno: README bir temenni, admission policy bir garantidir
# Bu merdivende öğrenilen kurallar (":latest yasak", "bellek limiti zorunlu", "probe zorunlu")
# şimdiye kadar README'lerde yazıyordu. Fark, o README'yi hiç okumamış birinin bir şey dağıttığı
# gün ortaya çıkar.
ensure_healthy
step "Tanımlı politikalar"
kubectl get clusterpolicy --no-headers 2>/dev/null | awk '{print "    " $1 " → " $2}' || note "    (Kyverno kurulu değil)"
# REDDEDİLMEK BEKLENEN SONUÇTUR — ama kubectl bunu sıfırdan farklı bir çıkış koduyla söyler.
# EN: `|| true` is not sloppiness here: a denied admission is exactly what this experiment wants
#     to observe, and `set -e` was killing the script at the first success. An experiment must not
#     treat its own expected outcome as a fatal error.
# TR: buradaki `|| true` özensizlik değil: reddedilme, bu deneyin GÖRMEK İSTEDİĞİ şeydir ve
#     `set -e` scripti ilk başarıda öldürüyordu. Bir deney, beklediği sonucu ölümcül hata
#     olarak görmemeli.
step "(1) :latest etiketli bir pod dağıtmayı dene"
out1=$(kubectl -n "$NS" run policy-test-latest --image=busybox:latest --restart=Never \
        --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:latest","command":["sleep","30"],"resources":{"limits":{"memory":"64Mi"}},"readinessProbe":{"exec":{"command":["true"]}}}]}}' \
        --dry-run=server 2>&1 | tail -2) || true
note "sonuç: $(echo "$out1" | head -c 220)"
step "(2) Bellek limiti OLMAYAN bir pod dağıtmayı dene"
out2=$(kubectl -n "$NS" run policy-test-nolimit --image=busybox:1.36 --restart=Never \
        --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","30"],"readinessProbe":{"exec":{"command":["true"]}}}]}}' \
        --dry-run=server 2>&1 | tail -2) || true
note "sonuç: $(echo "$out2" | head -c 220)"
step "(3) readinessProbe OLMAYAN bir pod dağıtmayı dene"
out3=$(kubectl -n "$NS" run policy-test-noprobe --image=busybox:1.36 --restart=Never \
        --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","30"],"resources":{"limits":{"memory":"64Mi"}}}]}}' \
        --dry-run=server 2>&1 | tail -2) || true
note "sonuç: $(echo "$out3" | head -c 220)"
blocked=0
for o in "$out1" "$out2" "$out3"; do echo "$o" | grep -qiE 'denied|blocked|violation|not allowed' && blocked=$((blocked+1)); done
grafana_hint "14 · Security → 'Kyverno policy sonuçları'"
note "engellenen deneme: $blocked / 3"
note "Politikaların kaynağı bu merdivenin kendi geçmişi: P12-04 (:latest), P00-08 (bellek limiti),"
note "P00-04 + P07-08 (probe). Yani her kural, bir kez ÖLÇÜLMÜŞ bir arızanın kalıcı karşılığı."
note "validationFailureAction: Enforce = REDDET. 'Audit' modu yalnızca raporlar — yeni bir politikayı"
note "önce Audit ile açmak, mevcut iş yüklerini kırmadan kapsamı görmenin standart yoludur."
note "Dikkat: politika, ADMISSION anında çalışır. Zaten çalışan ihlaller etkilenmez (background"
note "controller onları RAPORLAR ama silmez) — yani politika eklemek geçmişi temizlemez."
(( blocked > 0 )) \
  && reproduced "$blocked/3 ihlalli pod admission'da REDDEDİLDİ — merdivenin kuralları artık kapıda uygulanıyor"
not_reproduced "hiçbir deneme engellenmedi (Kyverno kurulu mu? kubectl get clusterpolicy)"
