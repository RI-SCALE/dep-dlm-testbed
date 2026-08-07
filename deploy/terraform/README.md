# deploy/terraform

Terraform IaC for DEP DLM staging/production infrastructure on GCP. See
[ADR-003](../../docs/adrs/adr-003-staging-cloud-provider.md) for why GCP,
[`docs/diagrams/staging-gcp.py`](../../docs/diagrams/staging-gcp.py) for
the deployment view.

**Provisions**: `dep-dlm-staging`/`dep-dlm-production` GCP Projects +
VPC/subnet/private-services-access networking (`bootstrap/`); GKE
Autopilot + Workload Identity binding, Secret Manager containers (values
rendered from `.tftpl` templates, not out-of-band), Cloud SQL for
Postgres (`rucio`) and MySQL (`fts`), both private-IP (`environments/<env>`).

**Does NOT provision**: Rucio, FTS, ESO, or any in-cluster workload —
those are GitOps-managed (Argo CD/Flux), matching ADR-003's boundary.
Storage RSEs are external/partner-operated, not provisioned here.

## Layout

```
deploy/terraform/
├── bootstrap/                  # Projects, networking, CI identities. Rare, human-run.
├── environments/
│   ├── staging/                 # apply this for staging
│   └── production/              # placeholder — NOT YET VALIDATED
├── modules/
│   ├── networking/               # instantiated by bootstrap/, not environments/<env>
│   ├── kubernetes/               # GKE Autopilot + Workload Identity
│   ├── secrets/                  # Secret Manager + rendered rucio.cfg/fts3config/etc.
│   ├── database-postgres/        # rucio
│   └── database-mysql/           # fts
├── scripts/
│   ├── seed-bootstrap-state.sh   # one-time: seed bootstrap's own state bucket
│   └── resolve-tf-env.sh         # resolves project/network/etc. from bootstrap's output
├── tests/
│   └── test_deployed_infra.py    # `make tf-smoke-test` — run after apply
└── README.md
```

Staging, production, and `bootstrap` are three fully separate root
modules with three separate states — never shared.

## Bootstrap

`environments/<env>` doesn't create its own Project or networking — it
takes both as inputs. `bootstrap/` creates them: the Projects, billing
linkage, API enablement, each environment's networking, `dep-dlm-terraform-ci`
service account + WIF binding, and state bucket. Run once per
environment by a human with org-level project-creation/billing rights —
not part of the routine CI apply loop.

**Why networking lives here, not in `environments/<env>`:** staging is
destroyed/recreated routinely (`deletion_policy = DELETE`), and every
recycle used to drag the VPC peering through GCP's async, frequently-stuck
deletion path. Moving networking to this rarely-applied layer doesn't
fix that fragility, but reduces how often anyone hits it to "only a full
bootstrap teardown" — whose recommended path (below) sidesteps it
entirely.

**One manual step**, everything else is real Terraform — `bootstrap/`
can't provision the bucket holding its own state on first run:

```bash
./deploy/terraform/scripts/seed-bootstrap-state.sh \
  --project-id <any existing project with billing already linked>
```

Once, ever, for the org's lifetime with this repo. Then, as your own
`gcloud` identity (org-level rights, no SA needed for this rare apply):

```bash
cd deploy/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # org_id/folder_id, billing_account_id, github_repo
terraform init -backend-config="bucket=<from seed script>" -backend-config="prefix=bootstrap"
terraform apply -auto-approve
```

`region` is decided once here, in `bootstrap`'s `environments` variable —
`environments/<env>` has no independent default, so networking and the
GKE cluster can't drift apart on it.

**Blast radius**: whoever applies `bootstrap/` holds real org-level
power (`projectCreator`, `billing.user`) — a much smaller, more tightly
held group than who runs `environments/<env>` applies, which are scoped
to one project each with `compute.networkUser` (attach-only, no
create/modify/delete on networking).

## Authentication

- **CI**: Workload Identity Federation — short-lived OIDC tokens, no
  stored secret. `OIDC_CLIENT_SECRET` is the one real GitHub Environment
  *secret* required (an external IdP client secret, not GCP-related);
  everything else is Environment *variables*, sourced from `bootstrap`'s
  outputs.
- **Local**: plain `gcloud auth application-default login` as *yourself*
  — **no impersonation**. Every `make tf-*` target's `resolve-tf-env.sh`
  step reads `bootstrap`'s state as whoever's currently authenticated,
  and ADC only holds one identity per session — impersonating
  `dep-dlm-terraform-ci` breaks that read (a 403, not a vague error) and
  gains nothing, since the actual `terraform` call in the same command
  then also runs as you. Your own account needs sufficient IAM on the
  target project for this to work in practice.

## Usage

Everything goes through `make` (`Makefile` at repo root) — it wraps
`resolve-tf-env.sh`'s auto-resolution of project/network/state-bucket
from `bootstrap`'s output, so nothing here is hardcoded per-environment:

```bash
make tf-init TF_ENV=staging
make tf-validate TF_ENV=staging      # needs tf-init; against the real backend
make tf-lint TF_ENV=staging          # tflint, credential-free
make tf-plan TF_ENV=staging          # needs SCOPE_PROFILE=egi-dev|ls-aai-dev + OIDC_CLIENT_SECRET
make tf-apply TF_ENV=staging
make tf-kubeconfig TF_ENV=staging
make tf-smoke-test TF_ENV=staging    # secrets/DB/kubeconfig checks against the live deploy
```

`AUTO_APPROVE=1` for non-interactive apply/destroy (CI always passes
this; local defaults to an interactive prompt).

CI: see [`_terraform-apply.yml`](../../.github/workflows/_terraform-apply.yml)
— `plan` → `apply` → `smoke-test` (own job, separate
status from `apply`) → `cleanup` (deletes the certs/plan artifacts).
Thin per-environment callers: `terraform-apply-staging.yml` (push+PR+
dispatch) and `terraform-apply-production.yml` (dispatch only).

## Teardown

**`environments/<env>`**: `make tf-destroy TF_ENV=staging` locally, or
[`terraform-destroy-staging.yml`](../../.github/workflows/terraform-destroy-staging.yml)/
`-production.yml` in CI (`workflow_dispatch`, type the environment name
to confirm, same reviewer gate as apply). State bucket itself is
untouched — that's `bootstrap`'s to own.

**`bootstrap/`** (rare): delete the project outright rather than a
graceful `destroy` — sidesteps the async peering-deletion problem
entirely:

```bash
gcloud projects delete <project-id> --quiet   # 30-day soft-delete, recoverable via `undelete`
cd deploy/terraform/bootstrap && terraform state rm $(terraform state list)
```

`state rm` only forgets locally, no GCP API calls — safe. Project IDs
get a fresh random suffix on every `bootstrap` apply anyway, so nothing
in state is worth preserving after deletion. `environments/<env>` needs
no separate cleanup — its state lived in the bucket that just went with
the project.

## After `apply`

```bash
kubectl annotate serviceaccount external-secrets -n external-secrets \
  iam.gke.io/gcp-service-account=$(terraform output -raw eso_service_account_email)
```

(Terraform creates the GCP-side IAM binding; this k8s-side annotation is
GitOps/cluster-side, not Terraform's job.)

## Not yet decided

See ADR-003's Open Points — region, procurement/credit, data-protection
sign-off.
