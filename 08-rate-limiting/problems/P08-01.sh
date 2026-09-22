#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P08-01 · Limiter'ın kendi bağımlılığı var: Redis düşünce fail-open mı fail-closed mı?
# Korumayı paylaşılan bir duruma taşıdın; artık koruma da arızalanabilir. İki seçenek:
#   fail-open  → koruma kalkar, tam da yükün en yüksek olduğu anda (çünkü Redis genelde yük altında düşer)
#   fail-closed → önbellek kesintisi TAM KESİNTİYE dönüşür
# Üçüncü seçenek "hiç düşünmemek"tir ve varsayılan davranış ne ise o olur — en kötüsü budur.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" RATE_LIMIT_FAIL_OPEN=true"
on_cleanup "kubectl -n \"$NS\" rollout status statefulset/redis --timeout=180s"
on_cleanup "kubectl -n \"$NS\" scale statefulset redis --replicas=1"
step "Normal çalışma: limit uygulanıyor mu?"
k6run abuser --duration 30s >/dev/null 2>&1 || true
sleep 10
rej=$(promq "sum(increase(ratelimit_decisions_total{namespace=\"$NS\",decision=\"reject\"}[3m]))")
note "normalde reddedilen istek: ${rej%%.*}"
need_confirm "redis durdurulacak"
step "FAIL-OPEN (varsayılan): Redis'i durdur, aynı kötü client'ı çalıştır"
kubectl -n "$NS" scale statefulset redis --replicas=0 >/dev/null
sleep 12
k6run abuser --duration 30s >/dev/null 2>&1 || true
sleep 10
open_rej=$(k6_429); open_errs=$(promq "sum(increase(ratelimit_errors_total{namespace=\"$NS\"}[3m]))")
open_5xx=$(k6_5xx)
note "fail-open: 429=$open_rej · 5xx=$open_5xx · limiter hatası=${open_errs%%.*}"
note "→ hizmet ÇALIŞTI ama koruma YOK: kötü client sınırsız geçti."
step "FAIL-CLOSED: aynı senaryo, bu kez reddet"
setenv "$(wl redirect)" RATE_LIMIT_FAIL_OPEN=false >/dev/null
kubectl -n "$NS" rollout status "$(wl redirect)" --timeout=180s >/dev/null 2>&1 || true
sleep 5
k6run redirect --vus 10 --duration 25s >/dev/null 2>&1 || true
closed_429=$(k6_429); closed_reqs=$(k6_reqs)
note "fail-closed: $closed_reqs istekten $closed_429 tanesi 429 (%$(awk -v a="$closed_429" -v b="$closed_reqs" 'BEGIN{printf "%.0f", (b>0? a*100/b : 0)}'))"
note "→ koruma ÇALIŞTI ama hizmet YOK: normal kullanıcılar da reddedildi."
kubectl -n "$NS" scale statefulset redis --replicas=1 >/dev/null
grafana_hint "10 · Rate limit → 'limiter backend hata/s' + 'decisions by key type' · 06 · Redis → redis_up"
note "Seçim bizim: fail-open + ALARM. Gerekçe: korumayı kaybetmek telafi edilebilir (kötü client"
note "bir süre geçer), hizmeti kaybetmek edilemez (herkes reddedilir)."
note "Ama bu seçim bir BORÇ yaratır: 'limiter devre dışı' alarmı OLMAK ZORUNDA, yoksa korumasız"
note "kaldığını fark etmezsin. 11'de bu alarm SLO'lardan türeyecek."
note "Azaltma: yerel bir yedek limiter (daha gevşek) — koruma tamamen kalkmasın, sadece gevşesin."
{ (( open_5xx == 0 )) && awk -v e="${open_errs%%.*}" 'BEGIN{exit !(e>0)}'; } \
  && reproduced "Redis kaybında limiter devre dışı kaldı (${open_errs%%.*} hata) ama hizmet sürdü; fail-closed modda ise $closed_429/$closed_reqs istek reddedildi"
not_reproduced "limiter arızası ölçülemedi (redis gerçekten durdu mu?)"
