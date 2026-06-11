SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Anchor for compose bind-mounts. Override if running from an unusual shell.
export TESTBED_HOST_SOURCE ?= $(CURDIR)

RUNTIME    ?= compose
TOKEN_MODE ?= managed
DAEMON_MODE ?= direct
SERVICES   ?=

COMPOSE_FILE  ?= deploy/compose/docker-compose.$(TOKEN_MODE).yml
COMPOSE       := docker compose -f $(COMPOSE_FILE)

HELM_CHART    := deploy/helm-charts/dep-dlm-testbed
HELM_RELEASE  ?= testbed
UMBRELLA_CHART_NAMESPACE ?= dep-dlm-testbed
KUBECTL       := kubectl -n $(UMBRELLA_CHART_NAMESPACE)
HELM          := helm

# GitOps (Argo CD sandbox bootstrap)
ARGOCD_REPO_URL ?=
ARGOCD_REVISION ?=
ARGOCD_NAMESPACE ?= argocd
APP_SANDBOX_NAMESPACE ?= dep-dlm-sandbox

# ── Validation ─────────────────────────────────────────────────────

ifeq ($(filter $(TOKEN_MODE),managed unmanaged),)
$(error TOKEN_MODE must be 'managed' or 'unmanaged', got '$(TOKEN_MODE)')
endif

ifeq ($(filter $(DAEMON_MODE),direct daemons),)
$(error DAEMON_MODE must be 'direct' or 'daemons', got '$(DAEMON_MODE)')
endif

ifeq ($(filter $(RUNTIME),compose k8s),)
$(error RUNTIME must be 'compose' or 'k8s', got '$(RUNTIME)')
endif

# ── Runtime-specific execution wrappers ────────────────────────────

ifeq ($(RUNTIME),k8s)
EXEC_RUCIO := $(KUBECTL) exec deploy/rucio-client --
else
EXEC_RUCIO := docker exec compose-rucio-client-1
endif

# ── Help ───────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help (default target)
	@echo ''
	@echo 'dep-dlm-testbed'
	@echo ''
	@echo '  RUNTIME    = $(RUNTIME)    (compose | k8s)'
	@echo '  TOKEN_MODE = $(TOKEN_MODE) (managed | unmanaged)'
	@echo '  DAEMON_MODE = $(DAEMON_MODE) (direct | daemons)'
	@echo ''
	@echo 'Usage:'
	@echo '  make <target> [RUNTIME=compose|k8s] [TOKEN_MODE=managed|unmanaged] [DAEMON_MODE=direct|daemons] [SERVICES="svc1 svc2"]'
	@echo ''
	@awk 'BEGIN {FS = ":.*?## "} \
	    /^[a-zA-Z0-9_%-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	    /^## / { sub(/^## /, ""); printf "\n\033[1m%s\033[0m\n", $$0 }' $(MAKEFILE_LIST)

## Setup

.PHONY: certs
certs: ## Generate certificates (CA, host certs)
	./shared/scripts/generate-certs.sh

.PHONY: init
init: ## Initialize the testbed (accounts, RSEs, OIDC seed)
	./shared/scripts/init-testbed.sh

## Lifecycle

.PHONY: start
start: ## Start the stack
ifeq ($(RUNTIME),compose)
	COMPOSE_PROFILES=$(DAEMON_MODE) $(COMPOSE) up -d $(SERVICES)
else
	$(KUBECTL) create namespace $(UMBRELLA_CHART_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	$(HELM) dependency update $(HELM_CHART)
	$(HELM) install --set global.tokenMode=$(TOKEN_MODE) \
	--set rucio-daemons.enabled=$(if $(filter daemons,$(DAEMON_MODE)),true,false) \
	--set global.daemonMode=$(DAEMON_MODE) $(HELM_RELEASE) $(HELM_CHART) -n $(UMBRELLA_CHART_NAMESPACE)
endif

.PHONY: stop
stop: ## Stop the stack and remove volumes / PVCs
ifeq ($(RUNTIME),compose)
	$(COMPOSE) down -v
else
	$(HELM) uninstall $(HELM_RELEASE) -n $(UMBRELLA_CHART_NAMESPACE) || true
	$(KUBECTL) delete pvc --all --ignore-not-found
	$(KUBECTL) delete namespace $(UMBRELLA_CHART_NAMESPACE) --ignore-not-found
endif

.PHONY: restart
restart: stop start ## Tear down and start again

.PHONY: rebuild
rebuild: ## Rebuild one or more services: make rebuild SERVICES="fts teapot"  (compose: rebuild image; k8s: helm upgrade)
ifeq ($(RUNTIME),compose)
	$(COMPOSE) build  $(SERVICES)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICES)
else
	$(HELM) upgrade $(HELM_RELEASE) $(HELM_CHART) -n $(UMBRELLA_CHART_NAMESPACE)
endif

.PHONY: rebuild-clean
rebuild-clean: ## Rebuild from scratch (no cache) — use when a forked git dependency (davix/gfal2/fts) moved
ifeq ($(RUNTIME),compose)
	$(COMPOSE) build --no-cache $(SERVICES)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICES)
else
	$(HELM) upgrade $(HELM_RELEASE) $(HELM_CHART) -n $(UMBRELLA_CHART_NAMESPACE)
endif

.PHONY: ps
ps: ## Show running services / pods
ifeq ($(RUNTIME),compose)
	$(COMPOSE) ps
else
	$(KUBECTL) get pods,svc
endif

.PHONY: logs
logs: ## Tail logs (all services, or pass SERVICES="..." for a subset)
ifeq ($(RUNTIME),compose)
	$(COMPOSE) logs -f --tail=100 $(SERVICES)
else
	@echo "k8s: use 'kubectl -n $(UMBRELLA_CHART_NAMESPACE) logs deploy/<name> -f'"
	@$(KUBECTL) get deploy -o name
endif

## GitOps

.PHONY: argocd-sandbox-install
argocd-sandbox-install: ## Install Argo CD and bootstrap the sandbox app-of-apps (override ARGOCD_REPO_URL / ARGOCD_REVISION to test from a fork/branch)
	./shared/scripts/init-argocd.sh \
	    $(if $(ARGOCD_REPO_URL),--repo-url $(ARGOCD_REPO_URL)) \
	    $(if $(ARGOCD_REVISION),--revision $(ARGOCD_REVISION))

.PHONY: argocd-sandbox-uninstall
argocd-sandbox-uninstall: ## Uninstall GitOps sandbox (Argo apps, workloads, store) and Argo CD itself
	# 1. Delete Applications first so Argo's selfHeal can't recreate resources.
	kubectl -n $(ARGOCD_NAMESPACE) delete application dep-dlm-sandbox --ignore-not-found
	kubectl -n $(ARGOCD_NAMESPACE) delete applications --all --ignore-not-found
	# 2. Namespaced workloads.
	kubectl delete namespace $(APP_SANDBOX_NAMESPACE) --ignore-not-found
	# 3. Cluster-scoped resources the overlay created.
	kubectl delete clustersecretstore dep-dlm-vault --ignore-not-found
	@echo "GitOps sandbox and Argo CD removed"
	kubectl delete namespace $(ARGOCD_NAMESPACE) --ignore-not-found

## Helm-only

.PHONY: helm-lint
helm-lint: ## Lint the umbrella chart
	$(HELM) lint $(HELM_CHART)

.PHONY: helm-template
helm-template: ## Render manifests without installing
	$(HELM) template $(HELM_RELEASE) $(HELM_CHART) -n $(UMBRELLA_CHART_NAMESPACE) --set global.tokenMode=$(TOKEN_MODE) --set global.daemonMode=$(DAEMON_MODE)

## Tests

.PHONY: test-rucio-transfers
test-rucio-transfers: ## Rucio E2E TPC transfer test
	$(EXEC_RUCIO) bash -c "DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(UMBRELLA_CHART_NAMESPACE) pytest /tests/test_rucio_transfers.py -v"

.PHONY: test-copernicus-transfers
test-copernicus-transfers: ## Rucio E2E TPC transfer test with Copernicus Sentinel data (WebDAV + OIDC)
	$(EXEC_RUCIO) bash -c "\
		S3_ACCESS_KEY='$(S3_ACCESS_KEY)' \
		S3_SECRET_KEY='$(S3_SECRET_KEY)' \
		DAEMON_MODE=$(DAEMON_MODE) \
		RUNTIME=$(RUNTIME) \
		K8S_NAMESPACE=$(UMBRELLA_CHART_NAMESPACE) \
		pytest /tests/test_rucio_transfers_with_copernicus.py -v"

.PHONY: test-rucio-deletion
test-rucio-deletion: ## Rucio E2E deletion test
	$(EXEC_RUCIO) bash -c "DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(UMBRELLA_CHART_NAMESPACE) pytest /tests/test_rucio_deletion.py -v"

.PHONY: probe-teapot
probe-teapot: ## Teapot WebDAV probe with OIDC tokens
	$(EXEC_RUCIO) bash -c "DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(UMBRELLA_CHART_NAMESPACE) python3 /tests/probe_teapot_auth.py -v"

## Cleanup

.PHONY: clean
clean: ## Remove generated certs and compose volumes (keeps CA)
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	find certs \
	    ! -name 'rucio_ca.pem' \
	    ! -name 'rucio_ca.key.pem' \
	    \( -name '*.pem' -o -name '*.namespaces' -o -name '*.signing_policy' \
	     -o -name '*.csr' -o -name '*.r0' -o -name '*.0' \) \
	    -delete 2>/dev/null || true
	@echo "Cleaned certs (preserved rucio_ca.pem and rucio_ca.key.pem) and volumes"
