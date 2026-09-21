#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P03-07 · TRAP_NO_TTL_JITTER: aynı anda yazılan anahtarlar aynı anda dolar → periyodik DB tepesi
# Bir dağıtımdan sonra önbellek tek seferde ısınır: yüzlerce anahtar aynı saniyede yazılır ve
# TTL süresi sonra hepsi aynı saniyede dolar. Grafikte düzenli aralıklı dikey darbeler görürsün;
# sistemin kendi kendine yarattığı, saat gibi işleyen bir yük dalgası.
#
# ÖLÇÜM NOTU — bu darbeyi Prometheus'tan OKUYAMAZSIN:
# Darbe 1-2 saniye sürüyor, Prometheus ise 15 saniyede bir örnekliyor ve `rate(...[30s])` onu
# 30 saniyeye yayıp düzlüyor. Tepe/ortalama oranı tam da düzlenen şey. Bu yüzden burada pod'un
# kendi /metrics ucunu SANİYEDE BİR örnekliyoruz: ölçüm çözünürlüğü, ölçtüğün olaydan ince olmalı.
# (Aynı örnekleme sorunu 11'de "exemplar ve yüksek çözünürlük" başlığıyla geri gelecek.)
TTLS=${TTLS:-30s}
LOAD=${LOAD:-150}
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_NO_TTL_JITTER- CACHE_TTL-"
on_cleanup "port_forward_stop"

warm_and_watch() {
  local out=$1 pod port=18307
  kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null
  for _ in $(seq 1 30); do serving && break; sleep 2; done
  pod=$(pod_name)
  port_forward "$pod" "$port"
  # Sabit, orta yoğunluklu okuma: 300 kod tek seferde ısınır, sonra TTL boyunca sürekli okunur.
  # Darbeler yalnızca TTL dolmalarından gelir.
  SEED=300 k6run redirect --vus 20 --duration "${LOAD}s" >/dev/null 2>&1 &
  local k6pid=$!
  # result="expired": TTL dolduğu için yapılan ıska. İlk ısınmanın ıskalarını saymaz —
  # yani ölçtüğümüz şey TAM OLARAK TTL dolmaları.
  sample_series "$port" "$LOAD" "$out" '^cache_ops_total\{.*result="expired"'
  wait "$k6pid" 2>/dev/null || true
  port_forward_stop
}

step "Jitter AÇIK (varsayılan, ±%20), TTL $TTLS — ${LOAD}s boyunca saniyede bir örnekleniyor"
kubectl -n "$NS" set env deploy/linkly CACHE_TTL="$TTLS" TRAP_NO_TTL_JITTER- >/dev/null
warm_and_watch /tmp/p0307-jitter.txt
read -r p1 a1 r1 <<< "$(peak_avg /tmp/p0307-jitter.txt)"
note "jitter'lı:  tepe=${p1}/s  ortalama=${a1}/s  → tepe/ortalama=$r1"

step "Jitter KAPALI (TRAP_NO_TTL_JITTER), aynı senaryo"
kubectl -n "$NS" set env deploy/linkly TRAP_NO_TTL_JITTER=true >/dev/null
warm_and_watch /tmp/p0307-nojitter.txt
read -r p2 a2 r2 <<< "$(peak_avg /tmp/p0307-nojitter.txt)"
note "jitter'sız: tepe=${p2}/s  ortalama=${a2}/s  → tepe/ortalama=$r2"
note "Saniyelik seriler duruyor: /tmp/p0307-jitter.txt · /tmp/p0307-nojitter.txt (ikisini yan yana koy)"

grafana_hint "05 · Postgres → 'DB queries by op' (düzenli aralıklı dikey darbeler) · 04 · Cache → 'eviction/expired'"
note "Bakılacak sayı ortalama değil, TEPE/ORTALAMA oranı: iki durumda da aynı sayıda anahtar dolar,"
note "fark yalnızca bunun ZAMANA YAYILIP yayılmadığıdır. Ortalamaya bakan kapasite planı seni yanıltır."
note "Jitter, ilişkisiz olayların ilişkili hâle gelmesini engelleyen genel bir tekniktir —"
note "aynı fikir retry'da (10) ve cron'larda da karşına çıkacak."
awk -v a="$r1" -v b="$r2" 'BEGIN{exit !(b > a * 1.8 && b > 3)}' \
  && reproduced "jitter'sız tepe/ortalama oranı $r1 → $r2'ye çıktı — TTL'ler hizalandı, DB periyodik darbe alıyor"
not_reproduced "tepe oranı artmadı (TTL ya da yük süresini gözden geçir: yük en az 4 TTL döngüsü sürmeli)"
