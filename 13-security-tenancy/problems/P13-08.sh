#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P13-08 · Konteyner sertleştirme ve tedarik zinciri: imajın içinde ne var?
# Kod güvenliği, çalıştırdığın imajın güvenliğiyle sınırlıdır. Bu merdiven en baştan distroless
# kullanıyor (00'dan beri): shell yok, paket yöneticisi yok, curl yok — yani ele geçiren biri
# pivot yapacak araç bulamaz. Script bunu DOĞRULUYOR ve eksik kalanları listeliyor.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
pod=$(pod_name)
step "Çalışma imajı ve kullanıcı"
img=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[0].image}') || true
note "imaj: $img"
sc=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[0].securityContext}') || true
note "securityContext: ${sc:-<yok>}"
step "Konteynerde shell var mı? (distroless doğrulaması)"
shell_out=$(kubectl -n "$NS" exec "$pod" -- /bin/sh -c 'echo VAR' 2>&1 | head -c 120) || true
note "sh denemesi: $shell_out"
step "Yazılabilir kök dosya sistemi var mı?"
rofs=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}') || true
nonroot=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}') || true
caps=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop}') || true
note "readOnlyRootFilesystem=${rofs:-?} · runAsNonRoot=${nonroot:-varsayılan(imajdan)} · drop=${caps:-?}"
step "Eksik kalan tedarik zinciri adımları"
note "  · imaj TARAMASI (Trivy/Grype) — CI'da var mı? .github/workflows/ci.yml'e bak"
note "  · imaj İMZALAMA (cosign) + doğrulama politikası (Kyverno verifyImages)"
note "  · SBOM üretimi ve saklanması"
note "  · base imaj güncelleme otomasyonu (distroless bile CVE alır)"
note "Grafana'da görünmez: sertleştirme pod tanımının ve imajın bir özelliği; 'Politika ihlalleri (Kyverno)'"
note "de göstermez — bu alanları zorunlu kılan bir kural yok. Kanıt yukarıdaki securityContext ve sh denemesi."
note "Distroless'ın verdiği şey saldırı YÜZEYİNİN küçüklüğü: içeride shell yoksa, uzaktan kod"
note "çalıştırma bir 'curl | sh' zincirine dönüşemez. Vermediği şey: uygulamanın KENDİ açıkları."
note "Ayrıca bir bedeli var ve bunu 00'da yaşadık: HEALTHCHECK'in çağıracağı bir araç yok, bu"
note "yüzden binary kendini yokluyor (cmd/.../main.go: 'healthcheck' alt komutu)."
{ echo "$shell_out" | grep -qv 'VAR' && [[ "${rofs:-false}" == "true" ]]; } \
  && reproduced "imaj distroless (shell yok) ve konteyner sertleştirilmiş (readOnlyRootFilesystem=$rofs, drop=$caps); tedarik zinciri adımları eksik"
not_reproduced "sertleştirme doğrulanamadı (shell çıktısı: $shell_out)"
