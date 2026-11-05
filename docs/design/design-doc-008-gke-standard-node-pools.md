# Design-008: GKE Standard cluster with per-environment node pools

- **Status:** Proposed
- **Owner:** DEP DLM testbed
- **Related ADR(s):** [ADR-009](../adrs/adr-009-standard-gke-fixed-staging-node.md) (why); [ADR-003](../adrs/adr-003-staging-cloud-provider.md) (GCP as provider)

## Problem

`deploy/terraform/modules/kubernetes/main.tf` creates an Autopilot cluster
(`enable_autopilot = true`), so node count and scaling are not under our
control. Workload Identity and Gateway API, which ESO and the public Gateway
depend on, come implicitly with Autopilot.

## Goals

- One `kubernetes` module: a zonal Standard cluster with one node pool.
- Staging: one fixed node. Production: autoscaling node pool.
- ESO via Workload Identity, the GKE Gateway, Cloud SQL over private IP and
  the Deploy (staging) workflow keep working.

## Non-goals

- Observability on staging (next step, design doc 005).
- Spot nodes, regional clusters, multiple node pools.

## Design

- **Cluster:** zonal (`location = var.zone`), `remove_default_node_pool = true`,
  existing networking kept. Set explicitly:
  `workload_identity_config` (`<project>.svc.id.goog`) and
  `gateway_api_config { channel = "CHANNEL_STANDARD" }`.
- **Node pool:** `machine_type`, default compute SA, `cloud-platform` scope,
  `workload_metadata_config { mode = "GKE_METADATA" }`, auto-repair and
  auto-upgrade. Fixed `node_count`, or an `autoscaling` block when enabled.
- **Variables:**

  | Variable | Staging | Production |
  |---|---|---|
  | `zone` | `europe-west3-b` | chosen zone |
  | `machine_type` | `e2-standard-4` (verify) | sized for load |
  | `node_count` | `1` | unused |
  | `autoscaling_enabled` | `false` | `true` |
  | `min_node_count` / `max_node_count` | unused | e.g. `2` / `4` |

- Plain `google_container_*` resources, not
  `terraform-google-modules/kubernetes-engine`: it needs provider ≥ 7.39 (we
  pin 5.x) and defaults to regional clusters with a new node SA.

## Touch points

| File / component | Change |
|---|---|
| `deploy/terraform/modules/kubernetes/` | Standard cluster, node pool, variables |
| `deploy/terraform/environments/{staging,production}/main.tf` | Node pool variables |
| `deploy/terraform/tests/test_deployed_infra.py`, `bootstrap/main.tf`, `modules/validation-storage/main.tf`, `deploy/terraform/README.md` | Autopilot wording |
| `docs/diagrams/staging-gcp.py` | GKE Standard, one node |

## Fallback / safety behavior

- The switch recreates the cluster. Cloud SQL, Secret Manager, DNS, the
  validation VM and the Gateway IP are outside it and kept.
- Pods that do not fit stay Pending: raise `machine_type`, do not enable
  staging autoscaling.
- Billing budget alert on the staging project; `make tf-destroy` when idle.

## Testing

- `make tf-plan`: staging one node, autoscaling off; production autoscaling on.
- Deploy (staging) workflow end to end: Terraform smoke test, GitOps, e2e.
- `kubectl get nodes` shows one node with all pods Running.

## Sequencing

1. ADR-009, ADR-003 note, this design doc.
2. Module change and environment variables; review `tf-plan`.
3. Staging: `make tf-destroy`, then Deploy (staging) with Terraform, GitOps and e2e.
4. Settle `machine_type`; update docs, comments and diagram.
5. Observability on staging (design doc 005).
6. Production applies the same module once set up.

## Open questions

- Staging machine size with observability.
- Spot nodes for staging.
- Production zonal or regional.
