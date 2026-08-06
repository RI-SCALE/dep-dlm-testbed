---
status: proposed
date: 2026-07-27
decision-makers: DEP DLM testbed maintainers
consulted: RI-SCALE PM / procurement, data protection contact
informed: DEP component owners, partner RIs
---
# Cloud Provider for Staging/Production Infrastructure

## Context and Problem Statement

Staging and production validation of the DEP DLM GitOps deployment
requires externalized infrastructure the sandbox currently bundles
in-cluster: a managed Kubernetes cluster, a managed secrets store (in
place of the sandbox's in-cluster Vault dev instance), and managed
PostgreSQL for Rucio/FTS metadata. A standardized, project-supported
on-premise Kubernetes environment is not currently available for all
participating partners, and the on-premise provisioning path itself is
not yet defined (see the adjacent, still-open on-premise backlog item).
A public cloud with managed equivalents of these services is therefore
the most reasonable way to validate staging/production convergence in
the near term.

Several RI-SCALE use cases process sensitive data, including medical
imaging (colorectal cancer risk prediction, synthetic pathology data
generation). This raises the bar on data-residency and regulatory
alignment beyond a pure cost/feature comparison.

## Decision Drivers

* No reliance on partner-provisioned on-premise Kubernetes, which is not
  standardized across partners today.
* Managed equivalents for every service the sandbox currently bundles
  in-cluster (Kubernetes, secrets, PostgreSQL), so the staging deployment
  view stays structurally identical to sandbox — only what's internal vs.
  external changes (see docs/diagrams/staging.py).
* Low operational overhead for an environment-per-test-cycle workload —
  environments stood up and torn down repeatedly, not a single
  long-running, hand-tuned production cluster.
* A single supported reference provider, so infra/terraform/ has one
  target to build and maintain rather than parallel provider-specific
  paths.
* Credible EU data-residency and GDPR-alignment story, given medical data
  in scope for several RI-SCALE use cases.
* Terraform provider maturity — AWS's, Azure's and GCP's providers are
  all mature and comparably capable; this driver rules out none of them
  on its own.

## Considered Options

1. AWS (EKS + Secrets Manager + RDS/Aurora)
2. Azure (AKS + Key Vault + PostgreSQL Flexible Server)
3. GCP (GKE Autopilot + Secret Manager + Cloud SQL for PostgreSQL)

## Decision Outcome

Chosen option: **GCP (GKE Autopilot + Secret Manager + Cloud SQL for
PostgreSQL)**

Primary factors:

* **Operational simplicity for a low-maintenance, ephemeral-environment
  workload**: GKE Autopilot is the most hands-off of the three managed
  Kubernetes offerings — Google manages node provisioning, scaling and
  patching by default, and pod-based billing means an idle or torn-down
  environment stops accruing node cost immediately rather than leaving
  provisioned VMs running. This fits the environment-per-test-cycle
  pattern more directly than AKS or EKS's node-pool models, both of
  which still require some node-pool sizing/lifecycle decisions even
  with their own automation features (AKS Automatic, EKS Auto Mode/
  Karpenter).
* **Cluster-fee economics for a single ephemeral cluster**: GKE charges
  a per-cluster management fee like EKS, but Google's $74.40/month free
  credit (per billing account) covers the fee for one zonal or Autopilot
  cluster — in practice making a single testbed cluster's management fee
  a wash, similar in outcome to AKS's fee-free standard tier, just
  structured differently. This is not a claim that GCP is cheaper
  overall: node, storage and networking costs are broadly comparable
  across all three providers and dominate total spend once a cluster is
  doing real work.
* **EU data-residency story**: GCP offers EU-region data-residency and
  sovereignty commitments comparable in shape to Azure's EU Data
  Boundary and AWS's European Sovereign Cloud initiative — relevant
  given the medical-data use cases in scope. As with the other two,
  coverage is service- and region-specific and rollout has been phased;
  no provider is categorically ahead here (see Open Points).
* **Single supported reference provider**: choosing one provider now is
  preferable to maintaining parallel Terraform paths for a testbed at
  this stage. The underlying Kubernetes workloads remain portable
  regardless of provider; only the Terraform resource definitions, the
  managed database, and the managed secrets store are provider-specific
  (see Consequences).

AWS was the closer runner-up: broader service/ecosystem depth and more
prevalent in EU research-infrastructure projects generally, partly via
its research-credit programs — a real consideration if partner
familiarity or existing credits favor it. That signal is not yet
confirmed (see Open Points), which is why it's noted here rather than
changing the outcome.

This decision is **operations- and cost-led, not compliance-led**.
Neither GCP, Azure nor AWS is categorically more GDPR-compliant than the
others at the brand level; actual compliance depends on region
selection, Data Processing Agreement terms, and configuration
(encryption, access control, audit logging), not the provider name.

## Consequences

### Positive
* No dependency on partner on-premise Kubernetes availability.
* Structurally mirrors the sandbox deployment view (see
  [staging.png](../diagrams/generated/staging.png) once produced) — same components, external
  instead of in-cluster.
* Lowest operational overhead of the three options for a workload of
  repeatedly created/torn-down environments.
* infra/terraform/ has a single target provider to build modules
  against, rather than maintaining multiple provider paths in parallel.
* Kubernetes workloads themselves remain portable; provider lock-in is
  confined to Terraform resource definitions, the managed database, and
  the managed secrets store, not the application layer.

### Negative
* Introduces a dependency on GCP-specific Terraform providers and GKE-
  specific operational knowledge, over providers (AWS in particular)
  more commonly seen elsewhere in EU research-infrastructure projects.
* Partners already standardized on AWS or Azure internally would need to
  bridge or accept a third/different cloud vendor for DEP DLM staging
  specifically.
* Switching later means rewriting the provider-specific Terraform
  resources in infra/terraform/modules/ — the module interfaces,
  variables and outputs can generally be preserved if modules already
  separate provider-specific resources from reusable interfaces; only
  the resource definitions themselves need not survive a switch.
* GKE Autopilot's pod-based billing model requires more careful resource
  request sizing than a flat node-based model to avoid overpaying for
  over-requested pods — a different (not necessarily larger) operational
  learning curve than AKS/EKS's node-pool model.

## Open Points

* **Not yet confirmed with RI-SCALE PM/procurement**: whether existing
  cloud credits, framework agreements, or partner commitments favor a
  specific provider — including whether AWS's or GCP's research-credit
  programs are actually available to this project. This could override
  the reasoning above outright and needs checking before this ADR is
  marked accepted.
* **Not yet confirmed with a data protection contact**: whether GCP's
  EU data-residency commitments (or the specific region chosen) satisfy
  the regulatory requirements applicable to the medical-data use cases
  in scope, and whether the specific services this deployment needs
  (GKE, Secret Manager, Cloud SQL) are covered. This ADR's compliance
  reasoning is a starting point, not a legal sign-off.
* Region selection within GCP is not yet decided — follow-on to this
  ADR once the provider itself is confirmed.
* **Not yet specified**: networking (VPC design, private connectivity
  requirements) and identity (Workload Identity Federation vs. Azure
  Managed Identity vs. AWS IAM/IRSA, and how GitOps workload identity
  maps onto whichever is chosen) — both are follow-on design work once
  the provider is confirmed, not blockers to this decision.
* Partner/team familiarity with GCP specifically has not been surveyed —
  worth a quick check given AWS's greater prevalence in this project
  space generally.

## Confirmation

Compliance is confirmed by:
* infra/terraform/modules/ built against GCP resources only (GKE, Secret
  Manager, Cloud SQL for PostgreSQL), no parallel AWS/Azure modules
  maintained.
* RI-SCALE PM/procurement sign-off recorded before status moves from
  `proposed` to `accepted`.
* Data protection contact confirmation recorded before any medical-data
  use case is validated against this infrastructure.
