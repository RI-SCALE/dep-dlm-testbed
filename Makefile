SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Anchor for compose bind-mounts. Override if running from an unusual shell.
export TESTBED_HOST_SOURCE ?= $(CURDIR)

RUNTIME    ?= compose
TOKEN_MODE ?= managed
SCOPE_PROFILE ?= local
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
OIDC_TEAPOT_AUD_SCOPE ?=
OIDC_GRANT_TYPE       ?= password
OIDC_EXPECTED_SCOPE   ?=

# Terraform
#
# GCP_PROJECT_ID, GCP_REGION, TF_STATE_BUCKET, and the networking values
# (network_id/subnet_id/pods_range_name/services_range_name) are
# DELIBERATELY NOT declared here with defaults — they're resolved at
# recipe-time by deploy/terraform/scripts/resolve-tf-env.sh
TF_ENV          ?= staging
TF_DIR          := deploy/terraform/environments/$(TF_ENV)
TF_STATE_PREFIX ?= $(TF_ENV)
TERRAFORM       := terraform -chdir=$(TF_DIR)
TF_RESOLVE_ENV  := eval "$$(deploy/terraform/scripts/resolve-tf-env.sh $(TF_ENV))"

# Single source of truth for every TF_VAR_* passed to plan/apply/destroy/
# import — previously duplicated across all four targets, which is how
# userpass_password ended up present in three of them and silently
# missing from the fourth (tf-import) until CI's self-heal step hit it.
# Must be expanded inside the same shell invocation as $(TF_RESOLVE_ENV)
# (relies on its exported $$GCP_PROJECT_ID etc.), so always use as:
#   @$(TF_RESOLVE_ENV); \
#   $(TF_VARS) \
#     $(TERRAFORM) <verb> ...
define TF_VARS
TF_VAR_project_id="$$GCP_PROJECT_ID" \
	TF_VAR_region="$$GCP_REGION" \
	TF_VAR_network_id="$$TF_NETWORK_ID" \
	TF_VAR_subnet_id="$$TF_SUBNET_ID" \
	TF_VAR_pods_range_name="$$TF_PODS_RANGE_NAME" \
	TF_VAR_services_range_name="$$TF_SERVICES_RANGE_NAME" \
	TF_VAR_bootstrap_userpass_pwd="secret" \
	TF_VAR_userpass_password="secret" \
	TF_VAR_oidc_issuer="$(OIDC_ISSUER)" \
	TF_VAR_oidc_client_id="$(OIDC_CLIENT_ID)" \
	TF_VAR_oidc_client_secret="$(OIDC_CLIENT_SECRET)" \
	TF_VAR_oidc_expected_scope="$(OIDC_EXPECTED_SCOPE)" \
	TF_VAR_oidc_issuer_name="$(OIDC_ISSUER_NAME)" \
	TF_VAR_teapot_audiences='$(TEAPOT_AUDIENCES)' \
	TF_VAR_teapot_extra_subs='$(TEAPOT_EXTRA_SUBS)' \
	TF_VAR_token_mode="$(TOKEN_MODE)"
endef

# Optional -target for a partial/targeted apply -- e.g. reserving
# validation-storage's static IP before certs (which need that IP baked
# into their SAN) can be generated, ahead of the full apply. Empty by
# default, so ordinary `make tf-apply` behaves exactly as before.
TF_TARGET ?=
TF_TARGET_FLAG := $(if $(TF_TARGET),-target=$(TF_TARGET),)

AUTO_APPROVE ?=
ifeq ($(AUTO_APPROVE),1)
  TF_AUTO_APPROVE_FLAG := -auto-approve
else
  TF_AUTO_APPROVE_FLAG :=
endif

ifeq ($(OIDC_ISSUER),)
  ifeq ($(SCOPE_PROFILE),egi-dev)
    OIDC_ISSUER := https://aai-dev.egi.eu/auth/realms/egi
  else ifeq ($(SCOPE_PROFILE),ls-aai-dev)
    OIDC_ISSUER := https://login.aai.lifescience-ri.eu/oidc/
  endif
endif

ifeq ($(OIDC_CLIENT_ID),)
  ifeq ($(SCOPE_PROFILE),egi-dev)
    OIDC_CLIENT_ID := 699e9e29-29e8-4220-8863-5306d8a7feb8
  else ifeq ($(SCOPE_PROFILE),ls-aai-dev)
    OIDC_CLIENT_ID := 4ff05c0b-1d83-42b7-a00a-8bd162df4165
  endif
endif

ifeq ($(OIDC_EXPECTED_SCOPE),)
  ifeq ($(SCOPE_PROFILE),egi-dev)
    OIDC_EXPECTED_SCOPE := openid profile eduperson_entitlement offline_access read:/ write:/
  else ifeq ($(SCOPE_PROFILE),ls-aai-dev)
    OIDC_EXPECTED_SCOPE := openid profile eduperson_entitlement offline_access
  endif
endif

# Passed to module.validation_storage
ifeq ($(OIDC_ISSUER_NAME),)
  ifeq ($(SCOPE_PROFILE),egi-dev)
    OIDC_ISSUER_NAME := egi-checkin-dev
  else ifeq ($(SCOPE_PROFILE),ls-aai-dev)
    OIDC_ISSUER_NAME := lsaai-dev
  endif
endif

# LS AAI restricts Teapot tokens to these audiences; EGI/Keycloak don't use
# audience restriction here, hence empty for every other profile.
ifeq ($(TEAPOT_AUDIENCES),)
  ifeq ($(SCOPE_PROFILE),ls-aai-dev)
    TEAPOT_AUDIENCES := ["https://teapot1.example.org/","https://teapot2.example.org/"]
  else
    TEAPOT_AUDIENCES := []
  endif
endif

ifeq ($(TEAPOT_EXTRA_SUBS),)
  ifeq ($(SCOPE_PROFILE),egi-dev)
    TEAPOT_EXTRA_SUBS := ["0f842730-ebfb-4de6-bcbb-3a44aab5a467@egi.eu","aa886829a0a894933008498cfe62264d899422f55b408560a259311776f0e519@egi.eu"]
  else ifeq ($(SCOPE_PROFILE),ls-aai-dev)
    TEAPOT_EXTRA_SUBS := ["4ff05c0b-1d83-42b7-a00a-8bd162df4165","28f7bc3a2d32a4a722f6eb24f77f7fbe42eb6471@lifescience-ri.eu"]
  else
    TEAPOT_EXTRA_SUBS := []
  endif
endif

ifeq ($(SCOPE_PROFILE),local)
  TEST_OIDC_ENV :=
else
  TEST_OIDC_ENV := OIDC_ISSUER='$(OIDC_ISSUER)' OIDC_TOKEN_URL='$(OIDC_TOKEN_URL)' \
    OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' \
    OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' OIDC_GRANT_TYPE='$(OIDC_GRANT_TYPE)' \
    OIDC_EXPECTED_SCOPE='$(OIDC_EXPECTED_SCOPE)' OIDC_TEAPOT_AUD_SCOPE=''
endif

ifeq ($(SCOPE_PROFILE),local)
  export CONFIG_PROFILE_DIR :=
else
  export CONFIG_PROFILE_DIR := $(SCOPE_PROFILE)/
endif

ifeq ($(origin TOKEN_MODE),file)
  ifeq ($(SCOPE_PROFILE),egi-dev)
    TOKEN_MODE := unmanaged
  endif
endif

define tf_require_oidc
	@[ -n "$(OIDC_ISSUER)" ] && [ -n "$(OIDC_CLIENT_ID)" ] || \
	  { echo "ERROR: OIDC_ISSUER/OIDC_CLIENT_ID couldn't be derived from SCOPE_PROFILE='$(SCOPE_PROFILE)'."; \
	    echo "  make $@ SCOPE_PROFILE=egi-dev|ls-aai-dev OIDC_CLIENT_SECRET=..."; \
	    echo "  or set OIDC_ISSUER/OIDC_CLIENT_ID explicitly for a profile not in the Makefile yet."; \
	    exit 1; }
	@[ -n "$(OIDC_CLIENT_SECRET)" ] || \
	  { echo "ERROR: OIDC_CLIENT_SECRET must be set explicitly — no safe default exists."; \
	    exit 1; }
endef

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

# Terraform outputs needed to wire DNS + Teapot ports for the ephemeral
# staging container. $(shell ...) only actually runs when a variable that
# uses this macro is expanded (i.e. inside a staging test recipe), not on
# every `make` invocation — but it does still require tf-init/tf-apply to
# have already populated state, same precondition test-rucio-transfers
# always had for GITOPS_ENV=staging.
define staging_tf_output
$(shell terraform -chdir=$(TF_DIR) output -raw $(1) 2>/dev/null)
endef

export TESTBED_HOST_HOME ?= $(HOME)

ifeq ($(GITOPS_ENV),staging)
  override RUNTIME := k8s
  # No long-running rucio-client pod exists in a real Terraform-managed
  # environment (sandbox-only convenience container)
  EXEC_RUCIO = docker run --rm -i \
    --network host \
    --add-host $(call staging_tf_output,rucio_public_hostname):$(call staging_tf_output,gateway_static_ip) \
    --add-host $(call staging_tf_output,fts_public_hostname):$(call staging_tf_output,gateway_static_ip) \
    --add-host $(call staging_tf_output,validation_storage_hostname):$(call staging_tf_output,validation_storage_ip) \
    -e REQUESTS_CA_BUNDLE=/etc/grid-security/certificates/tls_ca_bundle.pem \
    -e RUNTIME=k8s \
    -e K8S_NAMESPACE=$(K8S_NAMESPACE) \
    -e DAEMON_MODE=$(DAEMON_MODE) \
    -e TEAPOT1_URL=https://$(call staging_tf_output,validation_storage_ip):8081 \
    -e TEAPOT2_URL=https://$(call staging_tf_output,validation_storage_ip):8082 \
    -v $(TESTBED_HOST_SOURCE)/certs/hostcert.pem:/etc/grid-security/hostcert.pem:ro \
    -v $(TESTBED_HOST_SOURCE)/certs/hostkey.pem:/etc/grid-security/hostkey.pem:ro \
    -v $(TESTBED_HOST_SOURCE)/certs/tls_ca_bundle.pem:/etc/grid-security/certificates/tls_ca_bundle.pem:ro \
    -v $(TESTBED_HOST_SOURCE)/certs/rucio_ca.pem:/etc/grid-security/certificates/rucio_ca.pem:ro \
    -v $(TESTBED_HOST_SOURCE)/userpass-client.cfg:/opt/rucio/etc/rucio.cfg:ro \
    -v $(TESTBED_HOST_SOURCE)/shared/tests:/tests:ro \
    mgajekcern/rucio-client-docker-kubectl:latest
  # Prefixed into each test recipe's bash -c string below (empty for
  # sandbox, where the compose/helm rucio-client image already has
  # pytest baked in). boto3 deliberately skipped — not needed by
  # test_rucio_transfers.py; add it back here if test-copernicus-transfers
  # is run this way too.
  STAGING_PIP_INSTALL := pip install --no-cache-dir --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org pytest >/dev/null 2>&1 &&
else ifeq ($(RUNTIME),k8s)
  EXEC_RUCIO := $(KUBECTL) exec deploy/rucio-client --
else
  EXEC_RUCIO := docker exec compose-rucio-client-1
endif

## Help

.PHONY: help
help: ## Show this help
	@echo ''
	@echo 'dep-dlm-testbed'
	@echo ''
	@echo '  RUNTIME    = $(RUNTIME)    (compose | k8s)'
	@echo '  TOKEN_MODE = $(TOKEN_MODE) (managed | unmanaged)'
	@echo '  DAEMON_MODE = $(DAEMON_MODE) (direct | daemons)'
	@echo '  GITOPS_ENV = $(GITOPS_ENV) (sandbox | staging | production)'
	@echo '  K8S_NAMESPACE = $(K8S_NAMESPACE)'
	@echo '  SCOPE_PROFILE = $(SCOPE_PROFILE) (local | <profile>)'
	@echo '  TF_ENV = $(TF_ENV)'
	@echo ''
	@echo 'Usage:'
	@echo '  make <target> [RUNTIME=compose|k8s] [TOKEN_MODE=managed|unmanaged] [DAEMON_MODE=direct|daemons] [SCOPE_PROFILE=local|<profile, e.g. egi-dev, ls-aai-dev>] [SERVICES="svc1 svc2"]'
	@echo ''
	@awk 'BEGIN {FS = ":.*?## "} \
	    /^[a-zA-Z0-9_%-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	    /^## / { sub(/^## /, ""); printf "\n\033[1m%s\033[0m\n", $$0 }' $(MAKEFILE_LIST)

## Setup

.PHONY: certs
certs: ## Generate CA and host certificates
	./shared/scripts/generate-certs.sh

.PHONY: init
init: ## Init testbed accounts, RSEs, OIDC seed
	$(TEST_OIDC_ENV) \
	SCOPE_PROFILE=$(SCOPE_PROFILE) \
	S3_ACCESS_KEY='$(S3_ACCESS_KEY)' \
	S3_SECRET_KEY='$(S3_SECRET_KEY)' \
	./shared/scripts/init-testbed.sh

.PHONY: cleanup
cleanup: ## Delete rules/replicas/distances (and RSEs unless KEEP_RSES=1) created by init/tests
	$(TEST_OIDC_ENV) \
	RUNTIME=$(RUNTIME) \
	K8S_NAMESPACE=$(K8S_NAMESPACE) \
	./shared/scripts/cleanup-testbed.sh

## IdP token verification

.PHONY: verify-idp-token
verify-idp-token: ## Verify OIDC token flow for SCOPE_PROFILE. Needs OIDC_CLIENT_SECRET.
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
stop: ## Stop the stack, remove volumes / PVCs
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
rebuild: ## Rebuild services (SERVICES="fts teapot")
ifeq ($(RUNTIME),compose)
	$(COMPOSE) build  $(SERVICES)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICES)
else
	$(HELM) upgrade $(HELM_RELEASE) $(HELM_CHART) -n $(K8S_NAMESPACE)
endif

.PHONY: rebuild-clean
rebuild-clean: ## Rebuild from scratch, no cache
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
logs: ## Tail logs (SERVICES="..." for a subset)
ifeq ($(RUNTIME),compose)
	$(COMPOSE) logs --tail=100 $(SERVICES)
else
	@echo "k8s: use 'kubectl -n $(K8S_NAMESPACE) logs deploy/<name> -f'"
	@$(KUBECTL) get deploy -o name
endif

## GitOps

.PHONY: argocd-install
argocd-install: ## Install ArgoCD, bootstrap GITOPS_ENV
	OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' \
	./shared/scripts/init-argocd.sh --env $(GITOPS_ENV) \
	    --flow $(TOKEN_MODE) --scope-profile $(SCOPE_PROFILE) \
	    $(if $(GITOPS_REPO_URL),--repo-url $(GITOPS_REPO_URL)) \
	    $(if $(GITOPS_REVISION),--revision $(GITOPS_REVISION))

.PHONY: argocd-uninstall
argocd-uninstall: ## Remove ArgoCD apps and resources
	# 1. Delete the app-of-apps roots first (stops selfHeal recreating).
	kubectl -n $(ARGOCD_NAMESPACE) delete application dep-dlm-$(GITOPS_ENV)-apps dep-dlm-$(GITOPS_ENV)-secrets --ignore-not-found --wait=false
	# 2. Delete component apps but KEEP external-secrets so it can clear finalizers.
	kubectl -n $(ARGOCD_NAMESPACE) delete applications -l '!keep' --field-selector metadata.name!=external-secrets --ignore-not-found --wait=false || \
	  kubectl -n $(ARGOCD_NAMESPACE) delete application vault ruciodb rucio-server rucio-daemons rucio-bootstrap keycloak xrootd teapot fts --ignore-not-found --wait=false
	# 3. Clear ESO-managed resources while ESO is still alive.
	-kubectl delete clustersecretstore dep-dlm-secrets --ignore-not-found
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
flux-install: ## Install Flux, bootstrap GITOPS_ENV
	OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' \
	./shared/scripts/init-flux.sh --env $(GITOPS_ENV) \
	    --flow $(TOKEN_MODE) --scope-profile $(SCOPE_PROFILE) \
	    $(if $(GITOPS_REPO_URL),--repo-url $(GITOPS_REPO_URL)) \
	    $(if $(GITOPS_REVISION),--revision $(GITOPS_REVISION))

.PHONY: flux-uninstall
flux-uninstall: ## Remove Flux Kustomizations and controllers
	# 1. Suspend + delete the entrypoint Kustomizations (stops Flux re-reconciling).
	#    Reverse order: components -> secrets -> eso.
	kubectl -n $(FLUX_NAMESPACE) delete kustomization dep-dlm-$(GITOPS_ENV) --ignore-not-found --wait=false
	kubectl -n $(FLUX_NAMESPACE) delete kustomization dep-dlm-$(GITOPS_ENV)-secrets --ignore-not-found --wait=false
	# 2. Clear ESO-managed resources WHILE ESO is still alive (avoids finalizer deadlock).
	-kubectl delete clustersecretstore dep-dlm-secrets --ignore-not-found
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

test-rucio-transfers: ## Rucio E2E transfer test
	$(EXEC_RUCIO) bash -c "$(STAGING_PIP_INSTALL) $(TEST_OIDC_ENV) DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_rucio_transfers.py -v"

.PHONY: test-copernicus-transfers
test-copernicus-transfers: ## Rucio E2E transfer test with Copernicus data
	$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) \
		S3_ACCESS_KEY='$(S3_ACCESS_KEY)' \
		S3_SECRET_KEY='$(S3_SECRET_KEY)' \
		DAEMON_MODE=$(DAEMON_MODE) \
		RUNTIME=$(RUNTIME) \
		K8S_NAMESPACE=$(K8S_NAMESPACE) \
		$(STAGING_PIP_INSTALL) \
		pytest /tests/test_rucio_transfers_with_copernicus.py -v"

.PHONY: test-rucio-deletion
test-rucio-deletion: ## Rucio E2E deletion test
	$(EXEC_RUCIO) bash -c "$(STAGING_PIP_INSTALL) DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_rucio_deletion.py -v"

.PHONY: probe-teapot
probe-teapot: ## Teapot WebDAV probe with OIDC tokens
	$(EXEC_RUCIO) bash -c "DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) python3 /tests/probe_teapot_auth.py -v"

## Terraform

tf-fmt: ## Format Terraform files
	terraform fmt -recursive -no-color deploy/terraform

tf-fmt-check: ## Check Terraform formatting
	terraform fmt -check -recursive -no-color deploy/terraform

.PHONY: tf-init
tf-init: ## Init Terraform for TF_ENV (bucket resolved from bootstrap output)
	@$(TF_RESOLVE_ENV); \
	$(TERRAFORM) init \
	  -backend-config="bucket=$$TF_STATE_BUCKET" \
	  -backend-config="prefix=$(TF_STATE_PREFIX)"

.PHONY: tf-validate
tf-validate: ## Validate TF_ENV config (run tf-init first)
	$(TERRAFORM) validate -no-color

.PHONY: tf-lint
tf-lint: ## Lint every Terraform root module
	@command -v tflint >/dev/null 2>&1 || { echo "tflint not found — check .devcontainer/devcontainer.json's terraform Feature has tflint pinned, not 'none', then rebuild the container"; exit 1; }
	@for dir in deploy/terraform/bootstrap deploy/terraform/environments/staging deploy/terraform/environments/production; do \
	  echo "Linting $$dir"; \
	  ( cd "$$dir" && tflint --init >/dev/null 2>&1; tflint --config="$(CURDIR)/.tflint.hcl" ) || exit 1; \
	done

.PHONY: tf-docs
tf-docs: ## Generate Terraform reference docs. Needs terraform-docs.
	@command -v terraform-docs >/dev/null 2>&1 || { echo "terraform-docs not found — see .devcontainer/setup.sh's install_terraform_docs()"; exit 1; }
	@for dir in bootstrap environments/staging environments/production \
	            modules/networking modules/kubernetes modules/database-postgres \
				modules/database-mysql modules/secrets modules/validation-storage; do \
	  echo "Injecting docs into deploy/terraform/$$dir/README.md"; \
	  terraform-docs markdown table --sort-by required \
	    --output-file README.md --output-mode inject \
	    "deploy/terraform/$$dir"; \
	done
	@echo "Terraform reference docs injected into each module/root's own README.md"

.PHONY: tf-plan
tf-plan: ## Plan Terraform changes for TF_ENV
	$(call tf_require_oidc)
	@$(TF_RESOLVE_ENV); \
	$(TF_VARS) \
	  $(TERRAFORM) plan -no-color -out=tfplan

.PHONY: tf-apply
tf-apply: ## Apply TF_ENV. Uses saved plan if present. AUTO_APPROVE=1 for CI.
	$(call tf_require_oidc)
	@if [ -z "$(TF_TARGET)" ] && [ -f $(TF_DIR)/tfplan ]; then \
	  $(TERRAFORM) apply -no-color $(TF_AUTO_APPROVE_FLAG) tfplan; \
	else \
	  $(TF_RESOLVE_ENV); \
	  $(TF_VARS) \
	    $(TERRAFORM) apply -no-color $(TF_AUTO_APPROVE_FLAG) $(TF_TARGET_FLAG); \
	fi

.PHONY: tf-destroy
tf-destroy: ## Destroy TF_ENV (GKE, Cloud SQL, Secret Manager, not networking). AUTO_APPROVE=1 for CI.
	$(call tf_require_oidc)
	@$(TF_RESOLVE_ENV); \
	$(TF_VARS) \
	  $(TERRAFORM) destroy -no-color $(TF_AUTO_APPROVE_FLAG)

.PHONY: tf-output
tf-output: ## Show Terraform outputs for TF_ENV
	$(TERRAFORM) output

.PHONY: tf-kubeconfig
tf-kubeconfig: ## Fetch kubectl credentials for TF_ENV's cluster
	@$(TF_RESOLVE_ENV); \
	gcloud container clusters get-credentials $$($(TERRAFORM) output -raw cluster_name) \
	  --region="$$GCP_REGION" --project="$$GCP_PROJECT_ID"

.PHONY: tf-smoke-test
tf-smoke-test: ## Run smoke tests against TF_ENV. Run tf-kubeconfig first.
	TF_ENV=$(TF_ENV) pytest deploy/terraform/tests/test_deployed_infra.py -v

.PHONY: tf-import
tf-import: ## Import an existing GCP resource into TF_ENV's state. Usage: make tf-import RESOURCE=module.rucio_database.google_sql_database_instance.this ID=dep-dlm-staging-e52e0d90/dep-dlm-staging-pg
	$(call tf_require_oidc)
	@[ -n "$(RESOURCE)" ] && [ -n "$(ID)" ] || \
	  { echo "ERROR: usage: make tf-import RESOURCE=<terraform address> ID=<cloud resource id>"; exit 1; }
	@$(TF_RESOLVE_ENV); \
	$(TF_VARS) \
	  $(TERRAFORM) import -no-color "$(RESOURCE)" "$(ID)"

.PHONY: tf-force-unlock
tf-force-unlock: ## Force-unlock TF_ENV's state after a stale/abandoned lock. Usage: make tf-force-unlock LOCK_ID=<id from the lock error>. Confirm nothing else is actually running against TF_ENV first — see the Lock Info 'Who' field.
	@[ -n "$(LOCK_ID)" ] || \
	  { echo "ERROR: usage: make tf-force-unlock LOCK_ID=<lock id from the error message>"; exit 1; }
	$(TERRAFORM) force-unlock $(if $(filter 1,$(AUTO_APPROVE)),-force) $(LOCK_ID)

## Cleanup

.PHONY: clean
clean: ## Remove certs, volumes, Terraform/Python/Helm artifacts
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	find certs \
	    ! -name 'rucio_ca.pem' \
	    ! -name 'rucio_ca.key.pem' \
	    ! -name 'tls_ca_bundle.pem' \
	    \( -name '*.pem' -o -name '*.key' -o -name '*.namespaces' -o -name '*.signing_policy' \
	     -o -name '*.csr' -o -name '*.srl' -o -name '*.r0' -o -name '*.0' \) \
	    -delete 2>/dev/null || true
	@for dir in deploy/terraform/bootstrap deploy/terraform/environments/staging deploy/terraform/environments/production; do \
	  rm -rf "$$dir/.terraform" "$$dir/tfplan" "$$dir"/crash.log; \
	done
	@find . -type d \( -name '__pycache__' -o -name '.pytest_cache' \) -exec rm -rf {} + 2>/dev/null || true
	@find deploy/helm-charts -type f -name '*.tgz' -delete 2>/dev/null || true
	@echo "Cleaned certs (preserved rucio_ca.pem, rucio_ca.key.pem, tls_ca_bundle.pem), compose volumes,"
	@echo ".terraform/tfplan/crash.log (preserved .terraform.lock.hcl), __pycache__/.pytest_cache, and Helm chart .tgz deps"
	@echo "(NOT touched: envs/*.env — this holds real configured credentials, not regenerable artifacts)"
