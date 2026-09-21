# platform/Makefile — paylaşılan altyapı. Sıra: make cluster → make core → make obs → make dashboards
# ya da tek seferde: make minimal | standard | full
KIND_NAME := ladder
CALICO_VER := v3.29.3
INGRESS_URL := https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
METRICS_URL := https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
SHELL := /bin/bash

.PHONY: help cluster registry trust-ca core cnpg tempo argo security obs dashboards minimal standard full chaos keda destroy status

help: ## Hedefler
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

cluster: ## kind cluster (1 cp + 3 worker) + Calico + local registry
	@kind get clusters 2>/dev/null | grep -qx $(KIND_NAME) || kind create cluster --config kind/cluster.yaml
	@kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/$(CALICO_VER)/manifests/calico.yaml >/dev/null
	@kubectl -n kube-system rollout status ds/calico-node --timeout=300s
	@kubectl wait --for=condition=Ready nodes --all --timeout=300s
	@$(MAKE) --no-print-directory trust-ca
	@$(MAKE) --no-print-directory registry

trust-ca: ## Kurumsal MITM kök CA'sını node'lara kur (Cloudflare Gateway/Zscaler ağlarında şart)
	@kind/trust-ca.sh

registry: ## localhost:5001 registry'yi kur/bağla
	@kind/registry.sh

core: ## ingress-nginx + metrics-server
	@kubectl apply -f $(INGRESS_URL) >/dev/null
	@kubectl -n ingress-nginx patch deploy ingress-nginx-controller --patch-file manifests/ingress-nginx-patch.yaml >/dev/null
	@kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s
	@kubectl apply -f $(METRICS_URL) >/dev/null
	@kubectl -n kube-system patch deploy metrics-server --patch-file manifests/metrics-server-patch.yaml >/dev/null
	@kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
	@echo "✔ core"

obs: ## kube-prometheus-stack + Loki + Alloy (namespace monitoring)
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	@helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
	   -f helm/kube-prometheus-stack.values.yaml --wait --timeout 15m
	@helm upgrade --install loki grafana/loki -n monitoring -f helm/loki.values.yaml --wait --timeout 10m
	@helm upgrade --install alloy grafana/alloy -n monitoring -f helm/alloy.values.yaml --wait --timeout 5m
	@kubectl apply -f manifests/obs-servicemonitors.yaml   # Loki/Alloy'un KENDİ metrikleri (P11-05)
	@$(MAKE) --no-print-directory dashboards
	@echo "✔ obs → http://grafana.localtest.me (admin/ladder)  http://prometheus.localtest.me"

dashboards: ## platform/dashboards/*.json → Grafana (sidecar ConfigMap, klasör Ladder)
	@python3 dashboards/gen.py
	@kubectl -n monitoring create configmap ladder-dashboards --from-file=dashboards/out/ --dry-run=client -o yaml \
	  | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
	  | kubectl annotate --local -f - grafana_folder=Ladder -o yaml --dry-run=client \
	  | kubectl apply -f - >/dev/null
	@echo "✔ dashboards ($$(ls dashboards/out | wc -l | tr -d ' ') adet)"

chaos: ## Chaos Mesh (02+)
	@helm repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true; helm repo update >/dev/null
	@helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace \
	   --set chaosDaemon.runtime=containerd --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
	   --set dashboard.create=false --set controllerManager.replicaCount=1 \
	   --set controllerManager.resources.requests.cpu=50m --set controllerManager.resources.requests.memory=128Mi \
	   --set chaosDaemon.resources.requests.cpu=25m --set chaosDaemon.resources.requests.memory=64Mi \
	   --wait --timeout 15m
	@echo "✔ chaos-mesh"

keda: ## KEDA (07+)
	@helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true; helm repo update >/dev/null
	@helm upgrade --install keda kedacore/keda -n keda --create-namespace --wait --timeout 10m
	@echo "✔ keda"

minimal: cluster core obs ## Profil: 00–05
standard: minimal chaos keda ## Profil: 06–10 (+redpanda, cnpg hedefleri 06/09'da eklenecek)
full: standard ## Profil: 11–14 (+tempo, argo… hedefleri 11/12'de eklenecek)

status: ## Ne kurulu?
	@kubectl get nodes; echo; helm list -A; echo; kubectl get ingress -A

destroy: ## Cluster'ı ve registry'yi sil
	kind delete cluster --name $(KIND_NAME); docker rm -f kind-registry 2>/dev/null || true

cnpg: ## CloudNativePG operatörü + MinIO (09+)
	@helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
	@helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace \
	   --set resources.requests.cpu=50m --set resources.requests.memory=100Mi --wait --timeout 10m
	@echo "✔ cnpg"

tempo: ## Grafana Tempo (trace) + Alloy OTLP alıcısı (11+)
	@helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true; helm repo update >/dev/null
	@helm upgrade --install tempo grafana/tempo -n monitoring -f helm/tempo.values.yaml --wait --timeout 10m
	@helm upgrade --install alloy grafana/alloy -n monitoring -f helm/alloy-otlp.values.yaml --wait --timeout 5m
	@echo "✔ tempo + alloy(otlp)"

# NOT: Sloth (SLO→kural üreteci) BİLEREK kullanılmıyor. Üreteç, burn-rate matematiğini bir
# soyutlamanın arkasına saklıyor; bu merdivende kuralları ELLE yazmak daha öğretici — pencereler,
# çarpanlar ve neden iki pencere gerektiği 11-observability-deep/deploy/slo.yaml'da görünür.

argo: ## Argo CD + Argo Rollouts + Gitea (cluster içi git) — 12+
	@helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
	@helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
	   -f helm/argocd.values.yaml --wait --timeout 15m
	@helm upgrade --install rollouts argo/argo-rollouts -n argo-rollouts --create-namespace \
	   --set controller.resources.requests.cpu=50m --set controller.resources.requests.memory=100Mi \
	   --set dashboard.enabled=false --wait --timeout 10m
	@echo "✔ argocd + rollouts → http://argocd.localtest.me (admin / $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d))"

security: ## cert-manager + sealed-secrets + Kyverno (13+)
	@helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
	@# NOT: sealed-secrets'in helm deposu bu ağdan 404 dönüyor (kurumsal proxy). Resmi release
	@# manifest'i çalışıyor; helm başarısız olursa ona düşüyoruz.
	@helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
	@helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
	   --set crds.enabled=true --set resources.requests.cpu=20m --set resources.requests.memory=64Mi \
	   --wait --timeout 10m
	@helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n kube-system \
	   --set resources.requests.cpu=20m --set resources.requests.memory=64Mi --wait --timeout 10m \
	   || kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml
	@helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
	   --set admissionController.replicas=1 --set backgroundController.enabled=true \
	   --set cleanupController.enabled=false --set reportsController.enabled=false \
	   --wait --timeout 15m
	@echo "✔ cert-manager + sealed-secrets + kyverno"

profile: ## Seviyeye göre bileşenleri aç/kapat: make profile L=07
	@test -n "$(L)" || { echo "L=<seviye no> gerekli (00..14)"; exit 2; }
	@lib/profile.sh $(L)
