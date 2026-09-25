#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P11-03 · Sampling: %100 collector'ı boğar, düşük oran nadir hatayı kaçırır
# Head sampling kararı trace'in BAŞINDA verilir — yavaş mı, hatalı mı olduğunu bilmeden.
# Bu yüzden nadir hatalar tam da nadir oldukları için kaçar. %100'e çıkarmak "çözüm" değil:
# collector, ağ ve depolama maliyeti doğrusal artar, faydası artmaz.
APP_SELECTOR="app.kubernetes.io/name=redirect"
ensure_healthy
on_cleanup "setenv "$(wl redirect)" TRACE_SAMPLE_PCT=5"
measure() {
  for _ in $(seq 1 20); do serving && break; sleep 2; done
  k6run redirect --vus 30 --duration 40s >/dev/null 2>&1 || true
  sleep 15
  local cpu mem spans
  cpu=$(promq "max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace=\"monitoring\",pod=~\"alloy.*\",image!=\"\",image!~\".*pause.*\"}[30s]))[3m:15s])")
  mem=$(promq "max_over_time(sum(container_memory_working_set_bytes{namespace=\"monitoring\",pod=~\"alloy.*\",image!=\"\",image!~\".*pause.*\"})[3m:15s])")
  # DOĞRUDAN SİNYAL: sampling oranının KONTROL ETTİĞİ şey span sayısıdır, Alloy'un CPU'su değil.
  # Alloy aynı anda LOG da topluyor; trace yükü onun toplam maliyetinin küçük bir parçası ve
  # koşudan koşuya oynuyor. Yalnızca CPU'ya bakan bir karar %100 koşusunu %5'ten DAHA UCUZ
  # ölçebilir — yani karar gürültüye kalır. Önce kontrol ettiğin değişkeni ölç,
  # sonra onun maliyetini.
  # EN: sampling controls the SPAN COUNT, not Alloy's CPU. Alloy also ships logs, so trace load is
  # a small and noisy fraction of its cost; judging by CPU alone can make a 100% run measure
  # cheaper than a 5% run. Measure the variable you control first, then its cost.
  spans=$(promq "sum(increase(otelcol_receiver_accepted_spans_total{namespace=\"monitoring\"}[3m]))")
  echo "$cpu $mem $spans"
}
step "(1) %5 sampling (varsayılan)"
settle_rollout "$(wl redirect)"   # measure bir $( ) içinde koşar: bekleme (notu ve exit 2'si) DIŞARIDA
read -r c5 m5 s5 <<< "$(measure)"
note "%5: kabul edilen span=${s5%%.*} · Alloy CPU tepe=$(awk -v v="$c5" 'BEGIN{printf "%.2f", v}') çekirdek · bellek tepe=$(( ${m5%%.*} / 1024 / 1024 )) MB"
step "(2) %100 sampling"
setenv "$(wl redirect)" TRACE_SAMPLE_PCT=100 >/dev/null
settle_rollout "$(wl redirect)"   # measure bir $( ) içinde koşar: bekleme (notu ve exit 2'si) DIŞARIDA
read -r c100 m100 s100 <<< "$(measure)"
note "%100: kabul edilen span=${s100%%.*} · Alloy CPU tepe=$(awk -v v="$c100" 'BEGIN{printf "%.2f", v}') çekirdek · bellek tepe=$(( ${m100%%.*} / 1024 / 1024 )) MB"
grafana_hint "15 · k6 → 'Gönderilen istek / sn' (iki eşit faz) · Explore → otelcol_receiver_accepted_spans_total (Alloy 'monitoring' namespace'inde; 01 · Pods & Resources onu gösteremez)"
note "Maliyet 20 katına çıktı; peki fayda? Teşhis için gereken şey 'tüm trace'ler' değil,"
note "'DOĞRU trace'. Exemplar zaten yavaş bir isteği işaret ediyor (P11-01) — yani %5 ile de"
note "yavaş isteğe ulaşabiliyorsun."
note "Head sampling'in gerçek zayıflığı: nadir HATALAR. %5 ile 100 hatadan 5'ini görürsün;"
note "hata saniyede birden azsa hiçbirini görmeyebilirsin."
note "Çözüm tail sampling: karar trace BİTTİKTEN sonra verilir (yavaşsa/hatalıysa sakla). Bedeli:"
note "collector her span'i trace bitene kadar TAMPONLAR — gerçek bellek, gerçek karmaşıklık."
note "Ara yol: hata/yavaşlık durumunda üretici tarafında zorla örnekleme (AlwaysSample + kural)."
# İKİ FAZ DA SIFIRSA ÖLÇÜ YOK: span alıcısı (Alloy) kurulu değil ya da kazınmıyor. "Fark yok" demek,
# sampling hakkında değil ölçüm hattı hakkında bir cümle olurdu. (Alloy yalnızca 11'in profilinde açık.)
if awk -v a="$s5" -v b="$s100" 'BEGIN{exit !(a+0 == 0 && b+0 == 0)}'; then
  warn "ölçüm yapılamadı: iki fazda da kabul edilen span 0 — Alloy (OTLP alıcısı) kurulu ve kazınıyor mu?"
  warn "kubectl -n monitoring get pods | grep alloy · platform/manifests/obs-servicemonitors.yaml"
  exit 2
fi
awk -v a="$s5" -v b="$s100" 'BEGIN{exit !(b > a*3)}' \
  && reproduced "%100 sampling span hacmini ${s5%%.*} → ${s100%%.*} yaptı ($(awk -v a="$s5" -v b="$s100" 'BEGIN{printf "%.1f", (a>0? b/a : 0)}')×); Alloy CPU $(awk -v v="$c5" 'BEGIN{printf "%.2f", v}') → $(awk -v v="$c100" 'BEGIN{printf "%.2f", v}') çekirdek, bellek $(( ${m5%%.*} / 1024 / 1024 )) → $(( ${m100%%.*} / 1024 / 1024 )) MB"
not_reproduced "span hacmi farkı ölçülemedi (%5=${s5%%.*} · %100=${s100%%.*}) — otelcol_receiver_accepted_spans_total kazınıyor mu? (platform/manifests/obs-servicemonitors.yaml)"
