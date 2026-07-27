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

## Authentication

Both GitHub Actions and local `terraform` runs authenticate as the same
GCP service account (`dep-dlm-terraform-ci`):

- **CI**: [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
  — short-lived OIDC tokens, no stored secret.
- **Local dev**: your own `gcloud` identity **impersonates** the same
  service account — also no persistent secret. (This org enforces
  `constraints/iam.disableServiceAccountKeyCreation`, so a downloaded
  key isn't an option even if you wanted one; impersonation is the
  better practice regardless.)

### One-time setup

Run once, by a human with IAM admin rights on the target project:

```bash
gcloud services enable compute.googleapis.com --project=<your-gcp-project-id>

./deploy/terraform/scripts/setup-workload-identity.sh \
  --project-id <your-gcp-project-id> \
  --github-repo <org>/<repo> \
  --grant-local-impersonation
```

The script creates the service account, grants it every role
`deploy/terraform`'s modules need, sets up the WIF pool/provider, and
prints the CI values to paste into your GitHub Actions workflow. See the
script's own comments for what each step does and why it's idempotent —
safe to re-run any time (e.g. to add a second GitHub repo).

With `--grant-local-impersonation`, it also prints one command you run
yourself (interactive, one browser prompt — can't be scripted):

```bash
gcloud auth application-default login \
  --impersonate-service-account=dep-dlm-terraform-ci@<project-id>.iam.gserviceaccount.com
```

After that, `terraform init`/`plan`/`apply` need no further interaction
locally.

## Prerequisites

- `gcloud` and `terraform` CLIs — installed automatically in this repo's
  devcontainer (`.devcontainer/setup.sh`'s `install_gcloud`/
  `install_terraform`).
- Completed the one-time auth setup above.
- APIs enabled on the target project:
  ```bash
  gcloud services enable container.googleapis.com secretmanager.googleapis.com \
    sqladmin.googleapis.com servicenetworking.googleapis.com \
    compute.googleapis.com iam.googleapis.com iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com --project=<project_id>
  ```
- A GCS bucket for remote state. CI creates this idempotently on every
  run (`prepare-backend` in `terraform-staging.yml`) — nothing to do
  for CI. For local-only use before CI has run once:
  ```bash
  gcloud storage buckets create gs://<your-state-bucket> \
    --project=<project_id> --location=EU --uniform-bucket-level-access
  ```
  **Bucket names are global across all of GCP**, not scoped to your
  project — pick something unique, e.g. suffixed with your project ID
  (see Troubleshooting).

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
environment down for good, not for routine cleanup.

If you'd rather delete the whole project instead of fighting stuck
Google-side resource cleanup (see Troubleshooting), that's often faster
for a disposable trial/test project — trial credits carry over to a new
project under the same billing account.

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

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `setup-workload-identity.sh` fails with `NOT_FOUND: Unknown service account` on the default compute SA | Brand-new project — `compute.googleapis.com` hasn't provisioned the default compute SA yet | `gcloud services enable compute.googleapis.com --project=<id>`, wait ~1-2 min, retry |
| `terraform init` fails with `403: Permission 'iam.serviceAccounts.getAccessToken' denied` | `iamcredentials.googleapis.com` not enabled (separate from the general `iam` API) | `gcloud services enable iamcredentials.googleapis.com --project=<id>`; if it persists after enabling, wait 1-2 min (IAM propagation lag) and retry. Sanity-check independently: `gcloud auth print-access-token --impersonate-service-account=<sa-email>` |
| `apply` fails with `SERVICE_DISABLED` / `Cloud Resource Manager API has not been used in project ...` | `cloudresourcemanager.googleapis.com` not enabled — needed by `google_service_networking_connection` to resolve project metadata | `gcloud services enable cloudresourcemanager.googleapis.com --project=<id>` |
| GKE cluster creation fails: `Error 400: The user does not have access to service account "...-compute@developer.gserviceaccount.com"` | CI/local identity lacks `iam.serviceAccountUser` on the project's default compute SA (which Autopilot uses for node VMs) | Already granted automatically by `setup-workload-identity.sh` — if you're hitting this, re-run the script (idempotent) |
| `apply` fails creating `google_service_networking_connection`: `Error code 16 ... invalid authentication credentials` | Known, transient flakiness in this resource's long-running-operation polling — not a real permission gap | Just re-run `terraform apply`; resolves on retry the large majority of the time |
| `destroy` fails deleting `google_service_networking_connection`: `Producer services ... are still using this connection` (`FLOW_SN_DC_RESOURCE_PREVENTING_DELETE_CONNECTION`) | Google-side reconciliation lag between Cloud SQL instance deletion completing and the servicenetworking backend releasing the peering — can take well over the usual few minutes | Confirm the SQL instance is really gone (`gcloud sql instances list`), then just wait and retry `tf-destroy`. For a disposable project, deleting the whole project (`gcloud projects delete <id>`) sidesteps this entirely and is often faster |
| `gcloud storage buckets create` fails: `409: The requested bucket name is not available` | GCS bucket names are **globally unique across all of GCP**, not project-scoped — likely colliding with a bucket from a previous (possibly deleted-but-not-yet-released) project | Pick a bucket name that embeds your project ID, e.g. `dep-dlm-tfstate-staging-<project-id>` |

## What's genuinely not decided yet

See ADR-003's Open Points — region selection, procurement/credit
confirmation, and data-protection sign-off are all still open. This
scaffold is safe to `plan` against for review purposes but treat
`apply` as blocked on those confirmations for anything beyond your own
throwaway testing.
