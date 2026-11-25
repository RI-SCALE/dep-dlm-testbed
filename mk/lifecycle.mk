# Lifecycle: compose / Helm stack and Helm-only helpers.
# Included from the Makefile after mk/config.mk.

HELM_CHART    := deploy/helm-charts/dep-dlm-testbed
HELM_RELEASE  ?= testbed
HELM          := helm

# Shared by install, upgrade and template so they all render the same release.
HELM_SET = --set global.tokenMode=$(TOKEN_MODE) \
	--set global.daemonMode=$(DAEMON_MODE) \
	--set global.scopeProfile=$(SCOPE_PROFILE) \
	--set rucio-daemons.enabled=$(if $(filter daemons,$(DAEMON_MODE)),true,false) \
	--set observability.enabled=$(if $(filter 1,$(OBSERVABILITY)),true,false) \
	--set usage-reporter.enabled=true \
	$(if $(filter local,$(SCOPE_PROFILE)),,--set-string global.usageReporterClientSecret=$(REPORTER_RUCIO_CLIENT_SECRET))

# Helm creates subchart CRDs only on first install, never on upgrade, so apply
# the Prometheus Operator CRDs explicitly (server-side: they exceed the annotation limit).
OBS_CRDS = $(if $(filter 1,$(OBSERVABILITY)),$(HELM) show crds $(HELM_CHART)/charts/kube-prometheus-stack-*.tgz \
	| kubectl apply --server-side --force-conflicts -f - >/dev/null,true)

## Lifecycle

.PHONY: start
start: ## Start the stack
ifeq ($(RUNTIME),compose)
	COMPOSE_PROFILES=$(DAEMON_MODE) $(COMPOSE) up -d $(SERVICES)
else
	$(KUBECTL) create namespace $(K8S_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	source scripts/common.sh && ensure_helm_chart_deps
	$(OBS_CRDS)
	@$(HELM) upgrade --install $(HELM_SET) $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
endif

.PHONY: stop
stop: ## Stop the stack, remove volumes / PVCs
ifeq ($(RUNTIME),compose)
	$(COMPOSE_ALL) down -v --remove-orphans
else
	$(HELM) uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE) || true
	$(KUBECTL) delete pvc --all --ignore-not-found
	$(KUBECTL) delete namespace $(K8S_NAMESPACE) --ignore-not-found
endif

.PHONY: restart
restart: stop start ## Tear down and start again

.PHONY: rebuild
rebuild: ## Rebuild services (SERVICES="fts teapot")
ifeq ($(RUNTIME),compose)
	$(COMPOSE) build  $(SERVICES)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICES)
else
	$(OBS_CRDS)
	@$(HELM) upgrade $(HELM_SET) $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
endif

.PHONY: rebuild-clean
rebuild-clean: ## Rebuild from scratch, no cache
ifeq ($(RUNTIME),compose)
	$(COMPOSE) build --no-cache $(SERVICES)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICES)
else
	$(OBS_CRDS)
	@$(HELM) upgrade $(HELM_SET) $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
endif

.PHONY: ps
ps: ## Show running services / pods
ifeq ($(RUNTIME),compose)
	$(COMPOSE) ps
else
	$(KUBECTL) get pods,svc
endif

.PHONY: logs
logs: ## Tail logs (SERVICES="..." for a subset)
ifeq ($(RUNTIME),compose)
	$(COMPOSE) logs --tail=100 $(SERVICES)
else
	@echo "k8s: use 'kubectl -n $(K8S_NAMESPACE) logs deploy/<name> -f'"
	@$(KUBECTL) get deploy -o name
endif

## Helm-only

.PHONY: helm-lint
helm-lint: ## Lint the umbrella chart
	$(HELM) lint $(HELM_CHART)

.PHONY: helm-template
helm-template: ## Render manifests without installing
	$(HELM) template $(HELM_SET) $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
