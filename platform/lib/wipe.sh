#!/usr/bin/env bash
# Verileri sıfırla, platformu koru: make wipe CONFIRM=1
#
# Silinenler: bütün seviye namespace'leri (lvl*) ve içlerindeki her şey (Postgres, Redis, Kafka
# verisi dahil), seviyelerin kurduğu küme kapsamlı Kyverno kuralları, lvl* hedefli Argo CD
# Application'ları, Prometheus'un bütün metrikleri (k6 koşuları dahil), Tempo'nun trace'leri,
# Loki'nin logları, Alertmanager'ın durumu ve /tmp'deki k6 özetleri.
# Kalanlar: kind kümesi, kurulu bileşenler (Helm sürümleri), Grafana dashboard'ları ve
# registry'deki imajlar — sonraki `make up` imaj derlemeden, kurulum beklemeden başlar.
#
# Grafana veri tutmaz, gösterir: bir paneli boşaltmanın tek yolu, sorguladığı deponun (Prometheus,
# Tempo, Loki) diskini boşaltmaktır. Bu depoların diski bir PVC'dir ve bağlı bir pod varken
# silinemez; bu yüzden her depo önce 0 replikaya indirilir, PVC silinir, sonra eski replika
# sayısına döndürülür. Profil (make profile) bir bileşeni 0'da tuttuysa 0'da kalır.
# [Topic · Konu: Deney araçları]
set -euo pipefail
MON=monitoring

if [[ "${CONFIRM:-0}" != 1 ]]; then
  cat <<'EOF'
Bu komut şunları KALICI olarak siler:
  • bütün seviye namespace'leri (lvl00 … lvl14) ve içlerindeki veritabanı, cache, kuyruk verisi
  • seviyelerin kurduğu Kyverno ClusterPolicy'leri ve lvl* hedefli Argo CD Application'ları
  • Prometheus metrikleri, Tempo trace'leri, Loki logları, Alertmanager durumu
  • /tmp/k6-*.summary*.json
Kalır: küme, kurulu bileşenler, Grafana dashboard'ları, registry imajları.

Onaylamak için:  make wipe CONFIRM=1
EOF
  exit 2
fi

kubectl get --raw /readyz >/dev/null 2>&1 || { echo "✘ küme cevap vermiyor — önce: make start"; exit 1; }

has_crd() { kubectl get crd "$1" >/dev/null 2>&1; }

# 1) Seviye namespace'leri.
# Namespace silmek, içindeki her nesnenin sahibi olan controller'ın izin vermesini bekler:
# CloudNativePG, KEDA ve Chaos Mesh nesnelerine finalizer koyar. Profil o operatörü 0 replikaya
# indirdiyse finalizer'ı kaldıracak kimse yoktur ve namespace sonsuza kadar Terminating'te kalır.
# Bu grupların nesneleri önce silinir, finalizer'ları elle düşürülür; namespace ondan sonra gider.
kinds=$(for g in postgresql.cnpg.io keda.sh chaos-mesh.org; do
           kubectl api-resources --namespaced --api-group="$g" -o name 2>/dev/null
         done | paste -sd, -)

namespaces=$(kubectl get ns -o name | sed -n 's#^namespace/\(lvl[0-9][0-9]\)$#\1#p')
for ns in $namespaces; do
  echo "→ $ns siliniyor"
  if [[ -n "$kinds" ]]; then
    kubectl -n "$ns" delete "$kinds" --all --wait=false >/dev/null 2>&1 || true
    for r in $(kubectl -n "$ns" get "$kinds" -o name 2>/dev/null); do
      kubectl -n "$ns" patch "$r" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done
  fi
  kubectl delete namespace "$ns" --wait=false >/dev/null
done

# 2) Küme kapsamlı artıklar: namespace silinince gitmezler.
if has_crd clusterpolicies.kyverno.io; then
  kubectl delete clusterpolicy -l app.kubernetes.io/part-of=linkly-ladder --ignore-not-found
fi
# Otomatik senkronlu bir Application, silinen namespace'i Git'ten geri kurar; önce o gider.
if has_crd applications.argoproj.io; then
  for app in $(kubectl -n argocd get applications.argoproj.io -o json |
               jq -r '.items[] | select(.spec.destination.namespace // "" | test("^lvl[0-9]+$")) | .metadata.name'); do
    kubectl -n argocd delete applications.argoproj.io "$app"
  done
fi

# 3) Gözlem depoları.
# Diski silinecek pod'un tamamen gitmesini bekle: pod varken PVC "Terminating"de takılı kalır.
wait_gone() {  # $1 = pod label seçicisi
  kubectl -n "$MON" wait --for=delete pod -l "$1" --timeout=180s >/dev/null 2>&1 || true
}
drop_pvcs() {  # $1 = PVC ad ön eki
  local pvcs
  pvcs=$(kubectl -n "$MON" get pvc -o name | grep "^persistentvolumeclaim/$1" || true)
  [[ -z "$pvcs" ]] || kubectl -n "$MON" delete $pvcs --wait=true
}

# Prometheus'un StatefulSet'ini operatör yönetir; replika sayısı Prometheus nesnesinden değişir.
if kubectl -n "$MON" get prometheus kps-prometheus >/dev/null 2>&1; then
  echo "→ Prometheus metrikleri siliniyor"
  prom_replicas=$(kubectl -n "$MON" get prometheus kps-prometheus -o jsonpath='{.spec.replicas}')
  kubectl -n "$MON" patch prometheus kps-prometheus --type=merge -p '{"spec":{"replicas":0}}' >/dev/null
  wait_gone "app.kubernetes.io/name=prometheus,operator.prometheus.io/name=kps-prometheus"
  drop_pvcs prometheus-kps-prometheus-db-
  kubectl -n "$MON" patch prometheus kps-prometheus --type=merge \
    -p "{\"spec\":{\"replicas\":${prom_replicas:-1}}}" >/dev/null
fi

for sts in tempo loki; do
  kubectl -n "$MON" get statefulset "$sts" >/dev/null 2>&1 || continue
  echo "→ $sts verisi siliniyor"
  replicas=$(kubectl -n "$MON" get statefulset "$sts" -o jsonpath='{.spec.replicas}')
  kubectl -n "$MON" scale statefulset "$sts" --replicas=0 >/dev/null
  wait_gone "app.kubernetes.io/name=$sts"
  drop_pvcs "storage-$sts-"
  kubectl -n "$MON" scale statefulset "$sts" --replicas="${replicas:-0}" >/dev/null
done

# Alertmanager diski emptyDir: pod'u silmek susturmaları ve bildirim geçmişini sıfırlar.
kubectl -n "$MON" delete pod -l app.kubernetes.io/name=alertmanager --ignore-not-found >/dev/null

# 4) Yerel k6 özetleri (make repro bunları okuyup karar verir).
rm -f /tmp/k6-lvl*.summary*.json

# 5) Bekle: namespace'ler gitti mi, Prometheus geri geldi mi?
echo "→ namespace'lerin silinmesi bekleniyor (en fazla 5 dk)"
for i in $(seq 1 60); do
  left=$(kubectl get ns -o name | grep -c '^namespace/lvl[0-9][0-9]$' || true)
  [[ "$left" == 0 ]] && break
  sleep 5
done
if [[ "$left" != 0 ]]; then
  echo "✘ hâlâ silinmeyen namespace var:"; kubectl get ns | grep '^lvl'
  echo "  içinde kalan: kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl -n <ns> get --ignore-not-found"
  exit 1
fi
kubectl -n "$MON" rollout status statefulset prometheus-kps-prometheus --timeout=300s >/dev/null
echo "✔ veriler silindi — Grafana boş. Bir seviyeyi yeniden kurmak için: cd \"\$LADDER/00-naive\" && make up"
