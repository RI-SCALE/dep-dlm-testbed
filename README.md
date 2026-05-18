# dep-dlm-testbed

Self-contained DLM testbed with Rucio, FTS3, XRootD, Teapot WebDAV and OIDC provider (e.g. Keycloak). Runs end-to-end OIDC token orchestration tests on both `linux/amd64` and `linux/arm64`, across two runtimes: Docker Compose and Kubernetes. Extensible toward data discovery, popularity and preparation services and a full Rucio + FTS3 setup for external system integration.