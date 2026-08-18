# dep-dlm-testbed

[![Lint](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/lint.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/lint.yml)
[![EGI Check-In (dev)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/egi-dev.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/egi-dev.yml)
[![LS AAI (dev)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/ls-aai-dev.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/ls-aai-dev.yml)
[![Local](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/local.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/local.yml)
[![Local (full)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/local.full.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/local.full.yml)
[![GitOps (ArgoCD)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/gitops-argocd.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/gitops-argocd.yml)
[![GitOps (Flux)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/gitops-flux.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/gitops-flux.yml)
[![GitOps install test (staging)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/gitops-install-test-staging.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/gitops-install-test-staging.yml)
[![Terraform apply (staging)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/terraform-apply-staging.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/terraform-apply-staging.yml)
[![Terraform apply (production)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/terraform-apply-production.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/terraform-apply-production.yml)
[![Terraform destroy (staging)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/terraform-destroy-staging.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/terraform-destroy-staging.yml)
[![Terraform destroy (production)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/terraform-destroy-production.yml/badge.svg)](https://github.com/RI-SCALE/dep-dlm-testbed/actions/workflows/terraform-destroy-production.yml)

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

export TOKEN_MODE=managed # FTS token mode. Viable options: [managed, unmanaged]
export DAEMON_MODE=direct # Daemon mode. Viable options: [direct, daemons]
export RUNTIME=k8s

# 2. Install the Helm chart
make start

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

# Substitute your credentials into idpsecrets.json
sed -i \
  -e "s|<valid client id>|$OIDC_CLIENT_ID|g" \
  -e "s|<valid client secret>|$OIDC_CLIENT_SECRET|g" \
  shared/config/rucio/egi-dev/idpsecrets.json

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

# Substitute your credentials into idpsecrets.json
sed -i \
  -e "s|<valid client id>|$OIDC_CLIENT_ID|g" \
  -e "s|<valid client secret>|$OIDC_CLIENT_SECRET|g" \
  shared/config/rucio/ls-aai-dev/idpsecrets.json

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

> **NOTE:** the LS AAI test-phase environment requires the authenticating
> user to be a member of the `Life Science Community - Test Environment`
> VO before login succeeds — if `rucio whoami` (or a browser login against
> `login.aai.lifescience-ri.eu`) returns an access-denied page listing
> required organizational units, register at
> `https://signup.aai.lifescience-ri.eu/fed/registrar?vo=lifescience_test`
> with the same identity first; propagation can take a few minutes.

> **NOTE:** **Don't commit the substituted `idpsecrets.json`.** The `sed` step above
> writes real credentials into a git-tracked file. Before committing
> anything else, check `git status shared/config/rucio/<profile>/idpsecrets.json`
> and revert it (`git checkout -- shared/config/rucio/<profile>/idpsecrets.json`)
> once you're done testing.

## Make Targets

```bash
dep-dlm-testbed

  RUNTIME    = compose    (compose | k8s)
  TOKEN_MODE = unmanaged (managed | unmanaged)
  DAEMON_MODE = direct (direct | daemons)
  GITOPS_ENV = sandbox (sandbox | staging | production)
  K8S_NAMESPACE = dep-dlm-sandbox
  SCOPE_PROFILE = local (local | <profile>)
  TF_ENV = staging

Usage:
  make <target> [RUNTIME=compose|k8s] [TOKEN_MODE=managed|unmanaged] [DAEMON_MODE=direct|daemons] [SCOPE_PROFILE=local|<profile, e.g. egi-dev, ls-aai-dev>] [SERVICES="svc1 svc2"]


Help
  help                 Show this help

Setup
  certs                Generate CA and host certificates
  init                 Init testbed accounts, RSEs, OIDC seed

IdP token verification
  verify-idp-token     Verify OIDC token flow for SCOPE_PROFILE. Needs OIDC_CLIENT_SECRET.

Lifecycle
  start                Start the stack
  stop                 Stop the stack, remove volumes / PVCs
  restart              Tear down and start again
  rebuild              Rebuild services (SERVICES="fts teapot")
  rebuild-clean        Rebuild from scratch, no cache
  ps                   Show running services / pods
  logs                 Tail logs (SERVICES="..." for a subset)

GitOps
  argocd-install       Install ArgoCD, bootstrap GITOPS_ENV
  argocd-uninstall     Remove ArgoCD apps and resources
  flux-install         Install Flux, bootstrap GITOPS_ENV
  flux-uninstall       Remove Flux Kustomizations and controllers

Helm-only
  helm-lint            Lint the umbrella chart
  helm-template        Render manifests without installing

Tests
  test-rucio-transfers Rucio E2E transfer test
  test-copernicus-transfers Rucio E2E transfer test with Copernicus data
  test-rucio-deletion  Rucio E2E deletion test
  probe-teapot         Teapot WebDAV probe with OIDC tokens

Terraform
  tf-fmt               Format Terraform files
  tf-fmt-check         Check Terraform formatting
  tf-init              Init Terraform for TF_ENV (bucket resolved from bootstrap output)
  tf-validate          Validate TF_ENV config (run tf-init first)
  tf-lint              Lint every Terraform root module
  tf-docs              Generate Terraform reference docs. Needs terraform-docs.
  tf-plan              Plan Terraform changes for TF_ENV
  tf-apply             Apply TF_ENV. Uses saved plan if present. AUTO_APPROVE=1 for CI.
  tf-destroy           Destroy TF_ENV (GKE, Cloud SQL, Secret Manager, not networking). AUTO_APPROVE=1 for CI.
  tf-output            Show Terraform outputs for TF_ENV
  tf-kubeconfig        Fetch kubectl credentials for TF_ENV's cluster
  tf-smoke-test        Run smoke tests against TF_ENV. Run tf-kubeconfig first.
  tf-import            Import an existing GCP resource into TF_ENV's state. Usage: make tf-import RESOURCE=module.rucio_database.google_sql_database_instance.this ID=dep-dlm-staging-e52e0d90/dep-dlm-staging-pg
  tf-force-unlock      Force-unlock TF_ENV's state after a stale/abandoned lock. Usage: make tf-force-unlock LOCK_ID=<id from the lock error>. Confirm nothing else is actually running againstTF_ENV first — see the Lock Info 'Who' field.

Cleanup
  clean                Remove certs, volumes, Terraform/Python/Helm artifacts
```

## Documentation

See [docs](./docs/)
