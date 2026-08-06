# dep-dlm-testbed

Self-contained DLM testbed with Rucio, FTS3, XRootD, Teapot WebDAV and Keycloak for validating end-to-end OIDC token orchestration, TPC transfers, dataset operations and replication rule lifecycles across Docker Compose and Kubernetes (`amd64`/`arm64`), with GitOps-based deployment (ArgoCD or Flux) across sandbox, staging and production environments.

The testbed supports both managed and unmanaged token flows and integrates against external OIDC providers beyond the bundled Keycloak, validated end-to-end against EGI Check-In and LS AAI / Perun, as well as external storage backends including S3 (e.g. Copernicus Data Space). It can be further extended to validate data discovery, popularity and preparation services end-to-end.

The testbed also applies minimal source patches to upstream components (e.g. Rucio, FTS3, gfal2, davix, Teapot) to validate features not yet upstream, making it a realistic environment for prototyping and testing changes end-to-end before they land upstream. Patches, their rationale and the surrounding architectural decisions are documented in [docs/patches.md](./docs/patches.md), [docs/adrs/](./docs/adrs/) and [docs/design/](./docs/design/).

## Backlog

Tracked future improvements and planned work items are maintained in [BACKLOG.md](./BACKLOG.md).

## Quick start

The recommended setup is to use the provided [dev container](./.devcontainer/devcontainer.json). This requires:
- [Docker](https://docs.docker.com/engine/install/) installed on your system
- An IDE with dev container support (e.g. [VS Code with the devcontainer plugin](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers))

### Docker Compose

```bash
# 1. Generate certificates
make certs

export TOKEN_MODE=managed # FTS token mode. Viable options: [managed, unmanaged]
export DAEMON_MODE=direct # Daemon mode. Viable options: [direct, daemons]
export RUNTIME=compose

# 2. Start the stack
make start

# 3. Initialize DEP DLM testbed
make init

# 4. Run tests
make test-rucio-transfers
make test-rucio-deletion

# 5. Stop the stack and remove volumes
make stop
```

### Kubernetes

```bash
# 1. Generate certificates
make certs

# 2. Install the Helm chart
make start

export TOKEN_MODE=managed # FTS token mode. Viable options: [managed, unmanaged]
export DAEMON_MODE=direct # Daemon mode. Viable options: [direct, daemons]
export RUNTIME=k8s

# 3. Initialize DEP DLM testbed
make init

# 4. Run tests
make test-rucio-transfers
make test-rucio-deletion

# 5. Stop the stack and remove volumes
make stop
```

### Copernicus S3 transfers

`test-copernicus-transfers` validates an S3 source (Copernicus Data Space) →
WebDAV destination streamed copy. It requires `S3_ACCESS_KEY`/`S3_SECRET_KEY`
for the Copernicus endpoint and self-skips at init when they are unset.
Refer to the following [link](https://documentation.dataspace.copernicus.eu/APIs/S3.html)
for instructions on setting up an S3 account and generating the credentials required
to access Copernicus Data Space EO Data.

Export them **before `make init` and the test**. Init creates the S3 RSE and
FTS cloud-storage rows from these credentials and the test reads them back:

```bash
export S3_ACCESS_KEY=... S3_SECRET_KEY=...
make init
make test-copernicus-transfers
```

### EGI Check-In (scope profile: egi-dev)

Copy `envs/egi-dev.env.example` to `envs/egi-dev.env`, fill in your EGI
Check-In `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`, then:

```bash
source envs/egi-dev.env
export TOKEN_MODE=unmanaged #  managed mode isn't viable against egi-dev — EGI doesn't honor resource= on token-exchange; see runbook 02
export DAEMON_MODE=direct
export RUNTIME=k8s
make start
make init

# Map a valid user identity within EGI-Dev to the seeded rucio account
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-admin identity add --type OIDC \
    --id "SUB=aa886829a0a894933008498cfe62264d899422f55b408560a259311776f0e519@egi.eu, ISS=https://aai-dev.egi.eu/auth/realms/egi" --account randomaccount --email marvin.gajek@cern.ch

make test-rucio-transfers
```

### LS AAI (scope profile: ls-aai-dev)

Copy `envs/ls-aai-dev.env.example` to `envs/ls-aai-dev.env`, fill in your LS AAI
`OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`, then:

```bash
source envs/ls-aai-dev.env
export TOKEN_MODE=managed # or unmanaged
export DAEMON_MODE=direct
export RUNTIME=k8s
make start
make init

# Map a valid user identity within LS AAI to the seeded rucio account
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-admin identity add --type OIDC \
    --id "SUB=28f7bc3a2d32a4a722f6eb24f77f7fbe42eb6471@lifescience-ri.eu, ISS=https://login.aai.lifescience-ri.eu/oidc/" --account randomaccount --email marvin.gajek@cern.ch

make test-rucio-transfers
```

> **Note:** the LS AAI test-phase environment requires the authenticating
> user to be a member of the `Life Science Community - Test Environment`
> VO before login succeeds — if `rucio whoami` (or a browser login against
> `login.aai.lifescience-ri.eu`) returns an access-denied page listing
> required organizational units, register at
> `https://signup.aai.lifescience-ri.eu/fed/registrar?vo=lifescience_test`
> with the same identity first; propagation can take a few minutes.

## Make Targets

```bash
dep-dlm-testbed

  RUNTIME    = compose    (compose | k8s)
  TOKEN_MODE = managed (managed | unmanaged)
  DAEMON_MODE = direct (direct | daemons)
  GITOPS_ENV = sandbox (sandbox | staging | production)
  K8S_NAMESPACE = dep-dlm-sandbox
  SCOPE_PROFILE = local (local | <profile>)
  TF_ENV = staging

Usage:
  make <target> [RUNTIME=compose|k8s] [TOKEN_MODE=managed|unmanaged] [DAEMON_MODE=direct|daemons] [SCOPE_PROFILE=local|<profile, e.g. egi-dev, ls-aai-dev>] [SERVICES="svc1 svc2"]


Help
  help                 Show this help (default target)

Setup
  certs                Generate certificates (CA, host certs)
  init                 Initialize the testbed (accounts, RSEs, OIDC seed)

IdP token verification
  verify-idp-token     Verify client_credentials/resource=/token-exchange for SCOPE_PROFILE (egi-dev|lsaai-dev). Requires OIDC_CLIENT_SECRET.

Lifecycle
  start                Start the stack
  stop                 Stop the stack and remove volumes / PVCs
  restart              Tear down and start again
  rebuild              Rebuild one or more services: make rebuild SERVICES="fts teapot"  (compose: rebuild image; k8s: helm upgrade)
  rebuild-clean        Rebuild from scratch (no cache) — use when a forked git dependency (davix/gfal2/fts) moved
  ps                   Show running services / pods
  logs                 Tail logs (all services, or pass SERVICES="..." for a subset)

GitOps
  argocd-install       Install ArgoCD + bootstrap the chosen env (GITOPS_ENV=sandbox|staging|production, TOKEN_MODE=managed|unmanaged, SCOPE_PROFILE=local|<profile>)
  argocd-uninstall     Uninstall ArgoCD applications and ArgoCDresources
  flux-install         Install Flux + bootstrap the chosen env (GITOPS_ENV=sandbox|staging|production, TOKEN_MODE=managed|unmanaged, SCOPE_PROFILE=local|<profile>)
  flux-uninstall       Uninstall Flux Kustomizations, Flux resources (GitRepository) and Flux controllers

Helm-only
  helm-lint            Lint the umbrella chart
  helm-template        Render manifests without installing

Tests
  test-rucio-transfers Rucio E2E TPC transfer test
  test-copernicus-transfers Rucio E2E TPC transfer test with Copernicus Sentinel data (WebDAV + OIDC)
  test-rucio-deletion  Rucio E2E deletion test
  probe-teapot         Teapot WebDAV probe with OIDC tokens

Terraform
  tf-fmt               Auto-format Terraform files under deploy/terraform
  tf-fmt-check         Check Terraform formatting under deploy/terraform
  tf-init              Init Terraform for TF_ENV against its GCS state bucket (bucket auto-resolved from bootstrap output unless TF_STATE_BUCKET is already set)
  tf-validate          Validate the TF_ENV config (run tf-init first)
  tf-docs              Generate/update per-module Terraform reference docs (injected into each directory's own README.md) — requires terraform-docs
  tf-plan              Plan Terraform changes for TF_ENV, savedto $(TF_DIR)/tfplan
  tf-apply             Apply TF_ENV — uses a saved tf-plan if present, otherwise plans inline. AUTO_APPROVE=1 for CI.
  tf-destroy           Destroy TF_ENV's infrastructure (GKE, Cloud SQL, Secret Manager — networking untouched, it's bootstrap-owned). AUTO_APPROVE=1 for CI, interactive otherwise.
  tf-output            Show Terraform outputs for TF_ENV
  tf-kubeconfig        Fetch kubectl credentials for TF_ENV's GKE cluster (gcloud + gke-gcloud-auth-plugin required)
  tf-smoke-test        Run post-deploy smoke tests (secrets/DB/kubeconfig) against TF_ENV — run tf-kubeconfig first

Cleanup
  clean                Remove generated certs and compose volumes (keeps CA)
```

## Documentation

See [docs](./docs/)
