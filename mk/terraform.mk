# Terraform: TF_ENV roots, kubeconfig, Secret Manager syncs.
# Included from the Makefile after mk/config.mk.

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
	TF_VAR_token_mode="$(TOKEN_MODE)" \
	TF_VAR_scope_profile="$(SCOPE_PROFILE)"
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

## Terraform

.PHONY: tf-fmt
tf-fmt: ## Format Terraform files
	terraform fmt -recursive -no-color deploy/terraform

.PHONY: tf-fmt-check
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
				modules/database-mysql modules/secrets modules/validation-storage \
				modules/monitoring; do \
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
	CLUSTER_NAME=$$($(TERRAFORM) output -raw cluster_name); \
	CLUSTER_LOCATION=$$($(TERRAFORM) output -raw cluster_location); \
	gcloud container clusters get-credentials "$$CLUSTER_NAME" \
	  --location="$$CLUSTER_LOCATION" --project="$$GCP_PROJECT_ID"; \
	mkdir -p $(CURDIR)/.kube; \
	CLUSTER_ENDPOINT=$$(gcloud container clusters describe "$$CLUSTER_NAME" \
	  --location="$$CLUSTER_LOCATION" --project="$$GCP_PROJECT_ID" \
	  --format='value(endpoint)'); \
	CLUSTER_CA=$$(gcloud container clusters describe "$$CLUSTER_NAME" \
	  --location="$$CLUSTER_LOCATION" --project="$$GCP_PROJECT_ID" \
	  --format='value(masterAuth.clusterCaCertificate)'); \
	ACCESS_TOKEN=$$(gcloud auth print-access-token); \
	kubectl config --kubeconfig=$(CURDIR)/.kube/config-$(TF_ENV) set-cluster gke \
	  --server="https://$$CLUSTER_ENDPOINT" \
	  --certificate-authority=<(echo "$$CLUSTER_CA" | base64 -d) --embed-certs=true; \
	kubectl config --kubeconfig=$(CURDIR)/.kube/config-$(TF_ENV) set-credentials gke-token \
	  --token="$$ACCESS_TOKEN"; \
	kubectl config --kubeconfig=$(CURDIR)/.kube/config-$(TF_ENV) set-context gke \
	  --cluster=gke --user=gke-token --namespace=$(K8S_NAMESPACE); \
	kubectl config --kubeconfig=$(CURDIR)/.kube/config-$(TF_ENV) use-context gke

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

.PHONY: certs-sync
certs-sync: ## Fetch current certs from Secret Manager (matches what's deployed to TF_ENV)
	@$(TF_RESOLVE_ENV); \
	gcloud secrets versions access latest \
	  --secret="dep-dlm-$(TF_ENV)-certs" \
	  --project="$$GCP_PROJECT_ID" \
	| python3 -c "import sys,json,base64; d=json.load(sys.stdin); [open(f'certs/{k}','w').write(v) for k,v in d.items()]"

.PHONY: userpass-client-sync
userpass-client-sync: ## Fetch userpass-client.cfg from Secret Manager (matches what's deployed to TF_ENV)
	@$(TF_RESOLVE_ENV); \
	gcloud secrets versions access latest \
	  --secret="dep-dlm-$(TF_ENV)-secrets" \
	  --project="$$GCP_PROJECT_ID" \
	| python3 -c "import sys,json; d=json.load(sys.stdin); open('userpass-client.cfg','w').write(d['userpass-client.cfg'])"

.PHONY: oidc-client-sync
oidc-client-sync: ## Fetch oidc-client.cfg from Secret Manager into oidc-client.$(TF_ENV).cfg (interactive OIDC login against TF_ENV)
	@$(TF_RESOLVE_ENV); \
	gcloud secrets versions access latest \
	  --secret="dep-dlm-$(TF_ENV)-secrets" \
	  --project="$$GCP_PROJECT_ID" \
	| python3 -c "import sys,json; d=json.load(sys.stdin); open('oidc-client.$(TF_ENV).cfg','w').write(d['oidc-client.cfg'])"
	@echo "Wrote oidc-client.$(TF_ENV).cfg — use: RUCIO_CONFIG=oidc-client.$(TF_ENV).cfg rucio whoami"
