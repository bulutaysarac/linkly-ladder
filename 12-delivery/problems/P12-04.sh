#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P12-04 · :latest etiketi — "deploy ettim ama değişmedi" ve geri alınamayan sürüm
# Mutable bir etiket, dağıtımı ÖNGÖRÜLEMEZ yapar: hangi pod hangi kodu çalıştırıyor bilinmez,
# imagePullPolicy'ye göre bazı pod'lar eski imajda kalır ve "önceki sürüme dön" diye bir şey yoktur.
# Bu merdiven en baştan içerik hash'li etiket kullanıyor; script bunu DOĞRULUYOR.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
step "Çalışan imaj etiketleri"
imgs=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u) || true
echo "$imgs" | sed 's/^/    /'
latest=$(echo "$imgs" | grep -c ':latest' || true)
uniqtags=$(echo "$imgs" | sed 's/.*://' | sort -u | wc -l | tr -d ' ')
note ":latest kullanan imaj sayısı: $latest · farklı etiket sayısı: $uniqtags"
step "Etiket nasıl üretiliyor?"
note "ladder.mk: TAG = <git-sha>-<kaynak-hash>. Kaynak değişmezse etiket DEĞİŞMEZ (deterministik),"
note "kaynak değişirse yeni etiket üretilir — yani 'deploy ettim değişmedi' mümkün değil."
note "Bu bir tercih değil, bir ZORUNLULUK: ilk denemede zaman damgalı etiket kullanmıştık ve"
note "'make push' ile 'make deploy' ayrı çağrıldığında FARKLI etiket üretip ImagePullBackOff verdi."
step "Sürümü geri almak mümkün mü?"
hist=$(kubectl -n "$NS" get rollout redirect -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null) || true
rs=$(kubectl -n "$NS" get replicaset -l "$APP_SELECTOR" --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | tail -3) || true
[[ -n "$rs" ]] && { note "önceki sürümler (ReplicaSet geçmişi):"; echo "$rs" | sed 's/^/      /'; }
note "Her sürüm farklı bir etikete sahip olduğu için 'kubectl argo rollouts undo' anlamlı bir yere döner."
note ":latest olsaydı tüm ReplicaSet'ler aynı imajı gösterirdi ve 'undo' HİÇBİR ŞEY değiştirmezdi."
grafana_hint "13 · Rollout → 'rps by version'"
note "13'te Kyverno bu kuralı POLICY hâline getirecek: :latest kullanan bir pod cluster'a giremeyecek."
(( latest > 0 )) \
  && reproduced ":latest etiketi kullanılıyor ($latest imaj) — sürüm belirsiz ve geri alınamaz"
not_reproduced "tüm imajlar içerik hash'li etiket kullanıyor ($uniqtags farklı etiket) — sürüm deterministik ve geri alınabilir"
