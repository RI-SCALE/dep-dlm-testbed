# dep-dlm-testbed

Experimental validation environment for the DEP DLM architecture: Rucio, FTS3, XRootD, Teapot WebDAV, Keycloak and OPA, validating OIDC token orchestration, TPC transfers and rule lifecycles end to end. Validated patterns are promoted into production-focused repositories.

Every scenario is validated in CI: Compose and Kubernetes, the local Keycloak plus EGI Check-In and LS AAI, Argo CD and Flux and Terraform deploys to staging and production. See [Actions](https://github.com/RI-SCALE/dep-dlm-testbed/actions) for the status of each workflow.

## What's inside

- **Runtimes:** Docker Compose and Kubernetes (`amd64`/`arm64`), GitOps via Argo CD or Flux across sandbox, staging and production
- **Identity:** bundled Keycloak, EGI Check-In and LS AAI / Perun; managed and unmanaged token flows
- **Authorisation:** Rucio delegates permission checks to OPA via a Rego policy package
- **Storage:** XRootD, Teapot WebDAV and S3 (Copernicus Data Space)
- **Upstream patches:** minimal patches to Rucio, FTS3, gfal2, davix and Teapot for features not yet upstream — see [docs/patches.md](./docs/patches.md), with decisions in [docs/adrs/](./docs/adrs/) and [docs/design/](./docs/design/)

## Quick start

Use the provided [dev container](./.devcontainer/devcontainer.json). It needs [Docker](https://docs.docker.com/engine/install/) and an IDE with dev container support (e.g. [VS Code with the Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)).

```bash
make certs                  # generate CA and host certificates

export RUNTIME=compose      # compose | k8s (Helm chart)
export TOKEN_MODE=managed   # FTS token mode: managed | unmanaged
export DAEMON_MODE=direct   # direct | daemons

make start                  # start the stack
make init                   # accounts, RSEs, OIDC seed
make test-rucio-transfers
make test-rucio-deletion
make stop                   # stop and remove volumes / PVCs
```

## Scenarios

### Copernicus S3 transfers

`test-copernicus-transfers` validates a streamed copy from an S3 source (Copernicus Data Space) to a WebDAV destination. It needs `S3_ACCESS_KEY`/`S3_SECRET_KEY` for the Copernicus endpoint ([how to get them](https://documentation.dataspace.copernicus.eu/APIs/S3.html)) and self-skips at init when they are unset.

Export them **before `make init`**: init creates the S3 RSE and the FTS cloud-storage rows from them and the test reads them back.

```bash
export S3_ACCESS_KEY=... S3_SECRET_KEY=...
make init
make test-copernicus-transfers
```

### External identity providers

| Scope profile | Env file | `TOKEN_MODE` |
|---|---|---|
 | `egi-dev` (EGI Check-In) | `envs/egi-dev.env` | `unmanaged` — `resource=` is supported on token exchange; `requested_token_type=refresh_token` is currently unsupported ([runbook 02](./docs/runbooks/02-bring-your-own-idp.md)) |
| `ls-aai-dev` (LS AAI) | `envs/ls-aai-dev.env` | `managed` or `unmanaged` |

Copy `envs/<profile>.env.example` to `envs/<profile>.env` and fill in your `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`, then:

```bash
PROFILE=egi-dev             # or ls-aai-dev
source envs/$PROFILE.env

# Substitute your client credentials into idpsecrets.json
cp shared/config/rucio/$PROFILE/idpsecrets.json.example shared/config/rucio/$PROFILE/idpsecrets.json
sed -i \
  -e "s|<valid client id>|$OIDC_CLIENT_ID|g" \
  -e "s|<valid client secret>|$OIDC_CLIENT_SECRET|g" \
  shared/config/rucio/$PROFILE/idpsecrets.json

export RUNTIME=k8s DAEMON_MODE=direct TOKEN_MODE=unmanaged   # see table
make start
make init

# Map your identity at the IdP to the seeded Rucio account
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-admin identity add --type OIDC \
    --id "SUB=<your-sub>, ISS=<issuer>" --account randomaccount --email <your-email>

# e.g. for egi-dev
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-admin identity add --type OIDC \
    --id "SUB=aa886829a0a894933008498cfe62264d899422f55b408560a259311776f0e519@egi.eu, ISS=https://aai-dev.egi.eu/auth/realms/egi" --account randomaccount --email marvin.gajek@cern.ch

# e.g. for ls-aai
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-admin identity add --type OIDC \
    --id "SUB=28f7bc3a2d32a4a722f6eb24f77f7fbe42eb6471@lifescience-ri.eu, ISS=https://login.aai.lifescience-ri.eu/oidc/" --account randomaccount --email marvin.gajek@cern.ch

make test-rucio-transfers
```

Issuers: `https://aai-dev.egi.eu/auth/realms/egi` (egi-dev), `https://login.aai.lifescience-ri.eu/oidc/` (ls-aai-dev).

> **LS AAI:** the test environment requires membership of the `Life Science Community - Test Environment` VO before login succeeds. If `rucio whoami` or a browser login returns an access-denied page, register at `https://signup.aai.lifescience-ri.eu/fed/registrar?vo=lifescience_test` with the same identity; propagation can take a few minutes.

## Make targets

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
  help                 Show this help

Setup
  certs                Generate CA and host certificates
  init                 Init testbed accounts, RSEs, OIDC seed
  vendor-opa-ri-scale  Re-vendor the opa-ri-scale ODRL evaluator at OPA_RI_SCALE_REF

AuthN / AuthZ
  verify-idp-token     Verify OIDC token flow for SCOPE_PROFILE. Needs OIDC_CLIENT_SECRET.
  check-claims         Decode entitlements/acr claims for every realm user (or USER=<name>)
  ingest-policies      Push authz.rego and data (incl. ODRL policies) into the running OPA (idempotent)
  fetch-odrl-policies  Print the DEP ODRL policies from the WP4 policy repository. Needs ODRL_CLIENT_SECRET.

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
  probe-xrootd         XRootD probe with SciTokens
  probe-fts-teapot     Minimal FTS-only TPC repro (teapot1->teapot2), bypasses Rucio/conveyor
  probe-fts-xrootd     Minimal FTS-only TPC repro (xrd3->xrd4), bypasses Rucio/conveyor
  test-authz-personas  Authz entitlement-tier test across DEP persona accounts

Rego
  test-rego            Rego unit tests (all phases, no stack needed)
  fmt-rego             Format all Rego files in place (fixes the opa-fmt pre-commit hook)

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
  tf-force-unlock      Force-unlock TF_ENV's state after a stale/abandoned lock. Usage: make tf-force-unlock LOCK_ID=<id from the lock error>. Confirm nothing else is actually running against TF_ENV first — see the Lock Info 'Who' field.
  certs-sync           Fetch current certs from Secret Manager (matches what's deployed to TF_ENV)
  userpass-client-sync Fetch userpass-client.cfg from Secret Manager (matches what's deployed to TF_ENV)

Cleanup
  clear-artifacts      Remove certs, volumes, Terraform/Python/Helm artifacts
  cleanup              Delete rules/replicas/distances (and RSEs unless KEEP_RSES=1) created by init/tests
```

## Documentation and backlog

- [docs/](./docs/) — runbooks, design documents, ADRs and patches
- [BACKLOG.md](./BACKLOG.md) — tracked improvements and planned work
