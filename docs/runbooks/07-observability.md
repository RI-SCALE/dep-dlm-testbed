# Runbook 7 — Observability on staging and production

## Purpose
Operate metrics, logs, dashboards and alerts for Rucio, its daemons, FTS and
their databases on the GKE environments. Telemetry is stored and viewed in
Google Cloud, outside the cluster, so it survives a cluster outage or rebuild
([design doc 005](../design/design-doc-005-observability.md)):

| Signal | Collected by | Stored and viewed in |
|---|---|---|
| Metrics | Managed Service for Prometheus, via `PodMonitoring` | Cloud Monitoring (Metrics explorer, dashboards) |
| Logs | GKE workload logging (container stdout/stderr) | Cloud Logging (Logs Explorer) |
| Alerts | Cloud Monitoring PromQL alert policies | Cloud Monitoring (Alerting), optional e-mail |

Only the exporters, the `PodMonitoring` resources and GKE's managed agents run
in the cluster. Sandbox and Compose keep the in-cluster Prometheus, Grafana,
Loki and Alloy stack (`OBSERVABILITY=1`, `make obs-open`), which is not
covered here.

## Prerequisites
- Bootstrap applied with the monitoring and logging APIs, the CI roles
  `roles/monitoring.editor` and `roles/logging.viewer`, and
  `roles/container.defaultNodeServiceAccount` for the node service account.
- The environment applied (`make tf-apply TF_ENV=<env>`) and GitOps synced,
  including the `observability` application.
- `gcloud` authenticated against the environment's project; a fresh
  kubeconfig (`make tf-kubeconfig`, the token expires after about an hour).

## Configuration reference

| What | Where |
|---|---|
| Managed Prometheus and workload logging on the cluster | `deploy/terraform/modules/kubernetes` (`monitoring_config`, `logging_config`) |
| Scrape targets (`PodMonitoring`) | `deploy/helm-charts/observability/templates/podmonitoring.yaml`, enabled and listed per environment in `deploy/gitops/environments/<env>/values/observability.yaml` (`gmp.enabled`, `gmp.podMonitorings`) |
| Scrape job names | `rucio-server`, `rucio-daemons`, `fts`, `rucio-db`; each `PodMonitoring` name becomes the `job` label, which alerts, dashboard and tests rely on |
| Exporter database DSNs | `testbed-secrets` keys `rucio-db-dsn` and `fts-db-dsn`, rendered by `deploy/terraform/modules/secrets` |
| Rucio metrics endpoint | `metrics` in `[api] endpoints` of `modules/secrets/templates/rucio.cfg.tftpl` |
| Alert rules (single source) | `configs/observability/prometheus/alerts.yml`, turned into alert policies by `deploy/terraform/modules/monitoring` (recording rules inlined) |
| Dashboards (single source) | Grafana JSON in `configs/observability/grafana/dashboards/`, converted by `make obs-gcm-dashboards` into `configs/observability/cloud-monitoring/dashboards/`, applied by `modules/monitoring` |
| Alert e-mail | Terraform variable `alert_notification_email` (unset: console only) |

## Steps

### 1. Provision and deploy
Apply the environment and let GitOps sync. Check that the scrape targets are
accepted by Managed Prometheus:

```bash
kubectl -n dep-dlm-<env> get podmonitoring
kubectl -n dep-dlm-<env> describe podmonitoring rucio-server | grep -A3 Conditions
```

Each should report `ConfigurationCreateSuccess`.

### 2. Produce metrics
Rucio server series only appear after real API traffic, and FTS series only
once FTS has transfers. Run the usual initialisation and a transfer:

```bash
make init
make test-rucio-transfers
```

### 3. Create the pending alert policies
Cloud Monitoring rejects an alert policy whose metrics were never ingested
into the project, so `modules/monitoring` creates a policy only once its
metrics exist and lists the rest under `pending_alert_policies`. After step 2:

```bash
make tf-apply AUTO_APPROVE=1 TF_TARGET=module.monitoring
terraform -chdir=deploy/terraform/environments/<env> output pending_alert_policies
```

CI does this after the e2e tests. Some policies stay pending until their
metric has appeared at least once (e.g. after a failed or stuck transfer); a
later apply picks them up.

### 4. Look at the data
- **Dashboard:** Cloud Console → Monitoring → Dashboards → *Rucio and FTS
  overview*.
- **Logs:** Cloud Console → Logging → Logs Explorer, for example:
  ```
  resource.type="k8s_container"
  resource.labels.namespace_name="dep-dlm-<env>"
  resource.labels.container_name="rucio-server"
  ```
- **Ad hoc PromQL:** Monitoring → Metrics explorer → PromQL, e.g.
  `up{job="rucio-server"}`.
- **Alerts:** Monitoring → Alerting.

### 5. Change a dashboard
Edit the Grafana JSON (the single source), then regenerate and apply:

```bash
make obs-gcm-dashboards          # needs Node.js >= 20.4 (dev container has it)
git add configs/observability/
make tf-apply
```

### 6. Change an alert
Edit `configs/observability/prometheus/alerts.yml` and apply. The same file
drives the in-cluster Prometheus on sandbox and Compose. An alert may use at
most one recording rule; the module's precondition fails the plan otherwise.

## Verification

```bash
make test-observability GITOPS_ENV=<env>
```

This checks that the `rucio-server`, `fts` and `rucio-db` jobs report `up`,
that Rucio series are present in Managed Prometheus, and that rucio-server
logs reach Cloud Logging. It needs `gcloud auth print-access-token` to work
and the transfers from step 2. CI runs it after the e2e tests.

Known differences from Prometheus, relevant when writing queries or
debugging (details in [troubleshooting](../troubleshooting.md)):
- Managed Prometheus rejects regex matchers on `__name__`; use exact metric
  names.
- There is no `/api/v1/targets`; check targets via `PodMonitoring` status and
  `up`.
- `up{job="rucio-server"} == 0` with a 404 means `metrics` is missing from
  `[api] endpoints`.
