# infra/terraform

Terraform IaC for DEP DLM testbed staging/production infrastructure on
GCP. See [`docs/adrs/adr-003-staging-cloud-provider.md`](../../docs/adrs/adr-003-staging-cloud-provider.md)
for why GCP, and [`docs/diagrams/staging-gcp.py`](../../docs/diagrams/staging-gcp.py)
(→ `generated/staging-gcp.png`) for the deployment view this provisions.

## What this does and doesn't provision

**Provisions**: VPC/subnet, GKE Autopilot cluster + Workload Identity
binding, Secret Manager secret containers (empty — values provisioned
out-of-band), Cloud SQL for PostgreSQL (private IP, `rucio` + `fts`
databases).

**Does NOT provision**: Rucio, FTS, External Secrets Operator, or any
other workload inside the cluster. Those remain GitOps-managed (Argo CD
or Flux) — Terraform's job ends at "a working GKE cluster with the
external services it needs to reach exist and are reachable"; GitOps
takes it from there, matching the boundary drawn in ADR-003.

Storage RSEs (source/destination) are external to this infrastructure
entirely — partner-operated, not provisioned by this repo.

## Layout

```
infra/terraform/
├── environments/
│   ├── staging/       # root module — apply this for staging
│   └── production/     # placeholder, NOT YET VALIDATED — see its main.tf
├── modules/
│   ├── networking/     # VPC, subnet, private services access
│   ├── kubernetes/     # GKE Autopilot + Workload Identity
│   ├── secrets/        # Secret Manager containers + ESO IAM binding
│   └── database/       # Cloud SQL for PostgreSQL, private IP
└── README.md
```

Each environment is its own root module with its own state — staging and
production never share state or a GCP project.

## Prerequisites

- `gcloud auth application-default login` (or a service account key via
  `GOOGLE_APPLICATION_CREDENTIALS`) with permissions to create the
  resources above in the target project.
- APIs enabled on the target project:
  `container.googleapis.com`, `secretmanager.googleapis.com`,
  `sqladmin.googleapis.com`, `servicenetworking.googleapis.com`,
  `compute.googleapis.com`, `iam.googleapis.com`.
  ```bash
  gcloud services enable container.googleapis.com secretmanager.googleapis.com \
    sqladmin.googleapis.com servicenetworking.googleapis.com \
    compute.googleapis.com iam.googleapis.com --project=<project_id>
  ```
- A GCS bucket for remote state (see `environments/staging/backend.tf`
  for the exact command) — created once, out-of-band, before first
  `terraform init`.

## Usage

```bash
cd infra/terraform/environments/staging
cp terraform.tfvars.example terraform.tfvars   # fill in project_id at minimum
# uncomment the backend block in backend.tf once the state bucket exists
terraform init
terraform plan
terraform apply
```

After `apply`, complete the Workload Identity binding on the cluster
side (Terraform creates the GCP-side IAM binding; the k8s ServiceAccount
annotation is a GitOps/cluster-side concern):

```bash
kubectl annotate serviceaccount external-secrets \
  -n external-secrets \
  iam.gke.io/gcp-service-account=$(terraform output -raw eso_service_account_email)
```

Then populate the (currently empty) Secret Manager secrets with real
values — out-of-band, per the same rule the sandbox already follows:
sensitive values are never committed to this repo.

## What's genuinely not decided yet

See ADR-003's Open Points — region selection, procurement/credit
confirmation, and data-protection sign-off are all still open. This
scaffold is safe to `plan` against for review purposes but treat
`apply` as blocked on those confirmations for anything beyond your own
throwaway testing.
