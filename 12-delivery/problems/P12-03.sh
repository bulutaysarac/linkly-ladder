#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P12-03 · Drift ve self-heal: kubectl ile yapılan değişiklik nereye gidiyor?
# Cluster'daki durum git'ten sapabilir ve bu sapma HİÇBİR YERDE kayıtlı değildir. "Kim replikayı
# 10'a çıkardı?" sorusunun cevabı, GitOps yoksa yoktur. 11'de aynı dersi dashboard'lar için
# görmüştük (P11-07); burada uygulamanın kendisi için.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Argo CD bu namespace'i yönetiyor mu?"
app=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.spec.destination.namespace}{"\n"}{end}' 2>/dev/null | grep "$NS" | head -1) || true
if [[ -z "$app" ]]; then
  note "Bu seviyede Argo CD Application'ı TANIMLI DEĞİL — bilerek."
  note "Sebebi: GitOps'un değeri 'cluster git'ten sapmasın' garantisidir ve bu garanti ancak"
  note "gerçek bir git deposu + otomatik senkronizasyon ile anlamlıdır. Merdivende bunu kurmak"
  note "yerine, sapmanın KENDİSİNİ ölçüp neyin eksik olduğunu göstermeyi seçtik."
fi
step "Manifest'te ne yazıyor, cluster'da ne var?"
want=$(kubectl kustomize "$(dirname "$0")/../deploy" 2>/dev/null | awk '/^kind: Rollout$/{r=1} r&&/^  replicas:/{print $2; exit}') || true
have=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
note "manifest: ${want:-?} replika · cluster: ${have:-?} replika"
step "DRIFT üret: kubectl ile elle değiştir"
kubectl -n "$NS" scale rollout/redirect --replicas=5 >/dev/null 2>&1 || kubectl -n "$NS" patch rollout redirect --type=merge -p '{"spec":{"replicas":5}}' >/dev/null
sleep 5
drifted=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
note "elle değiştirildi → cluster: ${drifted:-?} replika (manifest hâlâ ${want:-?} diyor)"
note "Bu değişiklik: git'te YOK · gözden geçirilmedi · kim yaptı bilinmiyor · yeni bir cluster"
note "kurduğunda KAYBOLUR. Ve en kötüsü: bir sonraki 'make up' onu sessizce geri alır."
step "make up ile yeniden uygula — drift kaybolur"
(cd "$(dirname "$0")/.." && make deploy >/dev/null 2>&1) || warn "make deploy çalışmadı"
sleep 8
after=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
note "yeniden uygulamadan sonra: ${after:-?} replika"
grafana_hint "13 · Rollout → 'Argo CD sync durumu' (Application tanımlıysa dolar)"
note "Bu merdivende manifest'ler git'te ve 'make up' onları uyguluyor — yani ELDE bir GitOps var."
note "Argo CD'nin eklediği üç şey: (1) SÜREKLİ karşılaştırma (sen uygulamasan da), (2) otomatik"
note "self-heal (drift'i kendisi geri alır), (3) görünürlük (hangi kaynak neden farklı)."
note "Kurulum burada hazır (platform → make argo); Application tanımlamak bir sonraki adımın."
{ [[ "${drifted:-0}" != "${want:-0}" ]] && [[ "${after:-0}" == "${want:-0}" ]]; } \
  && reproduced "elle yapılan değişiklik (${want:-?} → ${drifted:-?}) yeniden uygulamada sessizce geri alındı — drift kalıcı olamaz ama GÖRÜNÜR de değil"
not_reproduced "drift üretilemedi ya da geri alınmadı"
