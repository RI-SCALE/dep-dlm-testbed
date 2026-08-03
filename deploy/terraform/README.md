# deploy/terraform

Terraform IaC for DEP DLM testbed staging/production infrastructure on
GCP. See [`docs/adrs/adr-003-staging-cloud-provider.md`](../../docs/adrs/adr-003-staging-cloud-provider.md)
for why GCP and [`docs/diagrams/staging-gcp.py`](../../docs/diagrams/staging-gcp.py)
(→ `generated/staging-gcp.png`) for the deployment view this provisions.

## What this does and doesn't provision

**Provisions**: the `dep-dlm-staging`/`dep-dlm-production` GCP Projects
themselves, their VPC/subnet/private-services-access networking (both in
`bootstrap/` — see below), GKE Autopilot cluster + Workload Identity
binding, Secret Manager secret containers (empty — values provisioned
out-of-band), Cloud SQL for PostgreSQL (private IP, `rucio` + `fts`
databases) — the last three in `environments/<env>`.

**Does NOT provision**: Rucio, FTS, External Secrets Operator, or any
other workload inside the cluster. Those remain GitOps-managed (Argo CD
or Flux) — Terraform's job ends at "a working GKE cluster with the
external services it needs to reach exist and are reachable"; GitOps
takes it from there, matching the boundary drawn in ADR-003.

Storage RSEs (source/destination) are external to this infrastructure
entirely — partner-operated, not provisioned by this repo.

## Layout

```
deploy/terraform/
├── bootstrap/          # separate root module — creates the GCP Projects,
│                        # networking, CI identities. One apply, run rarely.
│                        # See "Bootstrap" below.
├── environments/
│   ├── staging/         # root module — apply this for staging
│   └── production/      # placeholder, NOT YET VALIDATED — see its main.tf
├── modules/
│   ├── networking/      # VPC, subnet, private services access —
│   │                      # instantiated by bootstrap/, not environments/<env>
│   ├── kubernetes/      # GKE Autopilot + Workload Identity
│   ├── secrets/         # Secret Manager containers + ESO IAM binding
│   └── database/        # Cloud SQL for PostgreSQL, private IP
├── scripts/
│   └── seed-bootstrap-state.sh       # one-time: seed bootstrap/'s own state bucket
└── README.md
```

Each environment is its own root module with its own state. Staging and
production never share state or a GCP project. `bootstrap/` is a third,
separate root module again, with its own state. It operates one level
above `environments/<env>`, creating the projects AND the networking they
run inside of.

## Bootstrap

`environments/<env>` doesn't create its own GCP Project or networking —
it expects both to already exist and takes them as inputs.
`deploy/terraform/bootstrap/` is what creates them: the
`dep-dlm-staging`/`dep-dlm-production` Projects themselves, billing
linkage, baseline API enablement, each environment's VPC/subnet/private-
services-access peering, each environment's `dep-dlm-terraform-ci`
service account, its Workload Identity Federation binding, and its
Terraform state bucket. Run this once per environment (or when rotating
the trusted GitHub repo), by a human holding org-level project-creation
and billing rights — not part of the routine `environments/<env>` apply
loop CI runs through.

**Why networking lives here and not in `environments/<env>`:** VPC/
subnet/peering are foundational plumbing that should change essentially
never once set. `environments/staging` has `deletion_policy = DELETE`
and is expected to be destroyed/recreated routinely for testing —
keeping networking there meant every routine staging recycle dragged the
VPC's `google_service_networking_connection` peering through GCP's
async, frequently-stuck deletion path (`Producer services ... are still
using this connection`, even after Cloud SQL itself was confirmed fully
deleted). Moving networking to this rarely-applied layer doesn't
eliminate that GCP-side fragility, but reduces how often anyone hits it
from "every staging teardown" to "only a full bootstrap teardown" — and
a full bootstrap teardown's recommended path is deleting the project
outright (see Teardown below), which sidesteps the stuck-peering problem
entirely.

**The one genuinely manual step** (everything else below is real
Terraform): `bootstrap/` can't provision the bucket that holds its own
state on its first-ever run, so that one bucket is hand-created first:

```bash
./deploy/terraform/scripts/seed-bootstrap-state.sh \
  --project-id <any existing project you have, with billing already linked>
```

This only needs to happen once, ever, for the lifetime of the org's use
of this repo (see the script's own comments). It does **not** need — and
at this point cannot use — one of the `dep-dlm-<env>` projects, since
`bootstrap/` hasn't created those yet.

Then apply `bootstrap/` itself, authenticated as your own `gcloud`
identity (org-level rights, no service account needed for this rare,
human-run apply):

```bash
cd deploy/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # org_id/folder_id, billing_account_id, github_repo
terraform init \
  -backend-config="bucket=<bucket printed by seed-bootstrap-state.sh>" \
  -backend-config="prefix=bootstrap"
terraform plan
terraform apply -auto-approve
```

Feed its outputs into `environments/<env>` and into each environment's
GitHub Actions workflow:

```bash
terraform output -json project_ids                 # -> environments/<env>/terraform.tfvars' project_id
terraform output -json regions                     # -> environments/<env>/terraform.tfvars' region
terraform output -json network_ids                 # -> environments/<env>/terraform.tfvars' network_id
terraform output -json subnet_ids                  # -> environments/<env>/terraform.tfvars' subnet_id
terraform output -json pods_range_names            # -> environments/<env>/terraform.tfvars' pods_range_name
terraform output -json services_range_names        # -> environments/<env>/terraform.tfvars' services_range_name
terraform output -json state_buckets               # -> environments/<env>'s terraform init -backend-config=bucket=...
terraform output -json terraform_ci_emails         # -> google-github-actions/auth's service_account:
terraform output -json workload_identity_providers # -> google-github-actions/auth's workload_identity_provider:
```

`region` is now the **single source of truth** for an environment's
region, decided once in `bootstrap/`'s `environments` variable — networking
and the GKE cluster must agree on it, so `environments/<env>/variables.tf`
has no independent default for `region` anymore (deliberately, to remove
the drift risk of two places disagreeing).

**Blast radius**: the identity that applies `bootstrap/` holds real
organization-level power (`roles/resourcemanager.projectCreator` on the
org/folder, `roles/billing.user` on the billing account) — meaningfully
more than `dep-dlm-terraform-ci` ever holds, which is scoped to one
project each and (as of this revision) only `roles/compute.networkUser`
rather than `networkAdmin` — it now only ever attaches GKE/Cloud SQL to
an already-existing network, never creates/modifies/deletes networking
itself, so it no longer needs the broader role. Treat who can run
`bootstrap/` applies as a much smaller, more tightly held set of people
than who can run `environments/<env>` applies.

## Authentication (environments)

Both GitHub Actions and local `terraform` runs against `environments/<env>`
authenticate as that environment's `dep-dlm-terraform-ci` service account
(created by `bootstrap/`, see above):

- **CI**: [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
  — short-lived OIDC tokens, no stored secret.
- **Local dev**: your own `gcloud` identity **impersonates** the same
  service account — also no persistent secret. (This org enforces
  `constraints/iam.disableServiceAccountKeyCreation`, so a downloaded
  key isn't an option even if you wanted one; impersonation is the
  better practice regardless.)

Once `bootstrap/` has run for an environment, grant yourself local
impersonation of its `dep-dlm-terraform-ci`:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  $(terraform -chdir=deploy/terraform/bootstrap output -json terraform_ci_emails | jq -r '.staging') \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/iam.serviceAccountTokenCreator" --project="$(terraform -chdir=deploy/terraform/bootstrap output -json project_ids | jq -r '.staging')"

gcloud auth application-default login \
  --impersonate-service-account=$(terraform -chdir=deploy/terraform/bootstrap output -json terraform_ci_emails | jq -r '.staging')
```

After that, `terraform init`/`plan`/`apply` in `environments/<env>` need
no further interaction locally.

## Prerequisites

- `gcloud` and `terraform` CLIs — installed automatically in this repo's
  devcontainer (`.devcontainer/setup.sh`'s `install_gcloud`/
  `install_terraform`).
- `bootstrap/` has been applied for the environment you're targeting (see
  "Bootstrap" above) — this covers project creation, networking, API
  enablement, and state-bucket creation, so there's nothing further to do
  by hand for any of them.
- Completed the local-impersonation grant above.

## Usage — local

```bash
cd deploy/terraform/environments/staging
cp terraform.tfvars.example terraform.tfvars   # all six values from bootstrap's outputs — see the file's own comments
terraform init \
  -backend-config="bucket=$(terraform -chdir=../../bootstrap output -json state_buckets | jq -r '.staging')" \
  -backend-config="prefix=staging"
terraform plan
terraform apply -auto-approve
```

`backend.tf` is a partial config on purpose — bucket/prefix are supplied
via `-backend-config` at init time rather than hardcoded, so the exact
same `terraform init` command works locally and in CI without editing a
tracked file and so it doesn't have to hardcode a bucket name that
`bootstrap/` generates dynamically (project-suffixed, since project IDs
themselves get a random suffix — see `bootstrap/main.tf`).

## Usage — CI

See [`.github/workflows/terraform-staging.yml`](../../.github/workflows/terraform-staging.yml):
`fmt-check` → `plan` (on PRs and pushes) → `apply` (only on push to
`main`, gated behind a GitHub Environment you can add required reviewers
to). Fully non-interactive via WIF — no secrets configured, only
repo/Environment **variables** (not secrets), all sourced from
`bootstrap/`'s outputs once, at setup time.

## Teardown

**For `environments/<env>`** (routine — GKE, Cloud SQL, Secret Manager
only, networking untouched): bucket **deletion** is deliberately not part
of the main apply workflow — it lives in its own manually-triggered
workflow instead:
[`.github/workflows/terraform-teardown.yml`](../../.github/workflows/terraform-teardown.yml).
Trigger it via `workflow_dispatch`, typing the environment name into the
confirmation input (on top of the same GitHub Environment approval gate
as `apply`). It always runs `terraform destroy` against the real
resources first; deleting the state bucket itself is a separate,
default-off checkbox on the same run.

**For `bootstrap/`** (rare — the project itself, including its
networking): prefer deleting the project outright over a graceful
`terraform destroy`:

```bash
gcloud projects delete <project-id> --quiet
```

This is authoritative and unconditional — it tears down the VPC peering
(no async "producer services still using this connection" wait, since
GCP doesn't attempt a graceful per-resource deletion at all here), Cloud
SQL, GKE, the state bucket regardless of `force_destroy`, service
accounts, and WIF pools, in one shot. The project enters a 30-day
soft-delete window (recoverable via `gcloud projects undelete
<project-id>`; billing stops immediately). Afterward, reconcile
`bootstrap/`'s own state, since it still references resources that no
longer exist:

```bash
cd deploy/terraform/bootstrap
terraform state rm $(terraform state list)
```

`state rm` only forgets resources locally — it doesn't call the GCP API,
so it won't hit the same stuck-resource problems `destroy` can. Since
project IDs get a fresh random suffix on every `bootstrap` apply anyway,
there's nothing worth preserving in state after a project deletion — a
full wipe is simpler than surgically removing individual entries.
`environments/<env>` needs no separate cleanup: its state lived inside
the bucket that just got deleted along with the project.

## After `apply`

Complete the Workload Identity binding on the cluster side (Terraform
creates the GCP-side IAM binding; the k8s ServiceAccount annotation is a
GitOps/cluster-side concern):

```bash
kubectl annotate serviceaccount external-secrets \
  -n external-secrets \
  iam.gke.io/gcp-service-account=$(terraform output -raw eso_service_account_email)
```

Fetch cluster credentials:

```bash
gcloud container clusters get-credentials $(terraform output -raw cluster_name) \
  --region=<region> --project=<project_id>
```

Then populate the (currently empty) Secret Manager secrets with real
values — out-of-band, per the same rule the sandbox already follows:
sensitive values are never committed to this repo.

## What's genuinely not decided yet

See ADR-003's Open Points — region selection, procurement/credit
confirmation and data-protection sign-off are all still open. This
scaffold is safe to `plan` against for review purposes but treat
`apply` as blocked on those confirmations for anything beyond your own
throwaway testing.
