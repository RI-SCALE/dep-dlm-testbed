# DEP DLM Runbooks
Short, task-focused runbooks for deploying and operating your own DEP DLM data
orchestration stack (Rucio + FTS + storage + IdP). Entry point for deployment is
`deploy/gitops/README.md`; these runbooks cover the configurations that matter
once the stack is up.

| # | Runbook | Purpose |
|---|---------|---------|
| 1 | [Sandbox quickstart](01-sandbox-quickstart.md) | Install, watch it converge, run a transfer. |
| 2 | [Bring your own IdP](02-bring-your-own-idp.md) | Point Rucio/FTS/RSEs at an external OIDC issuer; where issuer/audience/client/scopes land. |
| 3 | [Bring your own storage](03-bring-your-own-storage.md) | Omit bundled XRootD/Teapot; register and wire external RSEs. |
| 5 | [The Rucio configs that matter](05-rucio-configs-that-matter.md) | Brief reference: `rucio.cfg` OIDC, FTS `fts3restconfig`, RSE attributes. |

## Planned runbooks (TODO)

These cover the staging/production hardening that the sandbox set defers. Tracked
in `BACKLOG.md`.

| # | Runbook | Purpose | Status |
|---|---------|---------|--------|
| 4 | Secrets with external Vault | Provision an external Vault (or equivalent) via Terraform/IaC on a hyperscaler; wire `ClusterSecretStore` + external-secrets to it; seed and rotate the cert/config/IdP secrets the stack consumes. | Deferred — pending external IaC provisioning |
| 6 | Certificate installation (Rucio + FTS) | Install the CA + host certs trusted by Rucio and FTS for IAM and storage backends, so token and TLS connections to external IdP/storage are trusted.  | TODO |
| 7 | Observability | Metrics, logs, and dashboards for the conveyor/judge/reaper daemons, FTS, and storage — what to scrape, what to alert on, where transfers stall. | TODO (later) |

## Conventions
Each runbook follows the same skeleton: Purpose, Prerequisites, Configuration
reference, Steps, Verification, Troubleshooting. Commands are copy-pasteable and
assume `kubectl` context is set to the target cluster/namespace.
