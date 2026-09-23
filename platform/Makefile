# platform/Makefile — paylaşılan altyapı. Tek seferde: make full (önerilen) | standard | minimal
# Adım adım: make cluster → core → obs → chaos keda cnpg → tempo argo security
# İSİM: Docker Desktop yalnızca Compose projelerini gruplar; kind düğümleri ve registry ayrı
# `docker run`'lardır ve gruplanamaz. Ortak ön ek (linkly-*) onları listede yan yana tutar.
# kind'da küme adı sonradan DEĞİŞTİRİLEMEZ: değiştirirsen `make destroy` + yeniden kurulum.
# Tek kaynak burası: `make cluster` kind/cluster.yaml'daki `name:`i --name ile ezer.
KIND_NAME := linkly
REG_NAME  := linkly-registry
export KIND_NAME REG_NAME
# ESKİ ADLAR (23 Eylül 2026 öncesi). `make cluster` bunları görürse durur, `make destroy` siler:
# ad değişikliği bir geçiş yolu gerektirir, yoksa eski küme hiçbir hedefin ulaşamadığı yerde kalır
# ve yenisi 80/443 portlarında onunla çakışır.
LEGACY_KIND_NAME := ladder
LEGACY_REG_NAME  := kind-registry
# kind/shim/docker kind'ın `docker run`larına Compose etiketi ekler (Docker Desktop gruplaması).
REAL_DOCKER := $(shell command -v docker)
CALICO_VER := v3.29.3
INGRESS_URL := https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
METRICS_URL := https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
SHELL := /bin/bash

.PHONY: help stop start cluster registry trust-ca core cnpg tempo argo security obs dashboards minimal standard full chaos keda destroy status

help: ## Hedefler
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

cluster: ## kind cluster (1 cp + 3 worker) + Calico + local registry
	@if kind get clusters 2>/dev/null | grep -qx $(LEGACY_KIND_NAME); then \
	  echo "✘ eski '$(LEGACY_KIND_NAME)' kümesi hâlâ var ve 80/443 portlarını tutuyor. Önce: make destroy"; exit 1; fi
	@# --name, cluster.yaml'daki `name:`i ezer: küme adının TEK kaynağı bu Makefile.
	@kind get clusters 2>/dev/null | grep -qx $(KIND_NAME) || \
	  PATH="$(CURDIR)/kind/shim:$$PATH" LADDER_REAL_DOCKER="$(REAL_DOCKER)" kind create cluster --name $(KIND_NAME) --config kind/cluster.yaml
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

# Hangi seviye neyi istiyor (platform/lib/profile.sh bunları açar/kapatır, eksikse SÖYLER):
#   00-01 temel · 02+ chaos · 07+ keda · 09+ cnpg · 11 tempo · 12+ argo · 13+ security
minimal: cluster core obs ## Seviye 00-01 için yeterli (~10 dk)
standard: minimal chaos keda cnpg ## Seviye 02-10 (~15 dk)
full: standard tempo argo security ## HER ŞEY — önerilen; profil kullanılmayanları kapatır (~20-25 dk)

status: ## Ne kurulu?
	@kubectl get nodes; echo; helm list -A; echo; kubectl get ingress -A

stop: ## Kümeyi ve registry'yi DURDUR (silmez; `make start` ile geri gelir)
	@# ÖNCE containerd'yi düğümün İÇİNDE durdur: `docker stop` bir systemd makinesine SIGKILL
	@# gönderirse containerd'nin meta veri deposu yazma ortasında kalabilir. ÖLÇÜLDÜ: control-plane'in
	@# kendi systemd kapanışı `-t 60` ile bile bitmiyor (60 sn bekleyip yine 137) — süreyi uzatmak
	@# koruma değil bekleme; containerd'yi kapatmak ise anlık ve deposunu temiz bırakıyor.
	@nodes=$$(kind get nodes --name $(KIND_NAME) 2>/dev/null); \
	  [ -n "$$nodes" ] || { echo "✘ '$(KIND_NAME)' kümesi yok"; exit 1; }; \
	  for n in $$nodes; do docker exec $$n systemctl stop kubelet containerd >/dev/null 2>&1 || true; done; \
	  docker stop $$nodes >/dev/null && echo "✔ düğümler durduruldu"
	@docker stop $(REG_NAME) >/dev/null 2>&1 && echo "✔ registry durduruldu" || echo "  (registry yok ya da zaten durmuş)"

start: ## Durdurulmuş kümeyi ve registry'yi başlat, düğümler Ready olana kadar bekle
	@nodes=$$(kind get nodes --name $(KIND_NAME) 2>/dev/null); \
	  [ -n "$$nodes" ] || { echo "✘ '$(KIND_NAME)' kümesi yok — önce: make cluster"; exit 1; }; \
	  docker start $$nodes >/dev/null
	@docker start $(REG_NAME) >/dev/null 2>&1 || echo "  (registry yok — imajlar için: make registry)"
	@# Açılışın ilk saniyelerinde API sunucusu RBAC önbelleği dolmadan "Forbidden" döner ve
	@# `kubectl wait` bunu kalıcı hata sayıp hemen düşer. Önce /readyz'i bekle — ve bekleme
	@# biterse bunu SÖYLE: sessiz bir zaman aşımı, sonraki adımın hatasını yanlış sebebe bağlatır.
	@kubectl config use-context kind-$(KIND_NAME) >/dev/null
	@for i in $$(seq 1 120); do \
	  kubectl get --raw /readyz >/dev/null 2>&1 && break; \
	  [ $$i = 1 ] && echo "  API sunucusu bekleniyor (en fazla 10 dk)..."; \
	  [ $$i = 120 ] && { echo "✘ API sunucusu 10 dk'da hazır olmadı: docker logs $(KIND_NAME)-control-plane"; exit 1; }; \
	  sleep 5; \
	done
	@kubectl wait --for=condition=Ready nodes --all --timeout=600s >/dev/null && echo "✔ başladı"

destroy: ## Cluster'ı ve registry'yi sil (eski adlarla kalmış olanlar dahil)
	kind delete cluster --name $(KIND_NAME); docker rm -f $(REG_NAME) 2>/dev/null || true
	@kind delete cluster --name $(LEGACY_KIND_NAME) 2>/dev/null || true; docker rm -f $(LEGACY_REG_NAME) 2>/dev/null || true

cnpg: ## CloudNativePG operatörü + MinIO (09+)
	@helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
	@helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@# Lider kirası 15/10 sn yerine 60/45 sn: paylaşılan VM'de lease yazması 25 sn'ye çıkıyor ve
	@# operatör saatte birkaç kez kirayı kaybedip yeniden başlıyordu (23 restart). Gerekçe:
	@# kind/cluster.yaml'daki controller-manager notu.
	@helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace \
	   --set resources.requests.cpu=50m --set resources.requests.memory=100Mi \
	   --set 'additionalArgs={--leader-lease-duration=60,--leader-renew-deadline=45}' --wait --timeout 10m
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
	   --set dashboard.enabled=false \
	   --set 'controller.extraArgs={--leader-election-lease-duration=60s,--leader-election-renew-deadline=45s,--leader-election-retry-period=5s}' \
	   --wait --timeout 10m
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
	@# KYVERNO'NUN PROBE BÜTÇESİ BU KÜMEDE YETMİYOR — ve yetmemesi TÜM KÜMEYİ kilitliyor.
	@# Varsayılan startup probe'u `timeout=1s period=6s failure=20`: yüklü bir kind kümesinde
	@# Kyverno'nun HTTPS sağlık ucu 1 saniyede cevap veremiyor, kubelet konteyneri öldürüyor ve
	@# admission controller CRASH LOOP'a giriyor. Kyverno'nun webhook'u `failurePolicy: Fail`
	@# olduğu için bu yalnızca Kyverno'yu değil, KÜMEDEKİ HER YAZMAYI bozuyor: local-path
	@# provisioner PVC oluşturamadı ("failed calling webhook validate.kyverno.svc-fail:
	@# connection refused"), Postgres hiç kalkmadı ve 14. seviye AYAĞA KALKMADI. P14-05'in
	@# "erişilebilirlik %4.37" sonucu buradan geliyordu: sistem çökmemişti, HİÇ KURULMAMIŞTI.
	@# Ders (Prometheus WAL OOM'u ile aynı): bir bileşenin bütçesini KARARLI durumuna göre değil
	@# EN KÖTÜ ANINA göre seç — hele ki o bileşen kümenin yazma yoluna zincirlenmişse.
	@# EN: the default startup probe (timeout=1s) is not enough on a loaded kind cluster, so the
	@# admission controller crash-loops; and because its webhook is `failurePolicy: Fail`, that
	@# breaks EVERY write in the cluster, not just Kyverno's. The local-path provisioner could not
	@# create the PVC, Postgres never initialised and level 14 never came up — which is where
	@# P14-05's "4.37% availability" actually came from: the system had not collapsed, it had
	@# never been built.
	@# FAIL-OPEN (forceFailurePolicyIgnore): probe bütçesi yetmedi. Kyverno'nun kirası kodda sabit
	@# (15/10 sn) ve API sunucusu yavaşladığında kirayı kaybedip yeniden başlıyor; bu sürede
	@# failurePolicy: Fail webhook'u kümedeki HER yazmayı reddediyor — `make up` üç denemede de
	@# "failed calling webhook ... connection refused" ile düştü. P08-01'in limiter seçiminin aynısı:
	@# Kyverno düşükken politika uygulanmaz (koruma kaybolur, telafi edilebilir), ama küme kilitlenmez
	@# (hizmet kaybolmaz). Bedeli: o pencerede kuralsız bir pod kabul edilebilir; Kyverno'nun arka
	@# plan taraması onu sonradan raporlar. KAPSAMI: yalnızca KAYNAK webhook'u (pod, PVC, ...)
	@# Ignore olur; Kyverno'nun kendi nesnelerini (ClusterPolicy, exception) doğrulayan webhook'lar
	@# Fail kalır — Kyverno düşükken seviyenin ClusterPolicy'si yazılamaz, `make deploy` yeniden dener.
	@# EN: fail-open — while Kyverno is down, policies are not enforced, but the cluster keeps working.
	@helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
	   --set admissionController.replicas=1 --set backgroundController.enabled=true \
	   --set cleanupController.enabled=false --set reportsController.enabled=false \
	   --set admissionController.startupProbe.timeoutSeconds=5 \
	   --set admissionController.startupProbe.periodSeconds=10 \
	   --set admissionController.startupProbe.failureThreshold=30 \
	   --set admissionController.readinessProbe.timeoutSeconds=10 \
	   --set admissionController.livenessProbe.timeoutSeconds=10 \
	   --set features.forceFailurePolicyIgnore.enabled=true \
	   --wait --timeout 15m
	@echo "✔ cert-manager + sealed-secrets + kyverno"

profile: ## Seviyeye göre bileşenleri aç/kapat: make profile L=07
	@test -n "$(L)" || { echo "L=<seviye no> gerekli (00..14)"; exit 2; }
	@lib/profile.sh $(L)
