# Tests: E2E suites, probes, usage reporter, CI timings.
# Included from the Makefile after mk/config.mk.

# Job from the CronJob's template, plus REPORTER_DAY=today and, for external
# IdPs, the profile's REPORTER_RUCIO_* (env overrides the chart's ConfigMap).
REPORTER_JOB_PY := import sys, os, json, datetime; cj = json.load(sys.stdin); \
  job = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": sys.argv[1]}, "spec": cj["spec"]["jobTemplate"]["spec"]}; \
  env = job["spec"]["template"]["spec"]["containers"][0].setdefault("env", []); \
  env.append({"name": "REPORTER_DAY", "value": datetime.datetime.utcnow().date().isoformat()}); \
  env.extend({"name": k, "value": os.environ[k]} for k in ("REPORTER_RUCIO_TOKEN_URL", "REPORTER_RUCIO_CLIENT_ID", "REPORTER_RUCIO_SCOPE", "REPORTER_RUCIO_RESOURCE") if os.environ.get(k)); \
  print(json.dumps(job))
REPORTER_CHECK_PY := import sys, json; r = [json.loads(l) for l in sys.stdin if l.startswith("{")]; \
  assert any(x["group_id"] == "suc1" and x["value"] > 0 for x in r), "no suc1 usage"; print("✓ suc1 reported")

## Tests

.PHONY: test-rucio-transfers
test-rucio-transfers: ## Rucio E2E transfer test
	@$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_rucio_transfers.py -v"

.PHONY: test-public-ri-transfers
test-public-ri-transfers: ## Rucio E2E copies from public RI holdings (ENES, EBI) into testbed storage
	@$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_rucio_public_ri.py -v"

.PHONY: test-copernicus-transfers
test-copernicus-transfers: ## Rucio E2E transfer test with Copernicus data
	@$(EXEC_RUCIO) bash -c "export $(TEST_OIDC_ENV) \
		S3_ACCESS_KEY='$(S3_ACCESS_KEY)' \
		S3_SECRET_KEY='$(S3_SECRET_KEY)' \
		DAEMON_MODE=$(DAEMON_MODE) \
		RUNTIME=$(RUNTIME) \
		K8S_NAMESPACE=$(K8S_NAMESPACE); \
		pytest /tests/test_rucio_transfers_with_copernicus.py -v"

.PHONY: test-rucio-deletion
test-rucio-deletion: ## Rucio E2E deletion test
	@$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_rucio_deletion.py -v"

.PHONY: probe-teapot
probe-teapot: ## Teapot WebDAV probe with OIDC tokens
	@$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) VALIDATION_STORAGE_HOST=$(VALIDATION_STORAGE_HOSTNAME) pytest /tests/probe_teapot.py -v"

.PHONY: probe-xrootd
probe-xrootd: ## XRootD probe with SciTokens
	@$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) VALIDATION_STORAGE_HOST=$(VALIDATION_STORAGE_HOSTNAME) pytest /tests/probe_xrootd.py -v"

.PHONY: probe-fts-teapot
probe-fts-teapot: ## Minimal FTS-only TPC repro (teapot1->teapot2), bypasses Rucio/conveyor
	@$(EXEC_FTS) env \
	  OIDC_ISSUER='$(OIDC_ISSUER)' OIDC_TOKEN_URL='$(OIDC_TOKEN_URL)' \
	  OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' \
	  OIDC_EXPECTED_SCOPE='$(OIDC_EXPECTED_SCOPE)' \
	  VALIDATION_STORAGE_HOST=$(VALIDATION_STORAGE_HOSTNAME) \
	  python3 - < tests/probe_fts_teapot.py

.PHONY: probe-fts-xrootd
probe-fts-xrootd: ## Minimal FTS-only TPC repro (xrd3->xrd4), bypasses Rucio/conveyor
	@$(EXEC_FTS) env \
	  OIDC_ISSUER='$(OIDC_ISSUER)' OIDC_TOKEN_URL='$(OIDC_TOKEN_URL)' \
	  OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' \
	  OIDC_EXPECTED_SCOPE='$(OIDC_EXPECTED_SCOPE)' \
	  VALIDATION_STORAGE_HOST=$(VALIDATION_STORAGE_HOSTNAME) \
	  python3 - < tests/probe_fts_xrootd.py

.PHONY: test-authz-personas
test-authz-personas: ## Authz entitlement-tier test across DEP persona accounts
	@$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_authz_personas.py -v"

.PHONY: test-authz-user
test-authz-user: ## Authz tier from userinfo entitlements for a real user token. Needs BEARER_TOKEN (from `rucio whoami`, valid ~1 h).
	@[ -n "$(BEARER_TOKEN)" ] || { echo "ERROR: BEARER_TOKEN must be set — log in with 'rucio whoami' first"; exit 1; }
	@$(EXEC_RUCIO) bash -c "USER_TOKEN='$(BEARER_TOKEN)' RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_authz_user.py -v"

.PHONY: test-usage-reporter
test-usage-reporter: ## Usage reporter dry-run: today's transfers report suc1 > 0
ifeq ($(RUNTIME),compose)
	@rc=0; out=$$($(COMPOSE) --profile usage-reporter run --rm --no-deps -T \
	    -e REPORTER_DAY=$$(date -u +%F) usage-reporter) || rc=$$?; \
	echo "$$out"; \
	case $$rc in 0|2) ;; *) echo "✗ reporter exit code $$rc"; exit 1;; esac; \
	echo "$$out" | python3 -c '$(REPORTER_CHECK_PY)'
else
	@job=usage-reporter-test-$$(date +%s); \
	$(KUBECTL) get cronjob usage-reporter -o json | python3 -c '$(REPORTER_JOB_PY)' $$job | $(KUBECTL) create -f - >/dev/null; \
	trap "$(KUBECTL) delete job $$job --ignore-not-found >/dev/null" EXIT; \
	for i in $$(seq 60); do \
	  phase=$$($(KUBECTL) get pods -l job-name=$$job -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true); \
	  case "$$phase" in Succeeded|Failed) break;; esac; sleep 3; \
	done; \
	out=$$($(KUBECTL) logs job/$$job); echo "$$out"; \
	rc=$$($(KUBECTL) get pods -l job-name=$$job -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}'); \
	case $$rc in 0|2) ;; *) echo "✗ reporter exit code $$rc"; exit 1;; esac; \
	echo "$$out" | python3 -c '$(REPORTER_CHECK_PY)'
endif

## CI

.PHONY: ci-durations
ci-durations: ## Compare CI step durations, latest successful runs: BRANCH (current) vs main. WORKFLOW=local.yml. Needs gh.
	@./scripts/ci-durations.sh $(or $(WORKFLOW),local.yml) $(BRANCH)
