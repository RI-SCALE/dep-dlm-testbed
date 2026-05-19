# dep-dlm-testbed

Self-contained DLM testbed with Rucio, FTS3, XRootD, Teapot WebDAV and OIDC provider (e.g. Keycloak). Runs end-to-end OIDC token orchestration tests on both `linux/amd64` and `linux/arm64`, across two runtimes: Docker Compose and Kubernetes. Extensible toward data discovery, popularity and preparation services and a full Rucio + FTS3 setup for external system integration.

## Quick start

### Docker Compose

The default runtime is compose.

```bash
# 1. Generate certificates
make certs

# 2. Start the stack
make compose-up
```

## Make Targets

```bash
  help                       Show this help (default target)

Setup
  certs                      Generate certificates (e.g. CA, hosts)

Stack lifecycle (compose-*)
  compose-up                 Start the full stack in the background
  compose-down               Stop the stack and remove volumes
  compose-restart            Tear down and restart the stack
  compose-rebuild            Rebuild and restart one or more services: make compose-rebuild SERVICES="teapot fts"
  compose-ps                 List running containers
  compose-logs               Tail logs from all services (Ctrl-C to exit)
  compose-logs-%             Tail logs from a single service, e.g. `make compose-logs-rucio`
  compose-build              Build local Docker images (e.g. fts, teapot)

Cleanup
  clean                      Remove generated certs and volumes; keep CA (rucio_ca.pem + key)
```