# Design-005: Observability for Rucio and FTS

- **Status:** Proposed
- **Owner:** DEP DLM testbed
- **Related ADR(s):** none yet

## Problem

The testbed validates transfers, deletions and authorization end to end, but
gives no runtime visibility once a deployment is running:

- No metrics: nothing scrapes rucio-server, rucio-daemons or FTS and there
  are no dashboards for daemon health or rule backlog.
- No central logs: diagnosing a failed transfer means `docker logs` or
  `kubectl logs` per container (see `docs/troubleshooting.md`).
- Transfer events are not collected: `shared/config/fts/fts-activemq.conf`
  exists, but no broker or consumer is deployed and Hermes is not configured
  to emit anywhere.
- The staging/production runbook for observability is still open in
  `BACKLOG.md`.

Partners operating a DEP need the same visibility, so this belongs in the
GitOps blueprint, not just the sandbox.

## Goals

- Answer, per environment: Are the Rucio daemons and FTS healthy? What is the
  transfer rate, failure rate and throughput per RSE? Is the rule backlog
  growing?
- Build on Docker Compose first, then translate to Kubernetes as optional
  GitOps components (Argo CD and Flux) on the existing
  sandbox/staging/production overlays.
- Configuration only: no source patches to Rucio or FTS.
- Each phase is independently useful and validated in CI.

## Non-goals

- A MONIT-scale pipeline (Kafka, HDFS, long-term analytics). Too heavy for
  RI-SCALE's scale.
- Long-term retention or capacity planning. Defaults only.
- SLAs or on-call commitments. SLOs are internal targets for the testbed
  [7, 8]; agreements with partners are out of scope.
- Usage reporting for credits (covered by ADR-005).

## Design

Three phases, each off by default (`OBSERVABILITY=1` for Compose,
`observability.enabled` in the umbrella chart for Kubernetes; the GitOps
sandbox environment enables them). Each phase is built on Compose first, then
translated to Kubernetes.

Runtime-independent configuration lives in `shared/config/observability/` and
is used by both runtimes: dashboards, datasources, alert rules, the Rucio
`[monitor]`/Hermes sections, `fts-activemq.conf` and the Vector config. Only
the wiring differs:

| | Compose | Kubernetes |
|---|---|---|
| Metrics | Prometheus with static scrape config | `kube-prometheus-stack` in `dep-dlm-<env>`, scrape config in its values (endpoints discovery) |
| Logs | Alloy with Docker discovery | Alloy with pod discovery |
| Dashboards | Grafana file provisioning | Grafana ConfigMap sidecar |
| Exporters, alerts | Compose services, `rule_files` | `deploy/helm-charts/observability` (Deployments, `PrometheusRule`) |

**Phase 1: Metrics**
- Prometheus and Grafana (Alertmanager only on Kubernetes).
- Internal metrics from the components, as in the Rucio monitoring guide
  [2]:
  - rucio-server: `metrics` in `[api] endpoints` of `rucio.cfg`, with
    `PROMETHEUS_MULTIPROC_DIR` so all server processes report together. In
    direct mode the `--run-once` daemons run inside this container, so their
    metrics appear here too.
  - rucio-daemons on Kubernetes: `[monitor] enable_metrics` in the daemons'
    own configuration (chart `config:`), so each daemon pod serves `/metrics`
    on its `metrics` port; `monitoring.enabled` adds the Service that
    Prometheus discovers. The server keeps it off: every server process
    would try to bind the same port.
  - rucio-daemons on Compose: all daemons share one container, so
    per-process ports would clash. They write multiprocess files to a shared
    volume that a small `rucio-daemons-metrics` exporter serves.
- Data management state from the databases, as WLCG and the Rucio operator
  guide do [2, 4]: FTS has no Prometheus endpoint, so `sql_exporter` reads
  transfer state from the FTS database; a second instance reads rules,
  transfer requests and daemon heartbeats from the Rucio database.
- Daemon liveness from Rucio's `heartbeats` table [5]: each daemon refreshes
  its row every cycle and removes it on clean exit, so a stale row means a
  hung or crashed daemon. This works the same in both runtimes and in both
  daemon modes, independent of the metrics endpoints.
- One dashboard, modelled on the WLCG/ATLAS/CMS transfer views [3, 6]:
  - health: rucio-server, exporters, stale daemons, transfer efficiency,
    stuck rules
  - SLOs and remaining error budgets
  - transfers: efficiency matrix, throughput per link (volume / time),
    failure categories and top reasons, the views FTS3 monitoring is built
    around [3]
  - backlog: rules by state, oldest open rule, Rucio transfer requests (the
    conveyor queue [2]), FTS queue
  - logs, collapsed

**Service level objectives**
- Internal targets over a rolling 7-day window, not SLAs:
  - transfer success 95 %: finished / (finished + failed) FTS files
  - rule latency 95 %: rules reaching OK within 30 minutes
- Alerts in `alerts.yml`:
  - burn-rate alerts on both SLOs (fast: 14.4x over 1h, slow: 6x over 6h),
    the multiwindow scheme of the SRE Workbook [8]. Its thresholds assume a
    30-day budget; on the 7-day window they fire after a larger share of the
    budget is spent, which is acceptable for a testbed.
  - component alerts: rucio-server down, exporter down, stale daemon, daemon
    metrics down, stuck rules, transfer requests blocked before FTS
    (submission failed, no sources, no matching scheme)

**Phase 2: Logs**
- Loki plus Grafana Alloy (Promtail is in LTS; Alloy is its successor),
  collecting stdout of all DEP DLM containers.
- Loki as a Grafana datasource; log panels linked from dashboards.

**Phase 3: Transfer events**
- ActiveMQ broker; FTS publishes to it via `fts-activemq.conf`.
- Hermes publishes Rucio events (`transfer-done`, `transfer-failed`,
  `deletion-done`, `RULE_OK`) directly to OpenSearch or via the broker (see
  Open questions).
- OpenSearch plus a STOMP consumer (Vector) writing broker messages to it.
- Dashboards on the OpenSearch datasource: transfers per RSE pair, failure
  reasons, throughput.

```
rucio-server/daemons ──metrics────────▶ Prometheus ──┐
Rucio/FTS DBs ──▶ sql_exporter ───────▶ Prometheus   │
all containers ──stdout──▶ Alloy ─────▶ Loki ────────┼──▶ Grafana
FTS ──STOMP──▶ ActiveMQ ──▶ Vector ───▶ OpenSearch ──┘
Hermes ───────────────────────────────▶ OpenSearch
```

## Touch points

| File / component | Change |
|---|---|
| `shared/config/observability/` (new) | Dashboards, datasources, alert rules, `sql_exporter` collectors, Alloy and Vector config |
| `deploy/helm-charts/observability/` (new) | Exporters, `PrometheusRule` and dashboard ConfigMap from `shared/config/observability` |
| `deploy/helm-charts/dep-dlm-testbed/` | `observability`, `kube-prometheus-stack`, `loki`, `alloy` dependencies behind `observability.enabled` |
| `deploy/compose/docker-compose.observability.yml` (new) | Prometheus, Grafana, Loki, Alloy, ActiveMQ, OpenSearch, Vector |
| `deploy/gitops/flux/components/` | New: `kube-prometheus-stack`, `loki`, `alloy`, `observability`; later `activemq`, `opensearch`, `vector` |
| `deploy/gitops/argocd/applicationsets/` | Same components for Argo CD |
| `deploy/gitops/base/values/` | Values for the new components; `PROMETHEUS_MULTIPROC_DIR` for rucio-server; `[monitor] enable_metrics` and `monitoring.enabled` for rucio-daemons; Hermes later |
| `shared/config/rucio/` and `deploy/terraform/modules/secrets/templates/rucio.cfg.tftpl` | `[monitor]` and Hermes sections |
| `shared/config/fts/fts-activemq.conf` | Broker endpoint per environment |
| `Makefile` | `OBSERVABILITY=1` toggle for `start`; `obs-open` and `test-observability` targets |
| `docs/runbooks/07-observability.md` (new) | Operator runbook |

## Fallback / safety behavior

- All components are off by default; enabling them must not change transfer
  behaviour.
- Monitoring outages must not block data management: Hermes keeps
  undelivered messages in the database and FTS buffers messages locally when
  the broker is down. Bound both with retention settings.
- Missing broker or OpenSearch config: Hermes and FTS messaging stay disabled
  rather than failing the containers.
- No credentials in the repo: local env files for Compose, the existing
  External Secrets path for Kubernetes.

## Testing

- `make helm-lint` and `helm-template` with observability enabled.
- `make test-observability` (new), run in the existing Compose and k8s CI
  jobs:
  - Phase 1: Prometheus targets for rucio-server and the database
    exporters (and rucio-daemons in daemons mode) are `up`, rucio-server
    returns metric series, and the exporters return rule and transfer
    metrics.
  - Phase 2: a Loki query returns rucio-server logs.
  - Phase 3: after `make test-rucio-transfers`, OpenSearch holds at least one
    `transfer-done` event from Hermes and one completion message from FTS.
- Dashboards load in Grafana without datasource errors (provisioning check).

## Sequencing

1. Phase 1 on Compose, then sandbox Kubernetes, then staging.
2. Phase 2 on Compose, then sandbox Kubernetes, then staging.
3. Phase 3 on Compose; decide the open questions; then sandbox Kubernetes
   and staging.
4. Runbook `07-observability.md`; close the observability item in `BACKLOG.md`.
5. Production overlay once staging has run stably.

## Open questions

- Hermes: write to OpenSearch directly, or via ActiveMQ for a single ingest
  path? Confirm direct OpenSearch support for this Rucio version.
- Could events go to Loki instead of OpenSearch, dropping one component?
- Resource cost of the full stack on GKE staging; whether OpenSearch fits.
- Keep Compose observability in CI permanently, or only as a development aid
  once Kubernetes is covered?
- Who operates this in partner production deployments: bundled, or the
  partner's existing monitoring stack?

## References

1. M. Barisits et al., "Rucio: Scientific Data Management", *Computing and
   Software for Big Science* 3, 11 (2019),
   [doi:10.1007/s41781-019-0026-3](https://doi.org/10.1007/s41781-019-0026-3).
2. Rucio operator documentation, [Monitoring](https://rucio.cern.ch/documentation/operator/monitoring):
   internal metrics, Hermes events, database queries, probes, dashboards.
3. H. Riahi, M. Salichos, O. Keeble et al., [Quantitative transfer monitoring for FTS3](https://indico.cern.ch/event/304944/contributions/1672313/),
   CHEP 2015: efficiency between sites, achieved throughput, most common errors.
4. [WLCG Transfers Dashboard](https://cern.ch/twiki/bin/view/LCG/WLCGTransferDashboard):
   cross-VO view of FTS and XRootD transfers.
5. Rucio source, [`lib/rucio/core/heartbeat.py`](https://github.com/rucio/rucio/blob/master/lib/rucio/core/heartbeat.py):
   daemon heartbeats (`readable` name, hashed `executable`, removal on exit).
6. [Rucio publications](https://rucio.cern.ch/publications.html), including
   the ATLAS and CMS operational experience.
7. B. Beyer et al., *Site Reliability Engineering*, O'Reilly (2016),
   [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/).
8. B. Beyer et al., *The Site Reliability Workbook*, O'Reilly (2018),
   [Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/).
