# Kök Makefile — bütün seviyelerde toplu iş. Tek bir seviyeyle çalışmak için o klasöre gir: cd 03-local-cache && make up
LEVELS := $(sort $(wildcard [0-9][0-9]-*))

.PHONY: help list wipe full-run test lint lint-skeleton fmt verify sweep build matrix

help: ## Bu yardım
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

list: ## Seviyeleri listele
	@for l in $(LEVELS); do printf '%s\n' "$$l"; done

wipe: ## Bütün verileri sil (seviyeler, Grafana'da görünen metrik/trace/log), kurulumu koru: make wipe CONFIRM=1
	@CONFIRM=$(CONFIRM) platform/lib/wipe.sh

full-run: ## Tam tur 00 → 14 + rapor (8-12 sa; reports/tam-tur-<zaman>/RAPOR.md)
	@tools/full-run.sh

test: ## go test -race, tüm seviyeler (go.work kökünden ./... çalışmaz — modül döngüsü)
	@for l in $(LEVELS); do echo "== $$l"; (cd $$l && go test -race ./...) || exit 1; done

lint: lint-skeleton ## go vet + iskelet lint, tüm seviyeler
	@for l in $(LEVELS); do echo "== $$l"; (cd $$l && go vet ./...) || exit 1; done

lint-skeleton: ## Her seviyenin iskeleti şablonla aynı mı
	@for l in $(LEVELS); do tools/lint-skeleton.sh $$l || exit 1; done

build: ## Tüm seviyelerin image'larını derle (push yok)
	@for l in $(LEVELS); do echo "== $$l"; (cd $$l && $(MAKE) --no-print-directory build) || exit 1; done

fmt: ## gofmt farkı var mı? (yalnızca rapor, yazmaz)
	@out=$$(gofmt -l . 2>/dev/null); \
	 if [ -n "$$out" ]; then echo "gofmt gerekiyor:"; echo "$$out"; exit 1; fi; \
	 echo "gofmt temiz"

verify: fmt lint test ## Kümesiz doğrulama: gofmt + vet + iskelet lint + go test
	@echo; echo "✔ kümesiz doğrulama tamam (gofmt · go vet · iskelet lint · go test -race)"
	@echo "  Küme gerektiren doğrulama: tools/verify-sweep.sh <seviye> [<seviye> ...]"

sweep: ## Küme üzerinde uçtan uca doğrula: make sweep L="06-event-stream 07-services-autoscaling"
	@test -n "$(L)" || { echo "kullanım: make sweep L=\"06-event-stream 07-...\""; exit 1; }
	tools/verify-sweep.sh $(L)

matrix: ## Tüm problems/*.sh'yi tüm seviyelere koş, README matrisini üret (uzun sürer, seviyeleri sırayla ayağa kaldırır)
	tools/ladder-matrix/run.sh
