#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P02-10 · TRAP_READYZ_CHECKS_DB: "readiness bağımlılıkları kontrol etsin" → kısmi arıza TAM kesinti
# Çok makul görünen bir fikir: pod DB'ye ulaşamıyorsa trafik almasın. Sonucu şu: DB 10 saniye
# kesilince TÜM pod'lar aynı anda Endpoints'ten düşer, ingress'in yönlendirecek HİÇBİR hedefi kalmaz.
# Üstelik DB dönünce hepsi aynı anda geri gelip onu ikinci kez devirir.
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_READYZ_CHECKS_DB-"
step "Önce varsayılan davranış: DB'yi kes, endpoint sayısını izle"
# NOT: bu KSM sürümü `kube_endpoint_address` ÜRETMİYOR; karşılığı `kube_endpointslice_endpoints`.
# Metrik adının var olduğunu VARSAYMAK, sessizce 0 ölçmenin en kolay yoludur.
# DİKKAT: `service` etiketi burada KSM'nin KENDİ servisidir (scrape etiketi); hedef servisi
# `endpointslice` adından seç (slice, servis adıyla başlar).
base_ep=$(promq "sum(kube_endpointslice_endpoints{namespace=\"$NS\",endpointslice=~\"linkly-.*\",ready=\"true\"})")
note "hazır endpoint (normal): ${base_ep%%.*}"
step "Tuzağı aç: readyz DB'ye ping atsın"
kubectl -n "$NS" set env deploy/linkly TRAP_READYZ_CHECKS_DB=true >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null || true
for _ in $(seq 1 20); do serving && break; sleep 2; done
need_confirm "postgres pod'u silinecek"
( k6run redirect --vus 5 --duration 100s >/tmp/p0210.k6 2>&1 ) & kpid=$!
sleep 10
on_cleanup "kubectl -n \"$NS\" rollout status statefulset/postgres --timeout=180s"   # sonraki deney hazır bir DB bulmalı
kubectl -n "$NS" delete pod -l app.kubernetes.io/name=postgres --wait=false >/dev/null
min_ep=99; zero_seconds=0
for _ in $(seq 1 40); do
  ep=$(kubectl -n "$NS" get endpointslice -l kubernetes.io/service-name=linkly \
        -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' 2>/dev/null | grep -c true || true)
  (( ep < min_ep )) && min_ep=$ep
  (( ep == 0 )) && zero_seconds=$((zero_seconds+2))
  sleep 2
done
wait $kpid || true
e5=$(k6_5xx)
grafana_hint "01 · Pods & Resources → 'hazır endpoint sayısı' (sıfıra iniyor) · 02 · App RED → 5xx"
note "DB kesintisi sırasında EN DÜŞÜK hazır endpoint sayısı: $min_ep · sıfırda geçen süre: ~${zero_seconds} sn · k6 5xx: $e5"
note "Karşılaştır: P02-03'te (tuzak KAPALI) endpoint'ler 3'te kalıyordu — aynı DB arızası, farklı yıkım."
note "Kural: readiness 'BEN hazır mıyım?' sorusudur. 'Bağımlılığım iyi mi?' sorusunun cevabı METRİKTİR,"
note "ve buna verilecek tepki devre kesici/degrade moddur (10), pod'u trafikten düşürmek değil."
{ (( min_ep == 0 )) || (( e5 > 0 )); } \
  && reproduced "readiness DB'ye bağlanınca tüm pod'lar trafikten düştü (min endpoint=$min_ep, ~${zero_seconds} sn sıfır, 5xx=$e5)"
not_reproduced "endpoint'ler ayakta kaldı (min=$min_ep) — readiness bağımlılığa bakmıyor"
