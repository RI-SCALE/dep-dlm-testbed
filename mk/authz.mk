# AuthN/AuthZ: IdP tokens, OPA policies, ODRL, Rego.
# Included from the Makefile after mk/config.mk.

# WP4 ODRL policy repository — read-only client (client_credentials, policies:read)
ODRL_CLIENT_ID     ?= 39b16c41-267f-46a8-984d-6adea53a7f0b
ODRL_CLIENT_SECRET ?=

# opa-ri-scale ODRL evaluator, vendored into configs/opa/vendor/ (see VENDORED.md)
OPA_RI_SCALE_REPO ?= https://github.com/mgajek-cern/opa-ri-scale.git
OPA_RI_SCALE_REF  ?= vendor-2026-10-08

## AuthN / AuthZ

.PHONY: verify-idp-token
verify-idp-token: ## Verify OIDC token flow for SCOPE_PROFILE. Needs OIDC_CLIENT_SECRET.
	@case "$(SCOPE_PROFILE)" in \
	  egi-dev) \
	    scripts/verify-idp-token.sh \
	      --issuer https://aai-dev.egi.eu/auth/realms/egi \
	      --client-id 699e9e29-29e8-4220-8863-5306d8a7feb8 \
	      --scope "openid profile eduperson_entitlement offline_access read:/ write:/" ;; \
	  ls-aai-dev) \
	    scripts/verify-idp-token.sh \
	      --issuer https://login.aai.lifescience-ri.eu/oidc/ \
	      --client-id 4ff05c0b-1d83-42b7-a00a-8bd162df4165 \
	      --scope "openid profile email offline_access eduperson_entitlement" ;; \
	  *) echo "Unknown SCOPE_PROFILE=$(SCOPE_PROFILE), expected egi-dev or ls-aai-dev"; exit 1 ;; \
	esac

.PHONY: check-claims
check-claims: ## Decode entitlements/acr claims for every realm user (or USER=<name>)
ifeq ($(RUNTIME),compose)
	python3 scripts/check_user_claims.py --keycloak-url http://localhost:8080 $(if $(USER),--user $(USER))
else
	@$(KUBECTL) port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap "kill $$PF_PID 2>/dev/null" EXIT; \
	sleep 2; \
	python3 scripts/check_user_claims.py --keycloak-url http://localhost:18080 $(if $(USER),--user $(USER))
endif

.PHONY: ingest-policies
ingest-policies: ## Push authz.rego and data (incl. ODRL policies) into the running OPA (idempotent)
ifeq ($(RUNTIME),compose)
	python3 scripts/ingest_policies.py --opa-url http://localhost:8181 --opa-dir configs/opa
else
	@$(KUBECTL) port-forward svc/opa 18181:8181 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap "kill $$PF_PID 2>/dev/null" EXIT; \
	sleep 2; \
	python3 scripts/ingest_policies.py --opa-url http://localhost:18181 --opa-dir configs/opa
endif

.PHONY: fetch-odrl-policies
fetch-odrl-policies: ## Print the DEP ODRL policies from the WP4 policy repository. Needs ODRL_CLIENT_SECRET.
	@[ -n "$(ODRL_CLIENT_SECRET)" ] || \
	  { echo "ERROR: ODRL_CLIENT_SECRET must be set (EGI Check-in dev client with policies:read)"; exit 1; }
	@ODRL_CLIENT_ID='$(ODRL_CLIENT_ID)' ODRL_CLIENT_SECRET='$(ODRL_CLIENT_SECRET)' \
	  ./scripts/fetch-odrl-policies.sh

.PHONY: vendor-opa-ri-scale
vendor-opa-ri-scale: ## Re-vendor the opa-ri-scale ODRL evaluator at OPA_RI_SCALE_REF
	rm -rf /tmp/ors configs/opa/vendor/opa-ri-scale/dep
	git clone -q --depth 1 --branch $(OPA_RI_SCALE_REF) $(OPA_RI_SCALE_REPO) /tmp/ors
	mkdir -p configs/opa/vendor/opa-ri-scale
	cp -r /tmp/ors/OPA/src/dep configs/opa/vendor/opa-ri-scale/dep
	rm -f configs/opa/vendor/opa-ri-scale/dep/data.yaml configs/opa/vendor/opa-ri-scale/dep/demo.yaml
	opa test configs/opa -v

## Rego

.PHONY: test-rego
test-rego: ## Rego unit tests (all phases, no stack needed)
	@command -v opa >/dev/null || { echo "opa not on PATH — see https://www.openpolicyagent.org/docs#1-download-opa"; exit 1; }
	opa test configs/opa -v

.PHONY: fmt-rego
fmt-rego: ## Format all Rego files in place (fixes the opa-fmt pre-commit hook)
	@command -v opa >/dev/null || { echo "opa not on PATH — see https://www.openpolicyagent.org/docs#1-download-opa"; exit 1; }
	opa fmt -w $$(find configs/opa -name '*.rego' -not -path '*/vendor/*')
	opa check --strict configs/opa
