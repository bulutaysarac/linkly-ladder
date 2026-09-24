#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-04 · Sırlar hâlâ git'te düz metin — sealed-secrets bunu nasıl bitirir?
# P02-09'da bunu ölçmüştük ve "13'te çözülecek" demiştik. Bu script hem mevcut durumu ölçüyor
# hem de çözümü uygulanabilir bir komuta indiriyor. Dürüst kalmak için: bu seviyede düz Secret
# DURUYOR — çünkü SealedSecret üretmek cluster'ın anahtarını gerektirir ve depoyu taze bir
# cluster'da kullanılamaz kılardı. Bir sırrın güvenli olduğunu VARSAYMAK, olmadığını kabul
# etmekten kötüdür.
ensure_healthy
step "Git'te düz metin sır var mı?"
# Düz metin sır BULUNAMAMASI bu scriptin NOT-REPRODUCED yoludur; `|| true` olmadan grep'in 1
# dönmesi pipefail ile atamayı düşürür ve set -e'yi tetiklerdi — yani iyi haber scripti öldürürdü.
hits=$(grep -rn 'API_KEYS:\|POSTGRES_PASSWORD:\|linkly:linkly@' "$(dirname "$0")/../deploy/" 2>/dev/null | grep -v 'secretKeyRef' | head -4 || true)
echo "${hits:-    (bulunamadı)}" | sed 's/^/    /'
step "sealed-secrets controller kurulu mu?"
sc=$(kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets --no-headers 2>/dev/null | awk '{print $1, $3}') || true
note "controller: ${sc:-YOK}"
crd=$(kubectl get crd sealedsecrets.bitnami.com -o name 2>/dev/null) || true
note "CRD: ${crd:-YOK}"
step "Cluster'ın açık anahtarı alınabiliyor mu? (kubeseal bunu kullanır)"
cert=$(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name 2>/dev/null | head -1) || true
note "şifreleme anahtarı: ${cert:-bulunamadı}"
step "Çözüm — bu komut düz Secret'ı şifreli bir SealedSecret'a çevirir:"
note "  kubectl -n $NS create secret generic linkly-api-keys \\"
note "    --from-literal=API_KEYS='acme:pro:...' --dry-run=client -o yaml \\"
note "    | kubeseal --controller-namespace kube-system -o yaml > "$(wl api)"-keys-sealed.yaml"
note "Üretilen dosya GİT'E COMMIT EDİLEBİLİR: yalnızca bu cluster'ın özel anahtarı çözebilir."
note "Grafana'da görünmez: sır git'teki bir dosyada duruyor; hiçbir metrik bir dosyanın içeriğini ölçmez — kanıt yukarıdaki grep."
note "Sealed-secrets'ın çözmediği şey: sır pod'un ORTAM DEĞİŞKENİNDE hâlâ düz metin. Bir crash"
note "dump, bir /proc okuması ya da yanlış bir log satırı onu sızdırabilir."
note "Sonraki adımlar (bu merdivende kapsam dışı): etcd at-rest şifreleme · kısa ömürlü kimlik"
note "bilgisi (Vault/ESO ile rotasyon) · sırrı dosyadan okuyup bellekte tutmak (env yerine) ·"
note "iş yükü kimliği (workload identity) ile paylaşılan sırrı tamamen ORTADAN KALDIRMAK."
note "Sır yönetimi bir araç seçimi değil, bir ZİNCİR: git → cluster → pod → süreç → log → yedek."
{ [[ -n "$crd" ]] && [[ -n "$hits" ]]; } \
  && reproduced "sealed-secrets kurulu ama düz metin sır hâlâ git'te — çözüm tek komut, uygulanması bir karar"
not_reproduced "düz metin sır bulunamadı ya da sealed-secrets kurulu değil"
