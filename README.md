# dep-dlm-testbed

Self-contained DLM testbed with Rucio, FTS3, XRootD, Teapot WebDAV and Keycloak for validating end-to-end OIDC token orchestration, TPC transfers, dataset operations and replication rule lifecycles across Docker Compose and Kubernetes (`amd64`/`arm64`), with GitOps-based deployment (ArgoCD or Flux) across sandbox, staging and production environments.

The testbed supports both managed and unmanaged token flows and integrates against external OIDC providers beyond the bundled Keycloak, validated end-to-end against EGI Check-In, with LS AAI / Perun integration in progress, as well as external storage backends including S3 (e.g. Copernicus Data Space). It can be further extended to validate data discovery, popularity and preparation services end-to-end.

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
export TOKEN_MODE=unmanaged
export DAEMON_MODE=direct
export RUNTIME=k8s
make start
make init

# Map a valid user identity within EGI-Dev to the seeded rucio account trough `make init`
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-admin identity add --type OIDC \
    --id "SUB=aa886829a0a894933008498cfe62264d899422f55b408560a259311776f0e519@egi.eu, ISS=https://aai-dev.egi.eu/auth/realms/egi" --account randomaccount --email marvin.gajek@cern.ch

make test-rucio-transfers
```

## Make Targets

```bash
dep-dlm-testbed

  RUNTIME    = compose    (compose | k8s)
  TOKEN_MODE = managed (managed | unmanaged)
  DAEMON_MODE = direct (direct | daemons)
  GITOPS_ENV = sandbox (sandbox | staging | production)
  K8S_NAMESPACE = dep-dlm-sandbox
  SCOPE_PROFILE = egi-dev (local | <profile>)

Usage:
  make <target> [RUNTIME=compose|k8s] [TOKEN_MODE=managed|unmanaged] [DAEMON_MODE=direct|daemons] [SCOPE_PROFILE=local|<profile, e.g. egi-dev>] [SERVICES="svc1 svc2"]

  help                 Show this help (default target)

Setup
  certs                Generate certificates (CA, host certs)
  init                 Initialize the testbed (accounts, RSEs, OIDC seed)

Lifecycle
  start                Start the stack
  stop                 Stop the stack and remove volumes / PVCs
  restart              Tear down and start again
  rebuild              Rebuild one or more services: make rebuild SERVICES="fts teapot"  (compose: rebuild image; k8s: helm upgrade)
  rebuild-clean        Rebuild from scratch (no cache) — use when a forked git dependency (davix/gfal2/fts) moved
  ps                   Show running services / pods
  logs                 Tail logs (all services, or pass SERVICES="..." for a subset)

GitOps
  argocd-install       Install ArgoCD + bootstrap the chosen env (GITOPS_ENV=sandbox|staging|production)
  argocd-uninstall     Uninstall ArgoCD applications and ArgoCD resources
  flux-install         Install Flux + bootstrap the chosen env (GITOPS_ENV=sandbox|staging|production)
  flux-uninstall       Uninstall Flux Kustomizations, Flux resources (GitRepository) and Flux controllers

Helm-only
  helm-lint            Lint the umbrella chart
  helm-template        Render manifests without installing

Tests
  test-rucio-transfers Rucio E2E TPC transfer test
  test-copernicus-transfers Rucio E2E TPC transfer test with Copernicus Sentinel data (WebDAV + OIDC)
  test-rucio-deletion  Rucio E2E deletion test
  probe-teapot         Teapot WebDAV probe with OIDC tokens

Cleanup
  clean                Remove generated certs and compose volumes (keeps CA)
```

## Documentation

See [docs](./docs/)
