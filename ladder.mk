# ladder.mk — her seviyenin Makefile'ı sadece şudur:
#   LEVEL := NN
#   NAME  := isim
#   include ../ladder.mk
# Seviyeye özel hedef YOK. Seviyeye özel iş gerekiyorsa deploy/ manifest'lerine sığdırılır.

ifndef LEVEL
$(error LEVEL tanımlı değil)
endif
ifndef NAME
$(error NAME tanımlı değil)
endif

ROOT        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PLATFORM    := $(ROOT)/platform
NS          := lvl$(LEVEL)
HOST        := lvl$(LEVEL).localtest.me
BASE_URL    ?= http://$(HOST)
PROM_URL    ?= http://prometheus.localtest.me
GRAFANA_URL ?= http://grafana.localtest.me
REGISTRY    ?= localhost:5001
IMAGE_BASE  := $(REGISTRY)/linkly-ladder/$(LEVEL)
SHA         := $(shell git -C $(ROOT) rev-parse --short HEAD 2>/dev/null || echo dev)
DIRTY       := $(shell git -C $(ROOT) diff --quiet -- $(CURDIR) 2>/dev/null || echo -dirty)
# TAG kaynak içeriğinin hash'i: deterministik. Zaman damgası kullanılsaydı `make push` ve `make deploy`
# ayrı çağrıldığında farklı tag üretir, deploy olmayan bir imajı arardı (ImagePullBackOff).
SRCHASH     := $(shell find . -type f \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -name 'Dockerfile' \) \
                 -not -path './bin/*' | sort | xargs shasum 2>/dev/null | shasum | cut -c1-10)
TAG         ?= $(SHA)-$(SRCHASH)
SERVICES    := $(notdir $(wildcard cmd/*))
PREV        := $(shell ls -d $(ROOT)/[0-9][0-9]-*/ | sort | awk -v cur="$(ROOT)/$(LEVEL)-$(NAME)/" '$$0==cur{print prev; exit}{prev=$$0}')
EXPORT_ENV  := NS=$(NS) LEVEL=$(LEVEL) BASE_URL=$(BASE_URL) PROM_URL=$(PROM_URL) GRAFANA_URL=$(GRAFANA_URL) LADDER_ROOT=$(ROOT)

.PHONY: help build push deploy wait smoke up down status load repro chaos unchaos grafana logs diff-prev verify-prev test lint

help: ## Hedefler
	@echo "Seviye $(LEVEL) ($(NAME))  namespace=$(NS)  url=$(BASE_URL)  servisler=$(SERVICES)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(ROOT)/ladder.mk | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## cmd/* altındaki her servisi image'a derle
	@for s in $(SERVICES); do \
	  echo "== build $(IMAGE_BASE)-$$s:$(TAG)"; \
	  docker build -q --build-arg SVC=$$s --build-arg VERSION=$(TAG) -t $(IMAGE_BASE)-$$s:$(TAG) . || exit 1; \
	done

push: build ## Local registry'ye push
	@for s in $(SERVICES); do docker push -q $(IMAGE_BASE)-$$s:$(TAG) || exit 1; done

deploy: ## kubectl apply -k deploy/ (IMAGE_TAG yerine gerçek tag)
	@kubectl kustomize deploy/ | sed 's|:IMAGE_TAG|:$(TAG)|g' | kubectl apply -f -

wait: ## Deployment/StatefulSet + (varsa) Argo Rollout hazır olana kadar bekle
	@for d in $$(kubectl -n $(NS) get deploy,statefulset -o name 2>/dev/null); do kubectl -n $(NS) rollout status $$d --timeout=240s || exit 1; done
	@# `kubectl rollout status` Argo Rollout'u tanımaz (yalnızca yerleşik türler). 12+ seviyelerde
	@# beklemezsek smoke, henüz hazır olmayan bir uygulamaya çarpar.
	@for r in $$(kubectl -n $(NS) get rollout -o name 2>/dev/null); do \
	  want=$$(kubectl -n $(NS) get $$r -o jsonpath='{.spec.replicas}'); \
	  for i in $$(seq 1 120); do \
	    got=$$(kubectl -n $(NS) get $$r -o jsonpath='{.status.readyReplicas}' 2>/dev/null); \
	    [ "$${got:-0}" -ge "$${want:-1}" ] && break; sleep 2; \
	  done; \
	  echo "  $$r hazır: $${got:-0}/$${want:-1}"; \
	done

smoke: ## POST + GET 30x
	@$(EXPORT_ENV) $(PLATFORM)/lib/smoke.sh

up: push deploy wait smoke ## build → push → deploy → wait → smoke
	@echo; echo "✔ $(NS) ayakta → $(BASE_URL)"; echo "  Grafana: $(GRAFANA_URL)/dashboards?query=Ladder  (level=$(NS))"

down: ## Namespace'i sil
	kubectl delete namespace $(NS) --ignore-not-found --wait=false

status: ## Pod/servis durumu
	@kubectl -n $(NS) get pods,svc,ingress,hpa 2>/dev/null

load: ## k6 senaryosu: make load S=redirect [K6_ARGS="--vus 50 --duration 30s"]
	@test -n "$(S)" || { echo "S=<senaryo> gerekli: $$(ls $(PLATFORM)/k6/scenarios | sed 's/.js//' | tr '\n' ' ')"; exit 2; }
	@$(EXPORT_ENV) $(PLATFORM)/lib/k6run.sh $(S) $(K6_ARGS)

repro: ## Sorunu reproduce et: make repro P=P00-01  (CONFIRM=1 yıkıcılar için)
	@test -n "$(P)" || { echo "P=<PNN-XX> gerekli: $$(ls problems | grep -o 'P[0-9]*-[0-9]*' | tr '\n' ' ')"; exit 2; }
	@$(EXPORT_ENV) bash problems/$(P).sh

chaos: ## Chaos şablonu uygula: make chaos C=pg-delay-2s
	@test -n "$(C)" || { echo "C=<şablon> gerekli: $$(ls $(PLATFORM)/chaos | sed 's/.yaml//' | tr '\n' ' ')"; exit 2; }
	@$(EXPORT_ENV) $(PLATFORM)/lib/chaos.sh apply $(C)

unchaos: ## Chaos'u kaldır: make unchaos C=pg-delay-2s (C boşsa hepsini)
	@$(EXPORT_ENV) $(PLATFORM)/lib/chaos.sh delete "$(C)"

grafana: ## Grafana'yı bu seviye seçili aç
	@echo "$(GRAFANA_URL)/dashboards?query=Ladder   (admin / ladder)"; open "$(GRAFANA_URL)/dashboards?query=Ladder" 2>/dev/null || true

logs: ## Uygulama logları
	kubectl -n $(NS) logs -l app.kubernetes.io/part-of=linkly-ladder --all-containers --tail=200 -f

diff-prev: ## Bir önceki seviyeyle fark (README, go.sum, problems hariç)
	@test -n "$(PREV)" || { echo "önceki seviye yok"; exit 0; }
	@echo "== $(PREV) → $(CURDIR)"; diff -ruN -x README.md -x go.sum -x problems -x bin "$(PREV)" . --color=auto || true

verify-prev: ## Önceki seviyenin problems/*.sh'sini bu namespace'e koş; problems/SOLVES'takiler NOT-REPRODUCED olmalı
	@test -n "$(PREV)" || { echo "önceki seviye yok"; exit 0; }
	@$(EXPORT_ENV) $(PLATFORM)/lib/verify-prev.sh "$(PREV)" problems/SOLVES

test: ## go test -race
	go test -race ./...

lint: ## go vet + iskelet lint
	go vet ./... && $(ROOT)/tools/lint-skeleton.sh $(CURDIR)
