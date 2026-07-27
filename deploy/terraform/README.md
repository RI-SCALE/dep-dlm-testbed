# deploy/terraform

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
deploy/terraform/
├── environments/
│   ├── staging/       # root module — apply this for staging
│   └── production/     # placeholder, NOT YET VALIDATED — see its main.tf
├── modules/
│   ├── networking/     # VPC, subnet, private services access
│   ├── kubernetes/     # GKE Autopilot + Workload Identity
│   ├── secrets/        # Secret Manager containers + ESO IAM binding
│   └── database/       # Cloud SQL for PostgreSQL, private IP
├── scripts/
│   └── setup-workload-identity.sh   # one-time GCP auth bootstrap — see below
└── README.md
```

Each environment is its own root module with its own state — staging and
production never share state or a GCP project.

## Authentication — one identity for CI and local dev

Both GitHub Actions and local `terraform` runs authenticate as the same
GCP service account (`dep-dlm-terraform-ci`), via two different
mechanisms:

- **CI**: [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
  — GitHub Actions exchanges a short-lived OIDC token for GCP credentials.
  No secret is stored anywhere.
- **Local dev**: your own `gcloud` identity **impersonates** the same
  service account. Also no persistent secret — this project's GCP org
  enforces `constraints/iam.disableServiceAccountKeyCreation`, so a
  downloaded service-account-key file isn't an option here even if you
  wanted one; impersonation is both the only path and the better
  practice regardless.

### One-time setup (run once, by a human with IAM admin rights)

```bash
./deploy/terraform/scripts/setup-workload-identity.sh \
  --project-id <your-gcp-project-id> \
  --github-repo <org>/<repo> \
  --grant-local-impersonation
```

This creates the service account, grants it the roles the four modules
need — plus project-level `roles/storage.admin`, so it can create and
manage its own Terraform state bucket idempotently in CI rather than
requiring a human to pre-create it (see Prerequisites below) — sets up
the WIF pool/provider scoped to your GitHub repo (see the script's own
comments for exactly what each step does and why it's idempotent), and
— with `--grant-local-impersonation` — grants your current `gcloud`
account `roles/iam.serviceAccountTokenCreator` on that service account.

The script prints the CI values to paste into your GitHub Actions
workflow (`workload_identity_provider` / `service_account`), and, for
local dev, the one command it can't run for you because it's an
interactive consent step:

```bash
gcloud auth application-default login \
  --impersonate-service-account=dep-dlm-terraform-ci@<project-id>.iam.gserviceaccount.com
```

Run that once. After it, `terraform init`/`plan`/`apply` need no further
interaction locally — ADC refreshes tokens transparently, and you're
authenticating as the identical principal CI uses.

**Known gotcha**: impersonation needs the **IAM Service Account
Credentials API** enabled — a different API than the general `iam`
one already listed under Prerequisites below, easy to miss:
```bash
gcloud services enable iamcredentials.googleapis.com --project=<project-id>
```
Without it, `terraform init` fails with `403: Permission
'iam.serviceAccounts.getAccessToken' denied`, even though the IAM role
binding itself is correct. If you still see that error after enabling
this API, wait 1-2 minutes (IAM propagation lag is real and has bitten
this exact setup more than once) and retry. Sanity-check independently
of Terraform with:
```bash
gcloud auth print-access-token --impersonate-service-account=dep-dlm-terraform-ci@<project-id>.iam.gserviceaccount.com
```
If that prints a token, impersonation works and Terraform will too.

## Prerequisites

- `gcloud` and `terraform` CLIs — installed automatically in this repo's
  devcontainer (`.devcontainer/setup.sh`'s `install_gcloud`/
  `install_terraform`).
- Completed the one-time auth setup above.
- APIs enabled on the target project:
  `container.googleapis.com`, `secretmanager.googleapis.com`,
  `sqladmin.googleapis.com`, `servicenetworking.googleapis.com`,
  `compute.googleapis.com`, `iam.googleapis.com`,
  `iamcredentials.googleapis.com` (the last one specifically for
  impersonation — see gotcha above).
  ```bash
  gcloud services enable container.googleapis.com secretmanager.googleapis.com \
    sqladmin.googleapis.com servicenetworking.googleapis.com \
    compute.googleapis.com iam.googleapis.com iamcredentials.googleapis.com \
    --project=<project_id>
  ```
- A GCS bucket for remote state. As of `prepare-backend` in
  [`terraform-staging.yml`](../../.github/workflows/terraform-staging.yml),
  CI creates this idempotently on every run — nothing to do here for CI.
  For local-only use before CI has run once, create it yourself:
  ```bash
  gcloud storage buckets create gs://<your-state-bucket> \
    --project=<project_id> --location=EU --uniform-bucket-level-access
  ```
  No separate IAM grant needed on the bucket itself anymore —
  `setup-workload-identity.sh` now grants the CI service account
  project-level `roles/storage.admin` (see Authentication above), which
  covers bucket creation and object access together. (Earlier revisions
  of this doc had you grant `storage.objectAdmin` on the bucket by hand;
  that manual step is superseded by this broader role.)

**Known gotcha**: `google_service_networking_connection` (used for Cloud
SQL's private IP peering, `modules/networking`) can fail mid-apply with:
```
Error waiting for Create Service Networking Connection: Error code 16,
message: Request had invalid authentication credentials. Expected OAuth 2
access token, login cookie or other valid authentication credential.
```
This is a known, transient flakiness in this specific resource's
long-running-operation polling — not a real permission or config gap (if
it were, you'd see a 403/`accessNotConfigured` like the Cloud Resource
Manager API gap above, not this generic auth-token complaint). Simply
re-running `terraform apply` resolves it in the large majority of cases,
with no other changes needed.

## Usage — local

```bash
cd deploy/terraform/environments/staging
cp terraform.tfvars.example terraform.tfvars   # fill in project_id at minimum
terraform init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="prefix=staging"
terraform plan
terraform apply
```

`backend.tf` is a partial config on purpose — bucket/prefix are supplied
via `-backend-config` at init time rather than hardcoded, so the exact
same `terraform init` command works locally and in CI without editing a
tracked file.

## Usage — CI

See [`.github/workflows/terraform-staging.yml`](../../.github/workflows/terraform-staging.yml):
`fmt-check` → `prepare-backend` (idempotent state bucket creation) →
`plan` (on PRs and pushes) → `apply` (only on push to `main`, gated
behind a GitHub Environment you can add required reviewers to). Fully
non-interactive via WIF — no secrets configured, only three repo
**variables** (not secrets): `TF_STATE_BUCKET`, `GCP_PROJECT_ID`,
`GCP_REGION`.

## Teardown

Bucket **deletion** is deliberately not part of the main workflow —
running it automatically before every plan/apply would risk deleting
Terraform's own state history and orphaning real GCP resources with no
record of them. It lives in its own manually-triggered workflow instead:
[`.github/workflows/terraform-teardown.yml`](../../.github/workflows/terraform-teardown.yml).

Trigger it via `workflow_dispatch`, typing `staging` into the
confirmation input (on top of the same GitHub Environment approval gate
as `apply`). It always runs `terraform destroy` against the real
resources first; deleting the state bucket itself is a separate,
default-off checkbox on the same run — only use it when tearing the
environment down for good, not for routine cleanup, since it leaves
Terraform with no memory of this environment afterward.

## After `apply`

Complete the Workload Identity binding on the cluster side (Terraform
creates the GCP-side IAM binding; the k8s ServiceAccount annotation is a
GitOps/cluster-side concern):

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
