# Shared settings: runtime/profile knobs, validation, OIDC per-profile
# derivation, and the exec wrappers. Included first by the Makefile.

# Anchor for compose bind-mounts. Override if running from an unusual shell.
export TESTBED_HOST_SOURCE ?= $(CURDIR)

RUNTIME    ?= compose
TOKEN_MODE ?= managed
SCOPE_PROFILE ?= local
DAEMON_MODE ?= direct
SERVICES   ?=

OBSERVABILITY ?= 0

COMPOSE_FILE  ?= deploy/compose/docker-compose.$(TOKEN_MODE).yml
COMPOSE_OBS_FILE := deploy/compose/docker-compose.observability.yml
COMPOSE_OBS   := $(if $(filter 1,$(OBSERVABILITY)),-f $(COMPOSE_OBS_FILE),)
COMPOSE       := docker compose -f $(COMPOSE_FILE) $(COMPOSE_OBS)
# Teardown targets every profile and the overlay, whatever flags start used.
COMPOSE_ALL   := docker compose --profile '*' -f $(COMPOSE_FILE) -f $(COMPOSE_OBS_FILE)

GITOPS_ENV ?= sandbox
K8S_NAMESPACE ?= dep-dlm-$(GITOPS_ENV)
KUBECTL       := kubectl -n $(K8S_NAMESPACE)

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

# $BROWSER is set inside the VS Code devcontainer and opens the page on the host.
OPEN_URL = $${BROWSER:-$$(command -v open || command -v xdg-open)}

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

# Token endpoint for external IdPs (used by tests, init and the reporter).
# Before TEST_OIDC_ENV, which expands it immediately.
ifeq ($(OIDC_TOKEN_URL),)
  ifeq ($(SCOPE_PROFILE),egi-dev)
    OIDC_TOKEN_URL := $(OIDC_ISSUER)/protocol/openid-connect/token
  else ifeq ($(SCOPE_PROFILE),ls-aai-dev)
    OIDC_TOKEN_URL := https://login.aai.lifescience-ri.eu/oidc/token
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

# Usage reporter's Rucio token for external IdPs (local: compose/chart
# defaults, Keycloak). EGI uses its dedicated M2M client; its secret only
# comes from the environment or CI (empty -> the reporter exits 1, never the
# Rucio client's secret). LS AAI reuses the Rucio client (ADR-008 addendum).
# resource gives the token Rucio's expected audience (EGI issues none
# otherwise). $(or) treats empty values (e.g. unset CI secrets) as unset.
ifneq ($(SCOPE_PROFILE),local)
  ifeq ($(SCOPE_PROFILE),egi-dev)
    REPORTER_RUCIO_CLIENT_ID := $(or $(REPORTER_RUCIO_CLIENT_ID),ba1fca56-245f-4f5c-968b-6c73485f5011)
    REPORTER_RUCIO_SCOPE     := $(or $(REPORTER_RUCIO_SCOPE),openid profile eduperson_entitlement read:/ write:/)
  else
    REPORTER_RUCIO_CLIENT_SECRET := $(or $(REPORTER_RUCIO_CLIENT_SECRET),$(OIDC_CLIENT_SECRET))
  endif
  REPORTER_RUCIO_TOKEN_URL := $(or $(REPORTER_RUCIO_TOKEN_URL),$(OIDC_TOKEN_URL))
  REPORTER_RUCIO_CLIENT_ID := $(or $(REPORTER_RUCIO_CLIENT_ID),$(OIDC_CLIENT_ID))
  REPORTER_RUCIO_SCOPE     := $(or $(REPORTER_RUCIO_SCOPE),$(OIDC_EXPECTED_SCOPE))
  REPORTER_RUCIO_RESOURCE  := $(or $(REPORTER_RUCIO_RESOURCE),https://fts.example.org/)
  export REPORTER_RUCIO_TOKEN_URL REPORTER_RUCIO_CLIENT_ID REPORTER_RUCIO_CLIENT_SECRET \
         REPORTER_RUCIO_SCOPE REPORTER_RUCIO_RESOURCE
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

# Named, lazily-evaluated Terraform outputs
RUCIO_PUBLIC_HOSTNAME       = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,rucio_public_hostname),)
FTS_PUBLIC_HOSTNAME         = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,fts_public_hostname),)
GATEWAY_STATIC_IP           = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,gateway_static_ip),)
VALIDATION_STORAGE_HOSTNAME = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,validation_storage_hostname),)
VALIDATION_STORAGE_IP       = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,validation_storage_ip),)
FTS_DATABASE_HOST = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,fts_database_private_ip),)
FTS_DB_PASSWORD    = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,fts_db_password),)
RUCIO_DB_HOST     = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,rucio_database_private_ip),)
RUCIO_DB_PASSWORD = $(if $(filter staging,$(GITOPS_ENV)),$(call staging_tf_output,rucio_db_password),)

ifeq ($(GITOPS_ENV),staging)
  override RUNTIME := k8s
  # No long-running rucio-client pod exists in a real Terraform-managed
  # environment (sandbox-only convenience container)
  EXEC_RUCIO = docker run --rm -i \
    --network host \
	--cap-add=SYS_ADMIN \
    --add-host $(RUCIO_PUBLIC_HOSTNAME):$(GATEWAY_STATIC_IP) \
    --add-host $(FTS_PUBLIC_HOSTNAME):$(GATEWAY_STATIC_IP) \
    --add-host $(VALIDATION_STORAGE_HOSTNAME):$(VALIDATION_STORAGE_IP) \
    -e REQUESTS_CA_BUNDLE=/etc/grid-security/certificates/tls_ca_bundle.pem \
    -e RUNTIME=k8s \
    -e K8S_NAMESPACE=$(K8S_NAMESPACE) \
	-e KUBECONFIG=/root/.kube/config \
    -e DAEMON_MODE=$(DAEMON_MODE) \
    -e TEAPOT1_URL=https://$(VALIDATION_STORAGE_HOSTNAME):8081 \
    -e TEAPOT2_URL=https://$(VALIDATION_STORAGE_HOSTNAME):8082 \
    -e GITOPS_ENV=$(GITOPS_ENV) \
    -e FTS_DATABASE_HOST=$(FTS_DATABASE_HOST) \
    -e FTS_DB_PASSWORD=$(FTS_DB_PASSWORD) \
    -v $(TESTBED_HOST_SOURCE)/certs/hostcert.pem:/etc/grid-security/hostcert.pem:ro \
    -v $(TESTBED_HOST_SOURCE)/certs/hostkey.pem:/etc/grid-security/hostkey.pem:ro \
    -v $(TESTBED_HOST_SOURCE)/certs/tls_ca_bundle.pem:/etc/grid-security/certificates/tls_ca_bundle.pem:ro \
    -v $(TESTBED_HOST_SOURCE)/certs/rucio_ca.pem:/etc/grid-security/certificates/rucio_ca.pem:ro \
	-v $(TESTBED_HOST_SOURCE)/certs/5fca1cb1.0:/etc/grid-security/certificates/5fca1cb1.0:ro \
    -v $(TESTBED_HOST_SOURCE)/userpass-client.cfg:/opt/rucio/etc/rucio.cfg:ro \
    -v $(TESTBED_HOST_SOURCE)/tests:/tests:ro \
	-v $(TESTBED_HOST_SOURCE)/.kube/config-$(TF_ENV):/root/.kube/config:ro \
    ghcr.io/ri-scale/dep-dlm-testbed/rucio-client:766076eba70ae540c42ab24fe0035c2a4f01328d

  EXEC_FTS := $(KUBECTL) exec -i deploy/fts --
else ifeq ($(RUNTIME),k8s)
  EXEC_RUCIO := $(KUBECTL) exec deploy/rucio-client --
  EXEC_FTS := $(KUBECTL) exec -i deploy/fts --
else
  EXEC_RUCIO := docker exec compose-rucio-client-1
  EXEC_FTS := docker exec -i compose-fts-1
endif

ifeq ($(filter $(OBSERVABILITY),0 1),)
$(error OBSERVABILITY must be '0' or '1', got '$(OBSERVABILITY)')
endif
