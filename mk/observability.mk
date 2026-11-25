# Observability: endpoints, smoke test, UIs, dashboards.
# Included from the Makefile after mk/config.mk.

ifeq ($(RUNTIME),compose)
  PROMETHEUS_URL ?= http://prometheus:9090
  LOKI_URL       ?= http://loki:3100
else
  # Deployed by the umbrella chart into K8S_NAMESPACE, next to rucio-client.
  PROMETHEUS_URL ?= http://kube-prometheus-stack-prometheus:9090
  LOKI_URL       ?= http://loki:3100
endif

ifeq ($(GITOPS_ENV),staging)
  OBS_ENV = OBSERVABILITY_BACKEND=gmp GCP_PROJECT_ID=$(call staging_tf_output,project_id) GCP_ACCESS_TOKEN=$$(gcloud auth print-access-token)
else
  OBS_ENV = PROMETHEUS_URL=$(PROMETHEUS_URL) LOKI_URL=$(LOKI_URL)
endif

## Observability

.PHONY: test-observability
test-observability: ## Observability smoke test: scrape targets up, Rucio series, rucio-server logs
	@$(EXEC_RUCIO) bash -c "$(STAGING_PIP_INSTALL) $(OBS_ENV) DAEMON_MODE=$(DAEMON_MODE) RUNTIME=$(RUNTIME) K8S_NAMESPACE=$(K8S_NAMESPACE) pytest /tests/test_observability.py -v"

.PHONY: obs-open
obs-open: ## Open Grafana (k8s: port-forwards Grafana/Prometheus/Loki until Ctrl-C)
ifeq ($(RUNTIME),k8s)
	@trap 'kill $$(jobs -p) 2>/dev/null' EXIT; \
	$(KUBECTL) port-forward svc/grafana 3000:80 >/dev/null & \
	$(KUBECTL) port-forward svc/kube-prometheus-stack-prometheus 9090 >/dev/null & \
	$(KUBECTL) port-forward svc/loki 3100 >/dev/null & \
	sleep 2; \
	$(OPEN_URL) http://localhost:3000; \
	echo "Grafana :3000  Prometheus :9090  Loki :3100 (Ctrl-C to stop)"; \
	wait
else
	@$(OPEN_URL) http://localhost:3000
endif

.PHONY: obs-gcm-dashboards
obs-gcm-dashboards: ## Convert Grafana dashboards to Cloud Monitoring JSON
	@./scripts/convert-dashboards.sh
