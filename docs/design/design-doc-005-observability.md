# Design-005: Observability for Rucio and FTS

- **Status:** Accepted (phases 1–2 on Compose and sandbox; staging in progress)
- **Owner:** DEP DLM testbed
- **Related ADR(s):** [ADR-009](../adrs/adr-009-standard-gke-fixed-staging-node.md) (staging node size)

## Problem

The testbed validates transfers, deletions and authorization end to end, but
gives no runtime visibility once a deployment is running:

- No metrics or dashboards for rucio-server, rucio-daemons or FTS.
- No central logs: a failed transfer means `docker logs`/`kubectl logs` per
  container.
- Transfer events are not collected: `configs/fts/fts-activemq.conf` exists,
  but no broker or consumer is deployed and Hermes emits nowhere.
- The staging/production observability runbook is open in `BACKLOG.md`.

Partners operating a DEP need the same visibility, so this belongs in the
GitOps blueprint, not just the sandbox.

## Goals

- Answer per environment: are the daemons and FTS healthy, what are transfer
  rate, failure rate and throughput per RSE, is the rule backlog growing?
- Compose first, then Kubernetes as optional GitOps components (Argo CD and
  Flux) on the sandbox/staging/production overlays.
- Configuration only: no source patches to Rucio or FTS.
- Staging and production clusters stay stateless and carry no observability
  frontend: storage, dashboards and alerting live outside the cluster, so
  visibility survives a cluster outage or recreate.
- Each phase is independently useful and validated in CI.

## Non-goals

- A MONIT-scale pipeline (Kafka, HDFS, long-term analytics).
- Capacity planning; retention stays at backend defaults.
- SLAs or on-call; SLOs are internal testbed targets [7, 8].
- Usage reporting for credits (ADR-005).

## Design

Three phases, each off by default (`OBSERVABILITY=1` for Compose,
`observability.enabled` in the umbrella chart). Runtime-independent
configuration lives in `configs/observability/` (Grafana dashboards,
`alerts.yml`, `sql_exporter` collectors, Alloy/Vector config, Rucio
`[monitor]`/Hermes sections) and is the single source for every
environment; only the wiring differs:

| | Compose / sandbox | Staging / production (GKE) |
|---|---|---|
| Metrics | Prometheus, in-cluster | Managed Service for Prometheus (GMP): managed collection via `PodMonitoring`, stored in Cloud Monitoring [9] |
| Logs | Alloy → Loki, in-cluster | GKE logging agent → Cloud Logging |
| Dashboards | Grafana, provisioned | Cloud Monitoring dashboards (PromQL), generated from the Grafana JSON; Logs Explorer for logs |
| Alerts | `PrometheusRule` / `rule_files` | Cloud Monitoring PromQL alert policies, generated from `alerts.yml` (evaluated in the cloud, not in-cluster) [9] |

On GKE the in-cluster parts are only the exporters, the `PodMonitoring`
resources and GKE's own managed agents (GMP collectors in `gmp-system`, the
logging agent); none of them store data. Dashboards and alert policies are
Terraform-managed Cloud Monitoring resources; GMP keeps metrics for 24
months [9]. Any Prometheus-API client, including a Grafana, can still query
the same data later without changes.

**Phase 1: Metrics**
- Rucio internal metrics as in the operator guide [2]: rucio-server via
  `metrics` in `[api] endpoints` with `PROMETHEUS_MULTIPROC_DIR`; daemons via
  `[monitor] enable_metrics` per pod on Kubernetes, via a shared multiprocess
  exporter on Compose.
- Database state [2, 4]: `sql_exporter` reads transfer state from FTS (no
  Prometheus endpoint) and rules, requests and daemon heartbeats [5] from
  Rucio. On GKE the DSNs point at Cloud SQL private IPs and come from the
  Terraform-rendered secrets via ESO.
- One dashboard modelled on the WLCG/FTS views [3, 6]: health, SLOs and error
  budgets, transfer efficiency and throughput per link, failure reasons,
  backlog (rules, conveyor queue, FTS queue), logs.

**Service level objectives** (rolling 7 days, not SLAs)
- Transfer success 95 % (finished / (finished + failed) FTS files).
- Rule latency 95 % (rules OK within 30 minutes).
- Multiwindow burn-rate alerts (14.4x/1h, 6x/6h) [8] plus component alerts:
  rucio-server or exporter down, stale daemon, stuck rules, requests blocked
  before FTS.

**Phase 2: Logs**
- Compose/sandbox: Loki plus Grafana Alloy collecting container stdout.
- GKE: Cloud Logging (default for system and workload logs), read in the
  Logs Explorer and as log panels on the Cloud Monitoring dashboard.

**Phase 3: Transfer events**
- ActiveMQ; FTS publishes via `fts-activemq.conf`; Hermes publishes Rucio
  events directly to OpenSearch or via the broker; Vector writes broker
  messages to OpenSearch; dashboards on transfers per RSE pair and failures.
- Not on staging until the open questions are settled.

```
                     Compose / sandbox            Staging / production
metrics (Rucio,  ──▶ Prometheus ──▶ Grafana       GMP ──▶ Cloud Monitoring
sql_exporter)                                             (dashboards, alerts)
container stdout ──▶ Alloy → Loki ──▶ Grafana      Cloud Logging (Logs Explorer)
FTS/Hermes ──▶ ActiveMQ ──▶ Vector ──▶ OpenSearch (phase 3)
```

## Touch points

| File / component | Change |
|---|---|
| `configs/observability/` | Dashboards, `alerts.yml`, collectors, Alloy/Vector config (single source) |
| `deploy/helm-charts/observability/` | Exporters, `PrometheusRule`; `PodMonitoring` behind a GMP toggle |
| `deploy/helm-charts/dep-dlm-testbed/` | `kube-prometheus-stack`, `loki`, `alloy` behind `observability.enabled` (sandbox) |
| `deploy/gitops/{argocd,flux}/` | Sandbox: full stack. Staging/production: `observability` chart only |
| `deploy/gitops/environments/staging/values/` | GMP toggle, exporter DSNs from Cloud SQL secrets |
| `deploy/terraform/modules/kubernetes/` | `monitoring_config { managed_prometheus { enabled = true } }`; `logging_config` with `SYSTEM_COMPONENTS`, `WORKLOADS` (explicit) |
| `deploy/terraform/modules/monitoring/` (new) | `google_monitoring_dashboard`, `google_monitoring_alert_policy`, notification channel |
| `scripts/` | Grafana JSON → Cloud Monitoring JSON, `alerts.yml` → alert policies; generated files checked in CI |
| `deploy/compose/docker-compose.observability.yml` | Compose stack |
| `Makefile` | `OBSERVABILITY=1`, `obs-open` (Grafana or console URLs), `test-observability` (per backend) |
| `.github/workflows/_gitops-deploy.yml` | `make test-observability` on staging |
| `docs/runbooks/07-observability.md` | Operator runbook |

## Fallback / safety behavior

- Off by default; enabling must not change transfer behaviour.
- Monitoring outages never block data management: Hermes keeps undelivered
  messages in the database, FTS buffers locally; both bounded by retention.
- Missing broker/OpenSearch config disables messaging instead of failing pods.
- No credentials in the repo: env files for Compose, ESO and Workload
  Identity on Kubernetes.
- Staging stays stateless: recreating the cluster loses no telemetry,
  dashboards or alerts.
- A monitoring failure must not fail the e2e transfer tests.

## Testing

- `make helm-lint`/`helm-template` with observability enabled.
- `make test-observability` in the Compose, sandbox and Deploy (staging) CI:
  exporter and rucio-server series present (Prometheus or GMP query API); a
  log query returns rucio-server logs (Loki or Cloud Logging); phase 3:
  OpenSearch holds a `transfer-done` event after the transfer tests.
- Grafana dashboards load without datasource errors; generated Cloud
  Monitoring dashboards and alert policies are up to date and plan cleanly.

## Sequencing

1. Phases 1–2 on Compose and sandbox (done).
2. Staging: enable GMP in Terraform; deploy the `observability` chart with
   `PodMonitoring`; wire exporter DSNs to Cloud SQL; generate and apply the
   dashboard and alert policies; run `make test-observability` in Deploy
   (staging).
3. Phase 3 on Compose; decide its open questions; then sandbox and staging.
4. Runbook `07-observability.md`; close the `BACKLOG.md` item.
5. Production overlay once staging has run stably.

## Open questions

- Dashboard conversion: which panels (tables, transformations, variables)
  need hand-tuning, and can the generated output stay untouched?
- Cost of GMP samples and Cloud Logging ingestion beyond the free tiers.
- Grafana Cloud as an alternative frontend: identical dashboards everywhere,
  but a non-GCP data processor (data-protection sign-off).
- Hermes: OpenSearch directly or via ActiveMQ; could events go to the log
  backend instead, dropping OpenSearch?
- Partner production: bundled backend or the partner's existing stack?
- PromQL labels on GMP (`project_id`, `location`, `cluster`; different
  `job`/`instance` values): which dashboard and alert queries need adjusting
  during generation?

## References

1. M. Barisits et al., "Rucio: Scientific Data Management", *Computing and
   Software for Big Science* 3, 11 (2019),
   [doi:10.1007/s41781-019-0026-3](https://doi.org/10.1007/s41781-019-0026-3).
2. Rucio operator documentation, [Monitoring](https://rucio.cern.ch/documentation/operator/monitoring).
3. H. Riahi et al., [Quantitative transfer monitoring for FTS3](https://indico.cern.ch/event/304944/contributions/1672313/), CHEP 2015.
4. [WLCG Transfers Dashboard](https://cern.ch/twiki/bin/view/LCG/WLCGTransferDashboard).
5. Rucio source, [`lib/rucio/core/heartbeat.py`](https://github.com/rucio/rucio/blob/master/lib/rucio/core/heartbeat.py).
6. [Rucio publications](https://rucio.cern.ch/publications.html).
7. B. Beyer et al., *Site Reliability Engineering*, O'Reilly (2016),
   [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/).
8. B. Beyer et al., *The Site Reliability Workbook*, O'Reilly (2018),
   [Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/).
9. Google Cloud, [Managed Service for Prometheus](https://cloud.google.com/stackdriver/docs/managed-prometheus):
   managed collection, PromQL in Cloud Monitoring, cloud-evaluated alerts,
   24-month retention.
