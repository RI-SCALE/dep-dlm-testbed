---
status: proposed
date: 2026-11-05
decision-makers: Marvin Gajek
consulted:
informed: DEP DLM / RI-SCALE
---

# ADR-009: Run staging on a single fixed-size node, autoscale only production

## Context and Problem Statement

[ADR-003](./adr-003-staging-cloud-provider.md) chose GCP with GKE Autopilot for low operational overhead and because
pod-based billing stops node cost when an environment is idle or torn down.
In practice, staging workloads (Rucio, FTS, exporters) run continuously while
the environment is up, so pod-based billing saves nothing over a fixed node,
and a torn-down environment costs nothing in either mode.

Autopilot has also caused problems in staging: default pod requests triggered
node scale-up for trivial one-shot pods, which then failed on zonal GCE
capacity, and host-level restrictions affect node agents such as the sandbox's
log collector. With the free trial over and personal billing, staging cost
must be low and predictable, while production must be able to scale.

Which cluster mode and node scaling should staging and production use?

## Decision Drivers

* Predictable, low staging cost
* Staging structurally identical to production (design doc 007)
* Production scales with load
* Sandbox workloads, including observability, run unchanged
* One Terraform module for both environments, differing only by variables

## Considered Options

1. Keep GKE Autopilot for both
2. GKE Standard for both: one fixed node for staging, autoscaling node pool for production
3. GKE Standard for staging, Autopilot for production
4. Single VM with kind/k3s for staging

## Decision Outcome

Chosen option: **2**, because it makes staging cost predictable, keeps both
environments on the same module and cluster mode, and still lets production
scale.

Only the node pool differs: staging has autoscaling off and one node sized for
the full stack; production autoscales with a minimum that tolerates a node
loss. The GCP provider choice from ADR-003 stands. Spot nodes for staging are
left open.

### Positive Consequences

* Staging compute is one known machine, independent of pod requests
* No scale-up or zonal capacity failures from short-lived pods
* Node-level agents run as in the sandbox
* Staging remains a faithful rehearsal of production

### Negative Consequences

* Node pools, sizing and upgrades are ours to manage (gives up part of ADR-003's "most hands-off" driver)
* Staging capacity is a hard ceiling; what does not fit stays Pending
* Workload Identity and Gateway API must be enabled explicitly
* The cluster is recreated on switch; acceptable as staging is disposable and production is not live

## Confirmation

* Terraform plan: staging has one node pool, autoscaling off, one node; production has autoscaling on
* Deploy (staging) passes end to end, including with observability enabled and `make test-observability`
* A billing budget alert covers the staging project

## Pros and Cons of the Options

### 1. Autopilot for both

* Good — no node management, no change needed
* Bad — cost follows pod requests; no fixed ceiling
* Bad — observed scale-up and capacity failures; host-agent restrictions

### 2. Standard for both

* Good — predictable staging cost, scalable production, one module
* Bad — node management is ours; staging capacity is fixed

### 3. Standard for staging, Autopilot for production

* Good — cheap staging, hands-off production
* Bad — staging no longer rehearses production; two configurations

### 4. Single VM with kind/k3s

* Good — cheapest
* Bad — drops GKE Gateway, Workload Identity and managed networking; separate deployment path

## Evidence / Links

* ADR-003: GCP as provider, Autopilot as originally chosen cluster mode (revisited here)
* Design doc 007: GitOps blueprint, staging = production shape
* Design doc 005: observability, deployed on staging next
* `deploy/terraform/tests/test_deployed_infra.py`: low requests on DB check pods to avoid Autopilot scale-up and capacity failures
