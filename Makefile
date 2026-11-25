SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# config.mk first: the other files' ifeq/:= read its variables at parse time.
include mk/config.mk

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
	@echo '  OBSERVABILITY = $(OBSERVABILITY) (0 | 1)'
	@echo ''
	@echo 'Usage:'
	@echo '  make <target> [RUNTIME=compose|k8s] [TOKEN_MODE=managed|unmanaged] [DAEMON_MODE=direct|daemons] [SCOPE_PROFILE=local|<profile, e.g. egi-dev, ls-aai-dev>] [SERVICES="svc1 svc2"] [OBSERVABILITY=0|1]'
	@echo ''
	@awk 'BEGIN {FS = ":.*?## "} \
	    /^[a-zA-Z0-9_%-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	    /^## / { sub(/^## /, ""); printf "\n\033[1m%s\033[0m\n", $$0 }' $(MAKEFILE_LIST)

include mk/setup.mk
include mk/authz.mk
include mk/lifecycle.mk
include mk/gitops.mk
include mk/observability.mk
include mk/tests.mk
include mk/terraform.mk
include mk/cleanup.mk
