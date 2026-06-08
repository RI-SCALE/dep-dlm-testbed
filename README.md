# dep-dlm-testbed

Self-contained DLM testbed with Rucio, FTS3, XRootD, Teapot WebDAV and Keycloak for validating end-to-end OIDC token orchestration, TPC transfers, dataset operations and replication rule lifecycles across Docker Compose and Kubernetes (`amd64`/`arm64`).

The testbed supports both managed and unmanaged token flows and can be extended to support data discovery, popularity, and preparation services, as well as broader integration scenarios involving external token providers and external WebDAV or XRootD interfaces.

The testbed also applies minimal source patches to upstream components (e.g. Rucio, FTS3, gfal2, davix, Teapot) to validate features not yet upstream, making it a realistic environment for prototyping and testing changes end-to-end before they land upstream. Patches and their rationale are documented in [patches.md](docs/patches.md).

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
FTS cloud-storage rows from these credentials, and the test reads them back:

```bash
export S3_ACCESS_KEY=... S3_SECRET_KEY=...
make init
make test-copernicus-transfers
```

## Make Targets

```bash
dep-dlm-testbed

  RUNTIME    = compose    (compose | k8s)
  TOKEN_MODE = managed (managed | unmanaged)

Usage:
  make <target> [RUNTIME=compose|k8s] [TOKEN_MODE=managed|unmanaged] [SERVICES="svc1 svc2"]

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

Documentation is available in the [docs directory](./docs/) including high-level flows.
