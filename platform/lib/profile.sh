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
on()  {
  kubectl -n "$1" scale deploy --all --replicas="${3:-1}" >/dev/null 2>&1
  [[ -n "${2:-}" ]] && kubectl -n "$1" scale statefulset --all --replicas=1 >/dev/null 2>&1
  wait_ns_ready "$1"
  return 0
}
off() { kubectl -n "$1" scale deploy --all --replicas=0 >/dev/null 2>&1; kubectl -n "$1" scale statefulset --all --replicas=0 >/dev/null 2>&1; return 0; }

# Chaos Mesh: 02'den itibaren (pg-delay, pg-loss, redis-delay...)
if (( n >= 2 )); then on chaos-mesh; else off chaos-mesh; fi
# KEDA: 07'den itibaren (lag tabanlı ölçekleme)
if (( n >= 7 )); then on keda; else off keda; fi
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
# Grafana: otomatik doğrulama turunda gerekmiyor (dashboard'lara insan bakar), ~200 MB.
# 11+ açık kalsın ki gözlemlenebilirlik seviyeleri elle de incelenebilsin.
if (( n == 11 )); then kubectl -n monitoring scale deploy kps-grafana --replicas=1 >/dev/null 2>&1
else                   kubectl -n monitoring scale deploy kps-grafana --replicas=0 >/dev/null 2>&1; fi
# Kyverno: 13'ten önce KAPALI (ölçüldü: ~90 MB × 2 controller ve bu VM'de yer yok).
# Politika YOKKEN Kyverno webhook'larını kendisi kaldırır, yani replikayı 0'a çekmek güvenli.
# 13 politikaları uyguladıktan SONRA kapatma: webhook ortada kalır ve failurePolicy=Fail
# kuralları küme genelinde pod oluşturmayı reddettirir.
# Kyverno bir ADMISSION WEBHOOK'tur: replikayı 0'a çekmek webhook'u ortada bırakır ve
# failurePolicy=Fail olan kurallar KÜME GENELİNDE pod oluşturmayı reddettirir. Yani "kaynak
# tasarrufu" için kapatmak, bütün merdiveni çalışamaz hâle getirebilir. Kurulmamışsa bu satır
# zaten hiçbir şey yapmaz (13'ten önce `platform && make security` çalıştırılmamış olur).
if (( n >= 13 )); then on kyverno; else kubectl -n kyverno scale deploy --all --replicas=0 >/dev/null 2>&1; fi

echo "profil: seviye $L → chaos=$(( n>=2 )) keda=$(( n>=7 )) cnpg=$(( n>=9 )) log=$(( n==11 )) tempo=$(( n==11 )) argo=$(( n>=12 )) güvenlik=$(( n>=13 ))"
