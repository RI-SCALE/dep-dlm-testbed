# Setup: upstream patches, certificates, testbed init.
# Included from the Makefile after mk/config.mk.

RUCIO_REF    ?= 41.2.1
FTS_REST_REF ?= v3.14.0
TEAPOT_REF   ?= 0.23.0

RUCIO_URL    := https://github.com/rucio/rucio.git
FTS_REST_URL := https://gitlab.cern.ch/fts/fts-rest-flask.git
TEAPOT_URL   := https://github.com/interTwin-eu/teapot.git

## Setup

.PHONY: patches
patches: ## Regenerate diffs/ against pinned upstream refs
	./scripts/make-patches.sh rucio    $(RUCIO_URL)    $(RUCIO_REF)    patches/rucio.manifest    diffs/rucio
	./scripts/make-patches.sh fts-rest $(FTS_REST_URL) $(FTS_REST_REF) patches/fts-rest.manifest diffs/fts-rest
	./scripts/make-patches.sh teapot   $(TEAPOT_URL)   $(TEAPOT_REF)   patches/teapot.manifest   diffs/teapot

.PHONY: patches-check
patches-check: patches ## Fail if patched files changed without regenerating diffs
	@if [ -n "$$(git status --porcelain -- diffs/)" ]; then \
		git status --short -- diffs/; git diff -- diffs/; \
		echo "::error::diffs/ is stale — run 'make patches' and commit the result"; exit 1; \
	fi

.PHONY: certs
certs: ## Generate CA and host certificates
	./scripts/generate-certs.sh

.PHONY: init
init: ## Init testbed accounts, RSEs, OIDC seed
	@$(TEST_OIDC_ENV) \
	SCOPE_PROFILE=$(SCOPE_PROFILE) TOKEN_MODE=$(TOKEN_MODE) \
	RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) GITOPS_ENV=$(GITOPS_ENV) \
	RUCIO_DB_HOST='$(RUCIO_DB_HOST)' RUCIO_DB_PASSWORD='$(RUCIO_DB_PASSWORD)' \
	S3_ACCESS_KEY='$(S3_ACCESS_KEY)' \
	S3_SECRET_KEY='$(S3_SECRET_KEY)' \
	./scripts/init-testbed.sh
