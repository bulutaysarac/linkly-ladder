#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P10-04 · Devre kesici: açılma, yarı açık deneme ve flapping riski
# Devre kesicinin işi bağımlılığı kurtarmak değil; ONA VE SANA nefes aldırmaktır. Eşikler yanlışsa
# iki yönde de zarar verir: çok hassas → sağlıklı bağımlılığı "bozuk" ilan eder (yanlış pozitif),
# çok tembel → arızayı fark etmez. Ayrıca yarı açık pencerede flapping (aç-kapa-aç) olabilir.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/redirect TRAP_NO_BREAKER-"
on_cleanup "$LADDER_ROOT/platform/lib/chaos.sh delete pg-loss-50"
step "Postgres'e %50 paket kaybı (ağır arıza)"
chaos_apply pg-loss-50
sleep 5
step "(1) Devre kesici AÇIK (varsayılan)"
k6run mixed --vus 25 --duration 50s >/dev/null 2>&1 || true
sleep 10
calls_on=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"postgres\"}[3m]))")
open_rej=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"postgres\",result=\"open\"}[3m]))")
state_max=$(promq "max_over_time(max(breaker_state{namespace=\"$NS\",dep=\"postgres\"})[4m:15s])")
p99_on=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")")
note "breaker açık: bağımlılık çağrısı=${calls_on%%.*} · devre-açık reddi=${open_rej%%.*} · tepe durum=${state_max%%.*} (2=açık) · p99=$(awk -v v="$p99_on" 'BEGIN{printf "%.0f", v*1000}') ms"
step "(2) TRAP_NO_BREAKER: devre kesici yok, her istek bozuk bağımlılığa gidiyor"
kubectl -n "$NS" set env deploy/redirect TRAP_NO_BREAKER=true >/dev/null
kubectl -n "$NS" rollout status deploy/redirect --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
k6run mixed --vus 25 --duration 50s >/dev/null 2>&1 || true
sleep 10
calls_off=$(promq "sum(increase(dependency_requests_total{namespace=\"$NS\",dep=\"postgres\"}[3m]))")
p99_off=$(num "$(promq "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[2m])) by (le))")")
grafana_hint "11 · Resilience → 'breaker state by dep' + 'dependency errors/s' · 02 · App RED → p99"
note "breaker yok: bağımlılık çağrısı=${calls_off%%.*} · p99=$(awk -v v="$p99_off" 'BEGIN{printf "%.0f", v*1000}') ms"
note "Devre açıkken istek, bağımlılığa GİTMEDEN hızlıca reddedilir (ya da degrade moda düşer):"
note "hem bağımlılık nefes alır hem client hızlı cevap alır. Yavaş hata, hızlı hatadan KÖTÜDÜR."
note "Ayar riski: OpenDuration çok kısa + HalfOpenProbes çok az → flapping. Grafana'da 'breaker state'"
note "paneli testere dişi görünüyorsa eşikler yanlış demektir. Bu deneyde tepe durum ${state_max%%.*} idi."
note "Kritik ayrıntı (kodda): ErrNotFound devre kesiciyi TETİKLEMEZ. 404'ler hata değildir; bunu"
note "ayırt etmemek, çok sayıda 404'ün sağlıklı bir bağımlılığı 'bozuk' ilan etmesine yol açar."
awk -v a="${calls_on%%.*}" -v b="${calls_off%%.*}" 'BEGIN{exit !(b > a)}' \
  && reproduced "devre kesici bağımlılık çağrılarını ${calls_off%%.*} → ${calls_on%%.*} düşürdü (açık-devre reddi ${open_rej%%.*}, tepe durum ${state_max%%.*})"
not_reproduced "devre kesici etkisi ölçülemedi (arıza yeterince ağır değil — pg-loss-50 uygulandı mı?)"
