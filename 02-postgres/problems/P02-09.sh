#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-09 · Veritabanı şifresi düz metin: git'te, Secret'ta ve pod env'inde
# Kubernetes Secret'ı ŞİFRELEMEZ, yalnızca base64'ler. Depolamada şifreleme (etcd encryption)
# ayrı bir ayardır ve varsayılan değildir. Üstelik bu dosya git'te düz metin duruyor.
ensure_healthy
step "1) Git deposunda düz metin var mı?"
if grep -rn 'POSTGRES_PASSWORD\|linkly:linkly@' "$(dirname "$0")/../deploy/" 2>/dev/null | head -3 | sed 's/^/    /' | grep -q .; then
  warn "parola manifest dosyasında düz metin — repoyu klonlayan herkes görüyor"
  ingit=1
else
  ingit=0
fi
step "2) Secret gerçekten şifreli mi?"
b64=$(kubectl -n "$NS" get secret postgres -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null) || true
plain=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
note "kubectl get secret → '$b64' → base64 -d → '$plain'"
note "base64 şifreleme değildir; RBAC'i olan herkes okuyabilir."
step "3) Pod'un içinden görünüyor mu?"
podenv=$(kubectl -n "$NS" get "$(app_workload)" -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].secretRef.name}') || true
note "deployment envFrom: $podenv → parola süreç ortam değişkenlerinde"
note "Bir crash dump, bir /proc okuması, yanlış bir log satırı ya da bir debug endpoint'i onu sızdırabilir."
step "4) Kim okuyabilir?"
kubectl -n "$NS" auth can-i get secrets --as=system:serviceaccount:"$NS":default >/dev/null 2>&1 \
  && warn "namespace'teki default service account Secret okuyabiliyor" \
  || note "default service account Secret okuyamıyor (iyi)"
grafana_hint "14 · Security (13'ten itibaren dolacak)"
note "Çözüm 13: sealed-secrets (git'te şifreli, cluster'da çözülür) + etcd at-rest şifreleme +"
note "NetworkPolicy (her pod DB'ye erişemesin) + kısa ömürlü kimlik bilgisi."
{ [[ -n "$plain" ]] || (( ingit == 1 )); } && reproduced "parola düz metin olarak erişilebilir (git: $([[ $ingit == 1 ]] && echo evet || echo hayır), Secret: '$plain')"
not_reproduced "parola düz metin olarak bulunamadı"
