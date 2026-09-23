#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-07 · Elle düzenlenen dashboard DRIFT eder
# Grafana'da bir paneli düzeltmek 30 saniye sürer ve o düzeltme HİÇBİR YERDE kayıtlı değildir.
# Bir sonraki `make dashboards` onu siler; kimse neyin neden değiştiğini bilmez. Dashboard'lar
# kod değilse, gözlemlenebilirliğin de bir sürüm kontrolü yok demektir.
ensure_healthy
GRAFANA_USER=${GRAFANA_USER:-admin}
GRAFANA_PASS=${GRAFANA_PASS:-ladder}
# ÖLÇTÜĞÜN ŞEY AYAKTA MI? Grafana kapalıysa aşağıdaki her curl boş döner, `editable` ve başlıklar
# boş kalır ve script yine de hüküm basardı — ölçüm yokken NOT-REPRODUCED. Ulaşamıyorsan söyle ve dur.
# EN: if Grafana is unreachable every query below is empty and the verdict has nothing behind it.
g=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/health" 2>/dev/null) || true
if [[ "$g" != 200 ]]; then
  warn "Grafana'ya ulaşılamadı (HTTP ${g:-yok}) — ölçüm yapılamaz. Aç: make profile (ya da GRAFANA=1)"
  exit 2
fi
step "Dashboard'lar nereden geliyor?"
note "kaynak: platform/dashboards/gen.py → out/*.json → ConfigMap (grafana_dashboard=1) → sidecar"
cm=$(kubectl -n monitoring get configmap ladder-dashboards -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null) || true
note "ConfigMap resourceVersion: ${cm:-?}"
step "Grafana'daki dashboard'ları say ve düzenlenebilirliği kontrol et"
dash=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/search?type=dash-db&limit=100" 2>/dev/null | jq -r '[.[] | select(.title|startswith("Ladder"))] | length') || true
editable=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/dashboards/uid/ladder-app-red" 2>/dev/null | jq -r '.dashboard.editable') || true
note "Ladder dashboard sayısı: ${dash:-?} · 'editable' bayrağı: ${editable:-?}"
step "Drift denemesi: dashboard'ı API üzerinden değiştirmeye çalış"
resp=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" -XPOST "$GRAFANA_URL/api/dashboards/db" \
  -H 'Content-Type: application/json' \
  -d '{"dashboard":{"uid":"ladder-app-red","title":"Ladder / 02 · App RED (ELLE DEĞİŞTİRİLDİ)","panels":[],"schemaVersion":39},"overwrite":true}' 2>/dev/null | head -c 200)
note "API yanıtı: ${resp:-<boş>}"
title_now=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/dashboards/uid/ladder-app-red" 2>/dev/null | jq -r '.dashboard.title') || true
note "şimdiki başlık: ${title_now:-?}"
step "Kaynaktan yeniden uygula (make dashboards) — drift silinir"
(cd "$LADDER_ROOT/platform" && make dashboards >/dev/null 2>&1) || warn "make dashboards çalışmadı"
sleep 25
title_after=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/dashboards/uid/ladder-app-red" 2>/dev/null | jq -r '.dashboard.title') || true
note "yeniden uygulamadan sonra başlık: ${title_after:-?}"
grafana_hint "Ladder klasörü — dashboard'lar salt okunur (editable: false)"
note "Bu merdivende dashboard'lar KODDUR: platform/dashboards/gen.py üretir, ConfigMap taşır,"
note "sidecar yükler. Grafana'da 'editable: false' — elle düzenleme kapatıldı."
note "Bedeli: bir paneli düzeltmek için kod değiştirip yeniden uygulamak gerekir (30 sn yerine 3 dk)."
note "Kazancı: her panel gözden geçirilebilir, geri alınabilir ve YENİDEN ÜRETİLEBİLİR — yeni bir"
note "cluster kurduğunda gözlemlenebilirliğin de kurulur. 12'de aynı fikir uygulamaya uygulanacak (GitOps)."
{ [[ "${editable:-true}" == "false" ]] || [[ "${title_after:-}" == "${title_now:-x}" ]]; } \
  && reproduced "dashboard'lar koddan üretiliyor (editable=${editable:-?}); elle yapılan değişiklik yeniden uygulamada kaybolur → drift kalıcı olamaz"
not_reproduced "dashboard'lar elle düzenlenebilir durumda — drift riski açık"
