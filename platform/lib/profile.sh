#!/usr/bin/env bash
# Seviyeye göre platform bileşenlerini AÇ/KAPAT.
#
# EN: The cluster is a 6 CPU / 10 GB VM. Running every operator (Chaos Mesh, KEDA, CNPG, Argo CD,
#     cert-manager, Tempo) plus the full monitoring stack at idle consumed ~5.6 of 6 cores and
#     pushed the VM into swap: kubelets went NotReady, the controller manager lost its leader
#     lease, and EVERY measurement after that point was measuring a dying cluster rather than the
#     application. A level only needs the components its own problems use — so turn the rest off.
#     This is the same lesson the ladder teaches at level 11 (observability has a capacity too),
#     applied to the platform itself.
# TR: Küme 6 CPU / 10 GB'lık bir VM. Bütün operatörleri (Chaos Mesh, KEDA, CNPG, Argo CD,
#     cert-manager, Tempo) ve tam gözlemlenebilirlik yığınını boşta çalıştırmak 6 çekirdeğin
#     ~5.6'sını yiyip VM'i swap'e soktu: kubelet'ler NotReady oldu, controller manager lider
#     kiralamasını kaybetti ve o andan sonra YAPILAN HER ÖLÇÜM uygulamayı değil, ölmekte olan
#     bir kümeyi ölçtü. Bir seviye yalnızca kendi sorunlarının kullandığı bileşenlere ihtiyaç
#     duyar — gerisini kapat. Bu, 11'in dersinin (gözlemlenebilirliğin de kapasitesi vardır)
#     platformun kendisine uygulanmış hâli.
#
# Kullanım: platform/lib/profile.sh <seviye-no>   (örn. 07)
set -uo pipefail
L=${1:?seviye numarası gerekli (00..14)}
n=$((10#$L))

# AÇTIĞIN BİLEŞENİN HAZIR OLMASINI BEKLE.
# Neden: CNPG ve Kyverno birer ADMISSION WEBHOOK sunar. Operatör pod'u henüz ayağa kalkmamışken
# `kubectl apply` yapan bir `make up`, "failed calling webhook ... connection refused" ile düşer
# ve seviye hiç kurulmaz — gece turunda 09 tam olarak böyle iki kez düştü. Ölçekleme komutunun
# dönmesi, bileşenin ÇALIŞIYOR olması demek değildir.
wait_ns_ready() {
  local ns=$1 i bad
  for i in $(seq 1 60); do
    bad=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null \
          | awk '$3!="Completed" {split($2,a,"/"); if (a[1]!=a[2]) c++} END{print c+0}')
    [[ "${bad:-0}" == "0" ]] && return 0
    sleep 3
  done
  echo "  uyarı: $ns 3 dk içinde hazır olmadı"
  return 0
}
# DAEMONSET'LER DE KAPANIR — ve bu fonksiyonlar uzun süre onları GÖRMÜYORDU.
# EN: a DaemonSet has no replica count, so the only way to park it is an impossible nodeSelector.
#     `off` never did that and `on` never undid it — but something had parked `chaos-daemon` with
#     `kapali=true` at some point, and nothing could ever bring it back. Result: chaos-mesh looked
#     healthy (controller-manager + dns-server Running) while NO chaos could be injected on any
#     node, for hours. Every chaos experiment in that window measured a system nobody had broken.
#     `chaos_apply` catches this (AllInjected=False → exit 2) so the scripts reported SKIPPED
#     instead of a fake green — but the hole was in the profile script, not the experiments.
#     If you can turn a component off, you must be able to turn it back on WITH THE SAME TOOL.
# TR: bir DaemonSet'in replika sayısı yoktur; onu park etmenin tek yolu imkânsız bir nodeSelector.
#     `off` bunu hiç yapmıyordu, `on` da hiç geri almıyordu — ama bir noktada `chaos-daemon`
#     `kapali=true` ile park edilmişti ve onu geri getirecek hiçbir şey yoktu. Sonuç: chaos-mesh
#     SAĞLIKLI görünüyordu (controller-manager + dns-server Running) ama hiçbir node'a chaos
#     ENJEKTE EDİLEMİYORDU. O pencerede koşan her chaos deneyi, kimsenin bozmadığı bir sistemi
#     ölçtü. `chaos_apply` bunu yakalıyor (AllInjected=False → exit 2), yani scriptler sahte
#     yeşil yerine SKIPPED bastı — ama delik deneylerde değil, profil scriptindeydi.
#     Bir bileşeni kapatabiliyorsan, AYNI ARAÇLA geri açabilmek zorundasın.
on()  {
  kubectl -n "$1" scale deploy --all --replicas="${3:-1}" >/dev/null 2>&1
  [[ -n "${2:-}" ]] && kubectl -n "$1" scale statefulset --all --replicas=1 >/dev/null 2>&1
  for d in $(kubectl -n "$1" get daemonset -o name 2>/dev/null); do
    kubectl -n "$1" patch "$d" --type=json \
      -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/kapali"}]' >/dev/null 2>&1 || true
  done
  wait_ns_ready "$1"
  return 0
}
off() {
  kubectl -n "$1" scale deploy --all --replicas=0 >/dev/null 2>&1
  kubectl -n "$1" scale statefulset --all --replicas=0 >/dev/null 2>&1
  for d in $(kubectl -n "$1" get daemonset -o name 2>/dev/null); do
    kubectl -n "$1" patch "$d" -p '{"spec":{"template":{"spec":{"nodeSelector":{"kapali":"true"}}}}}' >/dev/null 2>&1 || true
  done
  return 0
}

# Chaos Mesh: 02'den itibaren (pg-delay, pg-loss, redis-delay...)
if (( n >= 2 )); then on chaos-mesh; else off chaos-mesh; fi
# KEDA: 07'den itibaren (lag tabanlı ölçekleme)
# KEDA ASLA PARK EDİLMEZ — park etmek NAMESPACE SİLMEYİ KÜMEDE KİLİTLİYOR.
# EN: KEDA registers an AGGREGATED APIService (`v1beta1.external.metrics.k8s.io`). Scaling its
#     deployments to 0 leaves that APIService registered with NO endpoints, so API discovery
#     fails — and the namespace controller refuses to finish deleting ANY namespace while
#     discovery is incomplete ("NamespaceDeletionDiscoveryFailure"). Every `make down` then
#     returned 0 while the namespace sat in Terminating FOREVER, holding its pods. Four of them
#     piled up (one for 4 hours), the nodes ran at 170% CPU, etcd slowed down, the kube-apiserver
#     PostStartHook timed out and the control plane fell into a crash loop — which in turn made
#     Prometheus OOM during WAL replay and made an entire verification round measure nothing.
#     One parked component, a cluster-wide outage, and a day of verdicts with no measurement
#     behind them. The moment KEDA came back, all four namespaces disappeared within seconds.
#     Cost of keeping it up: two small idle pods. Not a trade.
# TR: KEDA bir AGREGE APIService kaydeder (`v1beta1.external.metrics.k8s.io`). Deployment'larını
#     0'a çekmek o APIService'i ENDPOINT'SİZ bırakır; API keşfi başarısız olur ve namespace
#     denetleyicisi, keşif eksikken HİÇBİR namespace'in silinmesini tamamlamaz
#     ("NamespaceDeletionDiscoveryFailure"). Böylece her `make down` 0 dönerken namespace
#     SONSUZA KADAR Terminating'de kalıyor ve pod'larını tutuyordu. Dört tanesi birikti (biri 4
#     saat), node'lar %170 CPU'ya çıktı, etcd yavaşladı, kube-apiserver'ın PostStartHook'u zaman
#     aşımına uğradı ve kontrol düzlemi crash loop'a girdi — bu da Prometheus'u WAL oynatırken
#     OOM'a soktu ve koca bir doğrulama turunun hiçbir şey ölçmemesine yol açtı. Park edilen tek
#     bileşen, küme çapında bir kesinti. KEDA geri gelince dört namespace saniyeler içinde
#     silindi. Ayakta tutmanın bedeli: iki küçük boşta pod. Bu bir takas değil.
on keda
# CNPG operatörü: 09'dan itibaren (Cluster + Pooler)
if (( n >= 9 )); then on cnpg-system; else off cnpg-system; fi
# Loki + Alloy (log toplama): 11'den itibaren.
# Ölçüldü: Loki ~270 MB, Alloy 3 pod × ~120 MB ve sürekli CPU. Yalnızca P11-05 log hacmini
# ölçüyor; geri kalan seviyeler için bu, ölçtüğün sistemden çalınan bütçedir.
# YALNIZCA 11: log/trace yığınını gerçekten kullanan tek seviye o (P11-02 trace, P11-05 Loki).
# 13 ve 14 en ağır seviyeler (CNPG + Redpanda + Redis + 3 servis + güvenlik yığını) ve bu
# VM'de ek 800 MB onları ayağa kaldıramaz hâle getiriyordu.
if (( n == 11 )); then
  kubectl -n monitoring scale statefulset loki --replicas=1 >/dev/null 2>&1
  kubectl -n monitoring patch daemonset alloy --type=json -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' >/dev/null 2>&1
else
  kubectl -n monitoring scale statefulset loki --replicas=0 >/dev/null 2>&1
  kubectl -n monitoring patch daemonset alloy -p '{"spec":{"template":{"spec":{"nodeSelector":{"kapali":"true"}}}}}' >/dev/null 2>&1
fi
# Tempo: 11'den itibaren (trace)
if (( n == 11 )); then kubectl -n monitoring scale statefulset tempo --replicas=1 >/dev/null 2>&1; \
                 else kubectl -n monitoring scale statefulset tempo --replicas=0 >/dev/null 2>&1; fi
# Argo CD + Rollouts: 12'den itibaren
if (( n >= 12 )); then on argocd with-sts; on argo-rollouts; else off argocd; off argo-rollouts; fi
# cert-manager: 13'ten itibaren
if (( n >= 13 )); then on cert-manager; else off cert-manager; fi
# Grafana: VARSAYILAN AÇIK — merdivenin amacı sorunu panelde GÖRMEK. Eskiden 11 dışında kapatılıyordu
# (~200 MB) ve `make grafana` her seviyede boş bir sayfa açıyordu: doğrulama turunun tasarrufu,
# öğrenen için yolun ortasında bir engeldi. İnsan bakmayan otomatik turlar GRAFANA=0 verir.
if [[ "${GRAFANA:-1}" == 1 ]]; then kubectl -n monitoring scale deploy kps-grafana --replicas=1 >/dev/null 2>&1
else                                kubectl -n monitoring scale deploy kps-grafana --replicas=0 >/dev/null 2>&1; fi
# Kyverno: 13'ten önce KAPALI (ölçüldü: ~90 MB × 2 controller ve bu VM'de yer yok).
# Politika YOKKEN Kyverno webhook'larını kendisi kaldırır, yani replikayı 0'a çekmek güvenli.
# 13 politikaları uyguladıktan SONRA kapatma: webhook ortada kalır ve failurePolicy=Fail
# kuralları küme genelinde pod oluşturmayı reddettirir.
# Kyverno bir ADMISSION WEBHOOK'tur: replikayı 0'a çekmek webhook'u ortada bırakır ve
# failurePolicy=Fail olan kurallar KÜME GENELİNDE pod oluşturmayı reddettirir. Yani "kaynak
# tasarrufu" için kapatmak, bütün merdiveni çalışamaz hâle getirebilir. Kurulmamışsa bu satır
# zaten hiçbir şey yapmaz (13'ten önce `platform && make security` çalıştırılmamış olur).
if (( n >= 13 )); then on kyverno; else kubectl -n kyverno scale deploy --all --replicas=0 >/dev/null 2>&1; fi

echo "profil: seviye $L → chaos=$(( n>=2 )) keda=1(hep) cnpg=$(( n>=9 )) log=$(( n==11 )) tempo=$(( n==11 )) argo=$(( n>=12 )) güvenlik=$(( n>=13 )) grafana=${GRAFANA:-1}"

# KURULU OLMAYAN BİLEŞEN SESSİZCE "AÇILMAZ" — SÖYLE.
# EN: `on` scales whatever exists; a component that was never installed makes it a silent no-op.
#     Someone who installed only `make minimal` and moved to level 02 got chaos experiments that
#     reported SKIPPED with no hint that Chaos Mesh was simply not there. Say what is missing and
#     the exact command, and fail — a level cannot be experienced without its platform.
# TR: `on` var olanı ölçekler; hiç kurulmamış bir bileşende sessizce hiçbir şey yapmaz. Yalnızca
#     `make minimal` kurup 02'ye geçen biri, chaos deneylerinin neden ATLANDI dediğini bilemezdi.
#     Neyin eksik olduğunu ve tam komutu söyle, ve dur: seviye platformu olmadan yaşanamaz.
missing=()
has() { kubectl get ns "$1" >/dev/null 2>&1; }
(( n >= 2 ))  && ! has chaos-mesh    && missing+=(chaos)
(( n >= 7 ))  && ! has keda          && missing+=(keda)
(( n >= 9 ))  && ! has cnpg-system   && missing+=(cnpg)
(( n == 11 )) && ! kubectl -n monitoring get statefulset tempo >/dev/null 2>&1 && missing+=(tempo)   # yalnızca 11 açar (yukarı bak)
(( n >= 12 )) && ! has argo-rollouts && missing+=(argo)
(( n >= 13 )) && ! has kyverno       && missing+=(security)
if (( ${#missing[@]} > 0 )); then
  echo "✘ seviye $L şu platform bileşenlerini istiyor ama kurulu değil: ${missing[*]}"
  echo "  kur: cd \"$(cd "$(dirname "$0")/.." && pwd)\" && make ${missing[*]}      (ya da hepsi: make full)"
  exit 1
fi
