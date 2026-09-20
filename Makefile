# Kök Makefile — bütün seviyelerde toplu iş. Tek bir seviyeyle çalışmak için o klasöre gir: cd 03-local-cache && make up
LEVELS := $(sort $(wildcard [0-9][0-9]-*))

.PHONY: help list test lint lint-skeleton build matrix

help: ## Bu yardım
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

list: ## Seviyeleri listele
	@for l in $(LEVELS); do printf '%s\n' "$$l"; done

test: ## go test -race, tüm seviyeler (go.work kökünden ./... çalışmaz — modül döngüsü)
	@for l in $(LEVELS); do echo "== $$l"; (cd $$l && go test -race ./...) || exit 1; done

lint: lint-skeleton ## go vet + iskelet lint, tüm seviyeler
	@for l in $(LEVELS); do echo "== $$l"; (cd $$l && go vet ./...) || exit 1; done

lint-skeleton: ## Her seviyenin iskeleti şablonla aynı mı
	@for l in $(LEVELS); do tools/lint-skeleton.sh $$l || exit 1; done

build: ## Tüm seviyelerin image'larını derle (push yok)
	@for l in $(LEVELS); do echo "== $$l"; (cd $$l && $(MAKE) --no-print-directory build) || exit 1; done

matrix: ## Tüm problems/*.sh'yi tüm seviyelere koş, README matrisini üret (uzun sürer, seviyeleri sırayla ayağa kaldırır)
	tools/ladder-matrix/run.sh
