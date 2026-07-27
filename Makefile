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

# COPERNICUS S3 credentials (env-overridable; defaults = empty)
S3_ACCESS_KEY ?=
S3_SECRET_KEY ?=

# OIDC provider (env-overridable; empty = use test defaults / Keycloak)
OIDC_ISSUER           ?=
OIDC_TOKEN_URL        ?=
OIDC_CLIENT_ID        ?=
OIDC_CLIENT_SECRET    ?=
OIDC_STORAGE_SCOPE    ?=
OIDC_TEAPOT_AUD_SCOPE ?=
OIDC_GRANT_TYPE       ?= password

## Terraform

TF_ENV          ?= staging
TF_DIR          := deploy/terraform/environments/$(TF_ENV)
TF_STATE_BUCKET ?= dep-dlm-tfstate-$(TF_ENV)
TF_STATE_PREFIX ?= $(TF_ENV)
GCP_PROJECT_ID  ?=
GCP_REGION      ?= europe-west3
TERRAFORM       := terraform -chdir=$(TF_DIR)

# CI passes AUTO_APPROVE=1 for non-interactive apply/destroy; local use
# defaults to interactive confirmation, same as running terraform directly.
AUTO_APPROVE ?=
ifeq ($(AUTO_APPROVE),1)
  TF_AUTO_APPROVE_FLAG := -auto-approve
else
  TF_AUTO_APPROVE_FLAG :=
endif

# Test env injection: only export OIDC_* overrides when targeting an
# external IdP profile. Passing OIDC_ISSUER='' etc. unconditionally would
# shadow conftest.py's os.environ.get(..., default) fallback for the local/
# Keycloak path, since an empty string still counts as "set".
ifeq ($(SCOPE_PROFILE),local)
  TEST_OIDC_ENV :=
else
  TEST_OIDC_ENV := OIDC_ISSUER='$(OIDC_ISSUER)' OIDC_TOKEN_URL='$(OIDC_TOKEN_URL)' \
    OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' \
    OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' OIDC_GRANT_TYPE='$(OIDC_GRANT_TYPE)' \
    OIDC_STORAGE_SCOPE='$(OIDC_STORAGE_SCOPE)' OIDC_TEAPOT_AUD_SCOPE=''
endif

SCOPE_PROFILE ?= local

ifeq ($(SCOPE_PROFILE),local)
  export CONFIG_PROFILE_DIR :=
else
  export CONFIG_PROFILE_DIR := $(SCOPE_PROFILE)/
endif

# Validation

ifeq ($(filter $(TOKEN_MODE),managed unmanaged),)
$(error TOKEN_MODE must be 'managed' or 'unmanaged', got '$(TOKEN_MODE)')
endif

ifeq ($(filter $(DAEMON_MODE),direct daemons),)
$(error DAEMON_MODE must be 'direct' or 'daemons', got '$(DAEMON_MODE)')
endif

ifeq ($(filter $(RUNTIME),compose k8s),)
$(error RUNTIME must be 'compose' or 'k8s', got '$(RUNTIME)')
endif

# Runtime-specific execution wrappers

ifeq ($(RUNTIME),k8s)
EXEC_RUCIO := $(KUBECTL) exec deploy/rucio-client --
else
EXEC_RUCIO := docker exec compose-rucio-client-1
endif

# Help

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
	@echo '  SCOPE_PROFILE = $(SCOPE_PROFILE) (local | <profile>)'
	@echo ''
	@echo 'Usage:'
	@echo '  make <target> [RUNTIME=compose|k8s] [TOKEN_MODE=managed|unmanaged] [DAEMON_MODE=direct|daemons] [SCOPE_PROFILE=local|<profile, e.g. egi-dev, ls-aai-dev>] [SERVICES="svc1 svc2"]'
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
	SCOPE_PROFILE=$(SCOPE_PROFILE) \
	S3_ACCESS_KEY='$(S3_ACCESS_KEY)' \
	S3_SECRET_KEY='$(S3_SECRET_KEY)' \
	./shared/scripts/init-testbed.sh

## IdP token verification

.PHONY: verify-idp-token
verify-idp-token: ## Verify client_credentials/resource=/token-exchange for SCOPE_PROFILE (egi-dev|lsaai-dev). Requires OIDC_CLIENT_SECRET.
	@case "$(SCOPE_PROFILE)" in \
	  egi-dev) \
	    shared/scripts/verify-idp-token.sh \
	      --issuer https://aai-dev.egi.eu/auth/realms/egi \
	      --client-id 699e9e29-29e8-4220-8863-5306d8a7feb8 \
	      --scope "openid profile eduperson_entitlement offline_access read:/ write:/" ;; \
	  ls-aai-dev) \
	    shared/scripts/verify-idp-token.sh \
	      --issuer https://login.aai.lifescience-ri.eu/oidc/ \
	      --client-id 4ff05c0b-1d83-42b7-a00a-8bd162df4165 \
	      --scope "openid profile email offline_access eduperson_entitlement" ;; \
	  *) echo "Unknown SCOPE_PROFILE=$(SCOPE_PROFILE), expected egi-dev or ls-aai-dev"; exit 1 ;; \
	esac

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
	--set global.daemonMode=$(DAEMON_MODE) \
	--set global.scopeProfile=$(SCOPE_PROFILE) \
	$(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
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
	$(COMPOSE) logs --tail=100 $(SERVICES)
else
	@echo "k8s: use 'kubectl -n $(K8S_NAMESPACE) logs deploy/<name> -f'"
	@$(KUBECTL) get deploy -o name
endif

## GitOps

.PHONY: argocd-install
argocd-install: ## Install ArgoCD + bootstrap the chosen env (GITOPS_ENV=sandbox|staging|production, TOKEN_MODE=managed|unmanaged, SCOPE_PROFILE=local|<profile>)
	./shared/scripts/init-argocd.sh --env $(GITOPS_ENV) \
	    --flow $(TOKEN_MODE) --scope-profile $(SCOPE_PROFILE) \
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
	-for es in $$(kubectl get externalsecret -n $(K8S_NAMESPACE) -o name 2>/dev/null); do \
	  kubectl delete -n $(K8S_NAMESPACE) $$es --ignore-not-found; done
	# 4. Now the namespace can finalize. NOTE: vault-seed-once and
	#    rucio-bootstrap-db are imperative Jobs (shared/scripts/seed-vault.sh,
	#    run-bootstrap-db.sh) — not GitOps-managed, so nothing above prunes
	#    them, but they live in this namespace and are deleted with it here.
	kubectl delete namespace $(K8S_NAMESPACE) --ignore-not-found --timeout=360s
	# 5. Finally remove ESO and Argo.
	kubectl -n $(ARGOCD_NAMESPACE) delete application external-secrets --ignore-not-found
	kubectl delete namespace $(ARGOCD_NAMESPACE) --ignore-not-found
	@echo "GitOps $(GITOPS_ENV) and Argo CD removed"

.PHONY: flux-install
flux-install: ## Install Flux + bootstrap the chosen env (GITOPS_ENV=sandbox|staging|production, TOKEN_MODE=managed|unmanaged, SCOPE_PROFILE=local|<profile>)
	./shared/scripts/init-flux.sh --env $(GITOPS_ENV) \
	    --flow $(TOKEN_MODE) --scope-profile $(SCOPE_PROFILE) \
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
	-for es in $$(kubectl get externalsecret -n $(K8S_NAMESPACE) -o name 2>/dev/null); do \
	  kubectl delete -n $(K8S_NAMESPACE) $$es --ignore-not-found; done
	# 3. Now the workload namespace can finalize. NOTE: vault-seed-once and
	#    rucio-bootstrap-db are imperative Jobs (shared/scripts/seed-vault.sh,
	#    run-bootstrap-db.sh) — not GitOps-managed, so nothing above prunes
	#    them, but they live in this namespace and are deleted with it here.
	kubectl delete namespace $(K8S_NAMESPACE) --ignore-not-found --timeout=360s
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

test-rucio-transfers: ## Rucio E2E TPC transfer test
	$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_rucio_transfers.py -v"

.PHONY: test-copernicus-transfers
test-copernicus-transfers: ## Rucio E2E TPC transfer test with Copernicus Sentinel data (WebDAV + OIDC)
	$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) \
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

## Terraform

.PHONY: tf-fmt
tf-fmt: ## Check Terraform formatting across deploy/terraform
	terraform fmt -check -recursive -no-color deploy/terraform

.PHONY: tf-prepare-backend
tf-prepare-backend: ## Idempotently create/grant access to TF_ENV's GCS state bucket (requires GCP_PROJECT_ID)
	@[ -n "$(GCP_PROJECT_ID)" ] || { echo "GCP_PROJECT_ID is required"; exit 1; }
	if gcloud storage buckets describe "gs://$(TF_STATE_BUCKET)" --project="$(GCP_PROJECT_ID)" >/dev/null 2>&1; then \
	  echo "Bucket gs://$(TF_STATE_BUCKET) already exists — skipping create"; \
	else \
	  echo "Creating gs://$(TF_STATE_BUCKET)"; \
	  gcloud storage buckets create "gs://$(TF_STATE_BUCKET)" \
	    --project="$(GCP_PROJECT_ID)" --location=EU --uniform-bucket-level-access; \
	fi
	gcloud storage buckets add-iam-policy-binding "gs://$(TF_STATE_BUCKET)" \
	  --member="serviceAccount:dep-dlm-terraform-ci@$(GCP_PROJECT_ID).iam.gserviceaccount.com" \
	  --role="roles/storage.objectAdmin"

.PHONY: tf-init
tf-init: ## Init Terraform for TF_ENV (default staging) against its GCS state bucket
	$(TERRAFORM) init \
	  -backend-config="bucket=$(TF_STATE_BUCKET)" \
	  -backend-config="prefix=$(TF_STATE_PREFIX)"

.PHONY: tf-validate
tf-validate: ## Validate the TF_ENV config (run tf-init first)
	$(TERRAFORM) validate -no-color

.PHONY: tf-plan
tf-plan: ## Plan Terraform changes for TF_ENV, saved to $(TF_DIR)/tfplan
	TF_VAR_project_id=$(GCP_PROJECT_ID) TF_VAR_region=$(GCP_REGION) \
	  $(TERRAFORM) plan -no-color -out=tfplan

.PHONY: tf-apply
tf-apply: ## Apply TF_ENV — uses a saved tf-plan if present, otherwise plans inline. AUTO_APPROVE=1 for CI.
	@if [ -f $(TF_DIR)/tfplan ]; then \
	  $(TERRAFORM) apply -no-color $(TF_AUTO_APPROVE_FLAG) tfplan; \
	else \
	  TF_VAR_project_id=$(GCP_PROJECT_ID) TF_VAR_region=$(GCP_REGION) \
	    $(TERRAFORM) apply -no-color $(TF_AUTO_APPROVE_FLAG); \
	fi

.PHONY: tf-destroy
tf-destroy: ## Destroy TF_ENV's infrastructure. AUTO_APPROVE=1 for CI, interactive otherwise.
	TF_VAR_project_id=$(GCP_PROJECT_ID) TF_VAR_region=$(GCP_REGION) \
	  $(TERRAFORM) destroy -no-color $(TF_AUTO_APPROVE_FLAG)

.PHONY: tf-destroy-state-bucket
tf-destroy-state-bucket: ## Empty and delete TF_ENV's GCS state bucket — irreversible, run tf-destroy first
	@echo "Emptying and deleting gs://$(TF_STATE_BUCKET) — this cannot be undone."
	gcloud storage rm --recursive "gs://$(TF_STATE_BUCKET)/**" 2>/dev/null || echo "(bucket already empty)"
	gcloud storage buckets delete "gs://$(TF_STATE_BUCKET)"

.PHONY: tf-output
tf-output: ## Show Terraform outputs for TF_ENV
	$(TERRAFORM) output

.PHONY: tf-kubeconfig
tf-kubeconfig: ## Fetch kubectl credentials for TF_ENV's GKE cluster (gcloud + gke-gcloud-auth-plugin required)
	gcloud container clusters get-credentials $$($(TERRAFORM) output -raw cluster_name) \
	  --region=$(GCP_REGION) --project=$(GCP_PROJECT_ID)

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
