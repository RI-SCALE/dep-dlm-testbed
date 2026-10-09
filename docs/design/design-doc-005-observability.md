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
- Alerting beyond a few basic rules (daemon down, transfer failure ratio).
- Usage reporting for credits (covered by ADR-005).

## Design

Three phases, each off by default (`OBSERVABILITY=1` for Compose, an
`observability.*` values flag for Kubernetes). Each phase is built on Compose
first, then translated to Kubernetes.

Runtime-independent configuration lives in `shared/config/observability/` and
is used by both runtimes: dashboards, datasources, alert rules, the Rucio
`[monitor]`/Hermes sections, `fts-activemq.conf` and the Vector config. Only
the wiring differs:

| | Compose | Kubernetes |
|---|---|---|
| Metrics | Prometheus with static scrape config | `kube-prometheus-stack` + ServiceMonitors |
| Logs | Alloy with Docker discovery | Alloy with pod discovery |
| Dashboards | Grafana file provisioning | Grafana ConfigMap sidecar |

**Phase 1: Metrics**
- Prometheus, Grafana and Alertmanager.
- Enable Rucio metrics via `[monitor]` in `rucio.cfg` (and the upstream
  chart's monitoring values on Kubernetes).
- Dashboards: daemon health, rule states, API request rates.

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
rucio-server/daemons ──metrics──▶ Prometheus ─┐
all containers ──stdout──▶ Alloy ──▶ Loki ────┼──▶ Grafana
FTS ──STOMP──▶ ActiveMQ ──▶ Vector ──▶ OpenSearch ┘
Hermes ──────────────────────────────▶ OpenSearch
```

## Touch points

| File / component | Change |
|---|---|
| `shared/config/observability/` (new) | Dashboards, datasources, alert rules, Vector config |
| `deploy/compose/docker-compose.observability.yml` (new) | Prometheus, Grafana, Loki, Alloy, ActiveMQ, OpenSearch, Vector |
| `deploy/gitops/flux/components/` | New: `kube-prometheus-stack`, `loki`, `alloy`, `activemq`, `opensearch`, `vector` |
| `deploy/gitops/argocd/applicationsets/` | Same components for Argo CD |
| `deploy/gitops/base/values/rucio-server.yaml`, `rucio-daemons.yaml` | Monitoring values, ServiceMonitors, Hermes enabled |
| `shared/config/rucio/` and `deploy/terraform/modules/secrets/templates/rucio.cfg.tftpl` | `[monitor]` and Hermes sections |
| `shared/config/fts/fts-activemq.conf` | Broker endpoint per environment |
| `Makefile` | `OBSERVABILITY=1` toggle for `start`; `test-observability` target |
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
  - Phase 1: Prometheus targets for rucio-server and rucio-daemons are `up`.
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

- How does Rucio 41.x expose metrics: a Prometheus endpoint, or a push
  gateway? Which chart values enable it?
- Hermes: write to OpenSearch directly, or via ActiveMQ for a single ingest
  path? Confirm direct OpenSearch support for this Rucio version.
- Could events go to Loki instead of OpenSearch, dropping one component?
- Resource cost of the full stack on GKE staging; whether OpenSearch fits.
- Keep Compose observability in CI permanently, or only as a development aid
  once Kubernetes is covered?
- Who operates this in partner production deployments: bundled, or the
  partner's existing monitoring stack?
