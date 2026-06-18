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
HELM          := helm

GITOPS_ENV ?= sandbox
K8S_NAMESPACE ?= dep-dlm-$(GITOPS_ENV)
KUBECTL       := kubectl -n $(K8S_NAMESPACE)

GITOPS_REVISION ?= main
GITOPS_REPO_URL ?=
ARGOCD_NAMESPACE ?= argocd
FLUX_NAMESPACE ?= flux-system
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
	@echo '  GITOPS_ENV = $(GITOPS_ENV) (sandbox | staging | production)'
	@echo '  K8S_NAMESPACE = $(K8S_NAMESPACE)'
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
	$(KUBECTL) create namespace $(K8S_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	$(HELM) dependency update $(HELM_CHART)
	$(HELM) install --set global.tokenMode=$(TOKEN_MODE) \
	--set rucio-daemons.enabled=$(if $(filter daemons,$(DAEMON_MODE)),true,false) \
	--set global.daemonMode=$(DAEMON_MODE) $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
endif

.PHONY: stop
stop: ## Stop the stack and remove volumes / PVCs
ifeq ($(RUNTIME),compose)
	$(COMPOSE) down -v
else
	$(HELM) uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE) || true
	$(KUBECTL) delete pvc --all --ignore-not-found
	$(KUBECTL) delete namespace $(K8S_NAMESPACE) --ignore-not-found
endif

.PHONY: restart
restart: stop start ## Tear down and start again

.PHONY: rebuild
rebuild: ## Rebuild one or more services: make rebuild SERVICES="fts teapot"  (compose: rebuild image; k8s: helm upgrade)
ifeq ($(RUNTIME),compose)
	$(COMPOSE) build  $(SERVICES)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICES)
else
	$(HELM) upgrade $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
endif

.PHONY: rebuild-clean
rebuild-clean: ## Rebuild from scratch (no cache) — use when a forked git dependency (davix/gfal2/fts) moved
ifeq ($(RUNTIME),compose)
	$(COMPOSE) build --no-cache $(SERVICES)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICES)
else
	$(HELM) upgrade $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
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
	@echo "k8s: use 'kubectl -n $(K8S_NAMESPACE) logs deploy/<name> -f'"
	@$(KUBECTL) get deploy -o name
endif

## GitOps

.PHONY: argocd-install
argocd-install: ## Install ArgoCD + bootstrap the chosen env (GITOPS_ENV=sandbox|staging|production)
	./shared/scripts/init-argocd.sh --env $(GITOPS_ENV) \
	    $(if $(GITOPS_REPO_URL),--repo-url $(GITOPS_REPO_URL)) \
	    $(if $(GITOPS_REVISION),--revision $(GITOPS_REVISION))

.PHONY: argocd-uninstall
argocd-uninstall: ## Uninstall ArgoCD applications and ArgoCD resources
	# 1. Delete the app-of-apps roots first (stops selfHeal recreating).
	kubectl -n $(ARGOCD_NAMESPACE) delete application dep-dlm-$(GITOPS_ENV)-apps dep-dlm-$(GITOPS_ENV)-secrets --ignore-not-found --wait=false
	# 2. Delete component apps but KEEP external-secrets so it can clear finalizers.
	kubectl -n $(ARGOCD_NAMESPACE) delete applications -l '!keep' --field-selector metadata.name!=external-secrets --ignore-not-found --wait=false || \
	  kubectl -n $(ARGOCD_NAMESPACE) delete application vault ruciodb rucio-server rucio-daemons rucio-bootstrap keycloak xrootd teapot fts --ignore-not-found --wait=false
	# 3. Clear ESO-managed resources while ESO is still alive.
	-kubectl delete clustersecretstore dep-dlm-vault --ignore-not-found
	-for es in $$(kubectl get externalsecret -n $(GITOPS_TARGET_NAMESPACE) -o name 2>/dev/null); do \
	  kubectl delete -n $(GITOPS_TARGET_NAMESPACE) $$es --ignore-not-found; done
	# 4. Now the namespace can finalize.
	kubectl delete namespace $(GITOPS_TARGET_NAMESPACE) --ignore-not-found --timeout=60s
	# 5. Finally remove ESO and Argo.
	kubectl -n $(ARGOCD_NAMESPACE) delete application external-secrets --ignore-not-found
	kubectl delete namespace $(ARGOCD_NAMESPACE) --ignore-not-found
	@echo "GitOps $(GITOPS_ENV) and Argo CD removed"

.PHONY: flux-install
flux-install: ## Install Flux + bootstrap the chosen env (GITOPS_ENV=sandbox|staging|production)
	./shared/scripts/init-flux.sh --env $(GITOPS_ENV) \
	    $(if $(GITOPS_REPO_URL),--repo-url $(GITOPS_REPO_URL)) \
	    $(if $(GITOPS_REVISION),--revision $(GITOPS_REVISION))

.PHONY: flux-uninstall
flux-uninstall: ## Uninstall Flux Kustomizations, Flux resources (GitRepository) and Flux controllers
	# 1. Suspend + delete the entrypoint Kustomizations (stops Flux re-reconciling).
	#    Reverse order: components -> secrets -> eso.
	kubectl -n $(FLUX_NAMESPACE) delete kustomization dep-dlm-$(GITOPS_ENV) --ignore-not-found --wait=false
	kubectl -n $(FLUX_NAMESPACE) delete kustomization dep-dlm-$(GITOPS_ENV)-secrets --ignore-not-found --wait=false
	# 2. Clear ESO-managed resources WHILE ESO is still alive (avoids finalizer deadlock).
	-kubectl delete clustersecretstore dep-dlm-vault --ignore-not-found
	-for es in $$(kubectl get externalsecret -n $(GITOPS_TARGET_NAMESPACE) -o name 2>/dev/null); do \
	  kubectl delete -n $(GITOPS_TARGET_NAMESPACE) $$es --ignore-not-found; done
	# 3. Now the workload namespace can finalize.
	kubectl delete namespace $(GITOPS_TARGET_NAMESPACE) --ignore-not-found --timeout=60s
	# 4. Remove ESO (its own Kustomization) and the HelmReleases it managed.
	kubectl -n $(FLUX_NAMESPACE) delete kustomization dep-dlm-$(GITOPS_ENV)-eso --ignore-not-found --wait=false
	# 5. Remove the GitRepository source.
	kubectl -n $(FLUX_NAMESPACE) delete gitrepository dep-dlm-testbed --ignore-not-found
	@echo "GitOps $(GITOPS_ENV) Flux Kustomizations removed (Flux controllers left intact)"
	# 6. Uinstall Flux itself
	flux uninstall --namespace=$(FLUX_NAMESPACE) --silent 2>/dev/null || \
	  kubectl delete namespace $(FLUX_NAMESPACE) --ignore-not-found
	@echo "Flux controllers removed"

## Helm-only

.PHONY: helm-lint
helm-lint: ## Lint the umbrella chart
	$(HELM) lint $(HELM_CHART)

.PHONY: helm-template
helm-template: ## Render manifests without installing
	$(HELM) template $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE) --set global.tokenMode=$(TOKEN_MODE) --set global.daemonMode=$(DAEMON_MODE)

## Tests

.PHONY: test-rucio-transfers
test-rucio-transfers: ## Rucio E2E TPC transfer test
	$(EXEC_RUCIO) bash -c "DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_rucio_transfers.py -v"

.PHONY: test-copernicus-transfers
test-copernicus-transfers: ## Rucio E2E TPC transfer test with Copernicus Sentinel data (WebDAV + OIDC)
	$(EXEC_RUCIO) bash -c "\
		S3_ACCESS_KEY='$(S3_ACCESS_KEY)' \
		S3_SECRET_KEY='$(S3_SECRET_KEY)' \
		DAEMON_MODE=$(DAEMON_MODE) \
		RUNTIME=$(RUNTIME) \
		K8S_NAMESPACE=$(K8S_NAMESPACE) \
		pytest /tests/test_rucio_transfers_with_copernicus.py -v"

.PHONY: test-rucio-deletion
test-rucio-deletion: ## Rucio E2E deletion test
	$(EXEC_RUCIO) bash -c "DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_rucio_deletion.py -v"

.PHONY: probe-teapot
probe-teapot: ## Teapot WebDAV probe with OIDC tokens
	$(EXEC_RUCIO) bash -c "DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) python3 /tests/probe_teapot_auth.py -v"

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
