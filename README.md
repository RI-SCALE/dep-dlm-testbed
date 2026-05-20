# dep-dlm-testbed

Self-contained DLM testbed with Rucio, FTS3, XRootD, Teapot WebDAV and Keycloak for validating end-to-end OIDC token orchestration, TPC transfers, dataset operations and replication rule lifecycles across Docker Compose and Kubernetes (`amd64`/`arm64`). Extensible toward data discovery, popularity and preparation services and a full Rucio + FTS3 setup for external system integration.

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

# 2. Start the stack
make compose-up

# 3. Initialize DEP DLM testbed
RUNTIME=compose make init

# 4. Run tests
RUNTIME=compose make test-rucio-transfers
RUNTIME=compose make test-rucio-deletion

# 5. Stop the stack and remove volumes
make compose-down
```

### Kubernetes

```bash
# 1. Generate certificates
make certs

# 2. Install the Helm chart
make helm-install

# 3. Initialize DEP DLM testbed
RUNTIME=k8s make init

# 4. Run transfer tests
RUNTIME=k8s make test-rucio-transfers
RUNTIME=k8s make test-rucio-deletion

# 5. Stop the stack and remove volumes
make helm-uninstall
```

## Make Targets

```bash
  help                       Show this help (default target)

Setup
  certs                      Generate certificates (e.g. CA, hosts)
  init                       Initialize DEP DLM testbed (uses $RUNTIME — set RUNTIME=k8s for kubernetes)

Docker Compose lifecycle (compose-*)
  compose-up                 Start the full stack in the background
  compose-down               Stop the stack and remove volumes
  compose-restart            Tear down and restart the stack
  compose-rebuild            Rebuild and restart one or more services: make compose-rebuild SERVICES="teapot fts"
  compose-ps                 List running containers
  compose-logs               Tail logs from all services (Ctrl-C to exit)
  compose-logs-%             Tail logs from a single service, e.g. `make compose-logs-rucio`
  compose-build              Build local Docker images (e.g. fts, teapot)

Helm / Kubernetes lifecycle (helm-*, k8s-*)
  helm-lint                  Lint the umbrella chart
  helm-template              Render manifests locally (helm template …) without installing
  helm-install               Create the namespace and install the umbrella chart
  helm-upgrade               Apply local chart changes to the running release
  helm-uninstall             Uninstall the release and delete its PVCs
  helm-reinstall             Uninstall + install (full reset)

Tests
  test-rucio-transfers       Rucio E2E TPC transfer test
  test-rucio-deletion        Rucio E2E deletion test

Cleanup
  clean                      Remove generated certs and volumes; keep CA (rucio_ca.pem + key)
```

## Documentation

Documentation is available in the [docs directory](./docs/) including high-level flows.
