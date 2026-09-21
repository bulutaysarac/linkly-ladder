#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-07 · TRAP_MIGRATE_IN_MAIN: migration'ı her pod kendi açılışında koşarsa N replika yarışır
# Varsayılan doğru: tek seferlik Job. Tuzağı açınca 3 pod aynı anda şema kilidine saldırıyor.
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_MIGRATE_IN_MAIN-"
step "Varsayılan: migration nerede koşuyor?"
kubectl -n "$NS" get job migrate -o jsonpath='  Job: {.metadata.name} · tamamlanan: {.status.succeeded}{"\n"}' 2>/dev/null || note "  Job bulunamadı"
note "Uygulama yalnızca şemanın hazır olmasını BEKLİYOR (cmd/linkly/main.go · waitForSchema)"
step "Tuzağı aç: her pod kendi migration'ını koşsun, hepsini aynı anda yeniden başlat"
kubectl -n "$NS" set env deploy/linkly TRAP_MIGRATE_IN_MAIN=true >/dev/null
kubectl -n "$NS" rollout restart deploy/linkly >/dev/null
sleep 5
kubectl -n "$NS" delete pod -l "$APP_SELECTOR" --force --grace-period=0 >/dev/null 2>&1 || true
rc=0; kubectl -n "$NS" rollout status deploy/linkly --timeout=150s >/dev/null 2>&1 || rc=$? || true
sleep 5
restarts=$(restarts)
logerr=$(kubectl -n "$NS" logs -l "$APP_SELECTOR" --tail=200 --all-containers 2>/dev/null | grep -ci 'migration\|lock\|deadlock\|already exists' || true)
mig=$(kubectl -n "$NS" logs -l "$APP_SELECTOR" --tail=300 --all-containers 2>/dev/null | grep -i 'migration koşuluyor' | wc -l | tr -d ' ')
grafana_hint "01 · Pods & Resources → 'Restart sayısı' · 02 · App RED → 5xx"
note "rollout sonucu: $([[ $rc == 0 ]] && echo tamam || echo "TIMEOUT ($rc)") · toplam restart: $restarts"
note "'migration koşuluyor' diyen pod sayısı: $mig (tek seferlik olması gereken iş, $mig kez yapıldı)"
note "goose bir advisory lock kullanır: yarışanlar bloklanır, en yavaş pod en son hazır olur."
note "Asıl tehlike şu: uygulamayı geri alırsan (rollback) ŞEMA geri gelmez. Bu yüzden şema değişikliği"
note "dağıtımın parçası değil, AYRI ve tek seferlik bir adımdır — 12'de expand/contract ile derinleşecek."
{ (( mig > 1 )) || (( rc != 0 )) || (( logerr > 0 )); } \
  && reproduced "migration $mig pod'da ayrı ayrı koştu (rollout $([[ $rc == 0 ]] && echo tamam || echo timeout)) — tek seferlik iş N kez yapıldı"
not_reproduced "migration yalnızca Job'da koştu — doğru yapı"
