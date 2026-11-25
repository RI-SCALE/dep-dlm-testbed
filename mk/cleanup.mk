# Cleanup: local artifacts and testbed data.
# Included from the Makefile after mk/config.mk.

## Cleanup

.PHONY: clear-artifacts
clear-artifacts: ## Remove certs, volumes, Terraform/Python/Helm artifacts
	$(COMPOSE_ALL) down -v --remove-orphans 2>/dev/null || true
	find certs -type f \
	    ! -path 'certs/public-roots/*' \
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
	@echo "Cleaned certs (preserved rucio_ca.pem, rucio_ca.key.pem, tls_ca_bundle.pem, public-roots/), compose volumes,"
	@echo ".terraform/tfplan/crash.log (preserved .terraform.lock.hcl), __pycache__/.pytest_cache, and Helm chart .tgz deps"
	@echo "(NOT touched: envs/*.env — this holds real configured credentials, not regenerable artifacts)"

.PHONY: cleanup
cleanup: ## Delete rules/replicas/distances (and RSEs unless KEEP_RSES=1) created by init/tests
	@$(TEST_OIDC_ENV) \
	RUNTIME=$(RUNTIME) \
	K8S_NAMESPACE=$(K8S_NAMESPACE) \
	./scripts/cleanup-testbed.sh
