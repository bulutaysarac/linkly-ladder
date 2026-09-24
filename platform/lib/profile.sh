#!/usr/bin/env bash
# Seviyeye göre platform bileşenlerini AÇ/KAPAT.
#
# EN: The cluster is a 6 CPU / 10 GB VM. Every operator (Chaos Mesh, KEDA, CNPG, Argo CD,
#     cert-manager, Tempo) plus the full monitoring stack consumes ~5.6 of 6 cores at idle and
#     pushes the VM into swap: kubelets go NotReady, the controller manager loses its leader
#     lease, and EVERY measurement from then on measures a dying cluster rather than the
#     application. A level only needs the components its own problems use — so turn the rest off.
#     This is the same lesson the ladder teaches at level 11 (observability has a capacity too),
#     applied to the platform itself.
# TR: Küme 6 CPU / 10 GB'lık bir VM. Bütün operatörler (Chaos Mesh, KEDA, CNPG, Argo CD,
#     cert-manager, Tempo) ve tam gözlemlenebilirlik yığını boşta 6 çekirdeğin ~5.6'sını yer ve
#     VM'i swap'e sokar: kubelet'ler NotReady olur, controller manager lider kiralamasını
#     kaybeder ve o andan sonra YAPILAN HER ÖLÇÜM uygulamayı değil, ölmekte olan bir kümeyi
#     ölçer. Bir seviye yalnızca kendi sorunlarının kullandığı bileşenlere ihtiyaç
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
# ve seviye hiç kurulmaz. Ölçekleme komutunun
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
# DAEMONSET'LER DE KAPANIR — ve AYNI ARAÇLA geri açılır.
# EN: a DaemonSet has no replica count, so the only way to park it is an impossible nodeSelector
#     (`kapali=true`); `on` removes it again. Without that pair, a parked `chaos-daemon` never
#     comes back: chaos-mesh looks healthy (controller-manager + dns-server Running) while NO
#     chaos can be injected on any node, and every chaos experiment measures a system nobody
#     broke. `chaos_apply` would catch it (AllInjected=False → exit 2, SKIPPED instead of a fake
#     green) — but the place to prevent it is here, not in the experiments.
#     If you can turn a component off, you must be able to turn it back on WITH THE SAME TOOL.
# TR: bir DaemonSet'in replika sayısı yoktur; onu park etmenin tek yolu imkânsız bir nodeSelector
#     (`kapali=true`); `on` onu yeniden kaldırır. Bu çift olmadan park edilmiş bir `chaos-daemon`
#     hiç geri gelmez: chaos-mesh SAĞLIKLI görünür (controller-manager + dns-server Running) ama
#     hiçbir node'a chaos ENJEKTE EDİLEMEZ ve her chaos deneyi kimsenin bozmadığı bir sistemi
#     ölçer. `chaos_apply` bunu yakalardı (AllInjected=False → exit 2, sahte yeşil yerine
#     SKIPPED) — ama önlenmesi gereken yer deneyler değil, burası.
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
#     discovery is incomplete ("NamespaceDeletionDiscoveryFailure"). Every `make down` still
#     returns 0 while the namespace sits in Terminating FOREVER, holding its pods. Levels pile
#     up, the nodes saturate, etcd slows down, the kube-apiserver PostStartHook times out and the
#     control plane falls into a crash loop — which in turn takes Prometheus into an OOM during
#     WAL replay, so every measurement after that reads nothing. One parked component, a
#     cluster-wide outage. Once KEDA is back, the stuck namespaces disappear within seconds.
#     Cost of keeping it up: two small idle pods. Not a trade.
# TR: KEDA bir AGREGE APIService kaydeder (`v1beta1.external.metrics.k8s.io`). Deployment'larını
#     0'a çekmek o APIService'i ENDPOINT'SİZ bırakır; API keşfi başarısız olur ve namespace
#     denetleyicisi, keşif eksikken HİÇBİR namespace'in silinmesini tamamlamaz
#     ("NamespaceDeletionDiscoveryFailure"). `make down` yine 0 döner ama namespace SONSUZA KADAR
#     Terminating'de kalır ve pod'larını tutar. Seviyeler üst üste birikir, node'lar doyar, etcd
#     yavaşlar, kube-apiserver'ın PostStartHook'u zaman aşımına uğrar ve kontrol düzlemi crash
#     loop'a girer — bu da Prometheus'u WAL oynatırken OOM'a sokar ve ondan sonraki her ölçüm
#     boş okur. Park edilen tek bileşen, küme çapında bir kesinti. KEDA geri gelince takılı
#     namespace'ler saniyeler içinde silinir. Ayakta tutmanın bedeli: iki küçük boşta pod.
#     Bu bir takas değil.
on keda
# CNPG operatörü: 09'dan itibaren (Cluster + Pooler)
if (( n >= 9 )); then on cnpg-system; else off cnpg-system; fi
# Loki + Alloy (log toplama): 11'den itibaren.
# Ölçüldü: Loki ~270 MB, Alloy 3 pod × ~120 MB ve sürekli CPU. Yalnızca P11-05 log hacmini
# ölçüyor; geri kalan seviyeler için bu, ölçtüğün sistemden çalınan bütçedir.
# YALNIZCA 11: log/trace yığınını gerçekten kullanan tek seviye o (P11-02 trace, P11-05 Loki).
# 13 ve 14 en ağır seviyeler (CNPG + Redpanda + Redis + 3 servis + güvenlik yığını) ve bu
# VM'de ek 800 MB onları ayağa kaldıramaz hâle getirir.
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
# Grafana: VARSAYILAN AÇIK — merdivenin amacı sorunu panelde GÖRMEK. Kapatmak ~200 MB kazandırır
# ama `make grafana` boş bir sayfa açar: otomatik turun tasarrufu, öğrenen için yolun ortasında
# bir engel olur. İnsan bakmayan otomatik turlar GRAFANA=0 verir — 11 HARİÇ: P11-07 Grafana'nın
# API'sini ölçüyor; kapalı bir Grafana ona boş cevap verir ve boş cevaptan hüküm çıkar. Bir
# seviyenin deneyinin ölçtüğü bileşen kapatılamaz.
if [[ "${GRAFANA:-1}" == 1 ]] || (( n == 11 )); then kubectl -n monitoring scale deploy kps-grafana --replicas=1 >/dev/null 2>&1
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
#     Someone who installed only `make minimal` and moves to level 02 would get chaos experiments
#     that report SKIPPED with no hint that Chaos Mesh is simply not there. Say what is missing and
#     the exact command, and fail — a level cannot be experienced without its platform.
# TR: `on` var olanı ölçekler; hiç kurulmamış bir bileşende sessizce hiçbir şey yapmaz. Yalnızca
#     `make minimal` kurup 02'ye geçen biri, chaos deneylerinin neden ATLANDI dediğini bilemez.
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
