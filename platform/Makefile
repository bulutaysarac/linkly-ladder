# platform/Makefile — paylaşılan altyapı. Sıra: make cluster → make core → make obs → make dashboards
# ya da tek seferde: make minimal | standard | full
KIND_NAME := ladder
CALICO_VER := v3.29.3
INGRESS_URL := https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
METRICS_URL := https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
SHELL := /bin/bash

.PHONY: help cluster registry trust-ca core obs dashboards minimal standard full chaos keda destroy status

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
