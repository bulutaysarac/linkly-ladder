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
want=$(kubectl kustomize "$(level_deploy_dir)" 2>/dev/null | awk '/^kind: Rollout$/{r=1} r&&/^  replicas:/{print $2; exit}') || true
have=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
note "manifest: ${want:-?} replika · cluster: ${have:-?} replika"
step "DRIFT üret: kubectl ile elle değiştir"
kubectl -n "$NS" scale "$(wl redirect)" --replicas=5 >/dev/null 2>&1 || kubectl -n "$NS" patch "$(wl redirect)" --type=merge -p '{"spec":{"replicas":5}}' >/dev/null
# Drift'i en az İKİ kazıma aralığı tut: kube-state-metrics 30 sn'de bir kazınıyor; 5 sn'lik bir sapma
# "Hazır pod (sürüme göre)" panelinin basamağına çoğu zaman hiç düşmez — panel, o kadar kısa bir olayı
# gösteremeyecek kadar kaba örnekler.
# EN: hold the drift for at least two scrape intervals (30s) or the panel usually misses it.
sleep "${DRIFT_HOLD:-65}"
drifted=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
note "elle değiştirildi → cluster: ${drifted:-?} replika (manifest hâlâ ${want:-?} diyor)"
note "Bu değişiklik: git'te YOK · gözden geçirilmedi · kim yaptı bilinmiyor · yeni bir cluster"
note "kurduğunda KAYBOLUR. Ve en kötüsü: bir sonraki 'make up' onu sessizce geri alır."
step "Manifest'i yeniden uygula — drift kaybolur"
# DİKKAT: burada `make deploy` ÇAĞIRMIYORUZ. 12'nin Makefile'ı kendi NS'ini (lvl12) kullanır;
# bu script 13'ün `verify-prev`i içinde koşarken `make deploy` ÜÇÜNCÜ bir seviyeyi kümeye
# kurardı: aynı anda iki seviye ayakta, etcd zaman aşımları, ve ölçtüğün ortam artık ölçmek
# istediğin ortam değil.
# Bir önceki seviyenin scripti, BULUNDUĞU namespace'ten başka bir yere dokunamaz.
# EN: do NOT call `make deploy` here — level 12's Makefile targets its OWN namespace, so running
# this script inside level 13's verify-prev would stand up a THIRD level in the cluster.
# A previous level's script must never touch anything outside the namespace it runs in.
kubectl -n "$NS" patch "$(wl redirect)" --type=merge -p "{\"spec\":{\"replicas\":${want:-3}}}" >/dev/null 2>&1 \
  || warn "manifest replikası geri uygulanamadı"
sleep 8
after=$(kubectl -n "$NS" get "$(wl redirect)" -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
note "yeniden uygulamadan sonra: ${after:-?} replika"
note "Grafana'da drift'in KENDİSİ görünmez: Argo CD kurulu ama lvl12 için Application yok (karşılaştıran"
note "kimse yok); 13 · Rollout → 'Hazır pod (sürüme göre)' stable sürümün 3 → 5 → 3 basamağını gösterir ama"
note "bunun bir sapma olduğunu, kimin yaptığını ve geri alındığını söylemez."
note "Bu merdivende manifest'ler git'te ve 'make up' onları uyguluyor — yani ELDE bir GitOps var."
note "Argo CD'nin eklediği üç şey: (1) SÜREKLİ karşılaştırma (sen uygulamasan da), (2) otomatik"
note "self-heal (drift'i kendisi geri alır), (3) görünürlük (hangi kaynak neden farklı)."
note "Kurulum burada hazır (platform → make argo); Application tanımlamak bir sonraki adımın."
{ [[ "${drifted:-0}" != "${want:-0}" ]] && [[ "${after:-0}" == "${want:-0}" ]]; } \
  && reproduced "elle yapılan değişiklik (${want:-?} → ${drifted:-?}) yeniden uygulamada sessizce geri alındı — drift kalıcı olamaz ama GÖRÜNÜR de değil"
not_reproduced "drift üretilemedi ya da geri alınmadı"
