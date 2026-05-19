SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

RUNTIME ?= compose

# Anchor for compose bind-mounts. Override if running from an unusual shell.
export TESTBED_HOST_SOURCE ?= $(CURDIR)

COMPOSE_FILE := deploy/compose/docker-compose.yml
COMPOSE      := docker compose -f $(COMPOSE_FILE)

EXEC_RUCIO := docker exec compose-rucio-client-1
EXEC_FTS   := docker exec compose-fts-oidc-1

# ── Help ──────────────────────────────────────────────────────────────────
.PHONY: help
help: ## Show this help (default target)
	@awk 'BEGIN {FS = ":.*?## "} \
	    /^[a-zA-Z0-9_%-]+:.*?## / { printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2 } \
	    /^## / { sub(/^## /, ""); printf "\n\033[1m%s\033[0m\n", $$0 }' $(MAKEFILE_LIST)

## Setup

.PHONY: certs
certs: ## Generate certificates (e.g. CA, hosts)
	./shared/scripts/generate-certs.sh

## Stack lifecycle (compose-*)

.PHONY: compose-up
compose-up: ## Start the full stack in the background
	$(COMPOSE) up -d

.PHONY: compose-down
compose-down: ## Stop the stack and remove volumes
	$(COMPOSE) down -v

.PHONY: compose-restart
compose-restart: compose-down compose-up ## Tear down and restart the stack

.PHONY: compose-rebuild
compose-rebuild: ## Rebuild and restart one or more services: make compose-rebuild SERVICES="teapot fts"
	$(COMPOSE) build $(SERVICES)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICES)

.PHONY: compose-ps
compose-ps: ## List running containers
	$(COMPOSE) ps

.PHONY: compose-logs
compose-logs: ## Tail logs from all services (Ctrl-C to exit)
	$(COMPOSE) logs -f --tail=50

.PHONY: compose-logs-%
compose-logs-%: ## Tail logs from a single service, e.g. `make compose-logs-rucio`
	$(COMPOSE) logs -f --tail=100 $*

.PHONY: compose-build
compose-build: ## Build local Docker images (e.g. fts, teapot)
	$(COMPOSE) build

# .PHONY: bootstrap
# bootstrap: ## Bootstrap DEP DLM testbed
# 	./shared/scripts/bootstrap-testbed.sh

## Cleanup

.PHONY: clean
clean: ## Remove generated certs and volumes; keep CA (rucio_ca.pem + key)
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	find certs \
	! -name 'rucio_ca.pem' \
	! -name 'rucio_ca.key.pem' \
	\( -name '*.pem' -o -name '*.namespaces' -o -name '*.signing_policy' -o -name '*.csr' -o -name '*.r0' -o -name '*.0' \) \
	-delete 2>/dev/null || true
	@echo "Cleaned certs (preserved rucio_ca.pem and rucio_ca.key.pem) and volumes"
