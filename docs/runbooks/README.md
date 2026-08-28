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
| 4 | [Connecting to validation-storage](04-connecting-to-validation-storage.md) | SSH into the staging/production validation-storage VM via OS Login + IAP tunneling for debugging config, logs, and container state in place. |
| 5 | [Adding a new IdP / SCOPE_PROFILE](05-adding-a-new-idp-profile.md) | Checklist for validating the stack against a different external IdP — which files to add under `shared/config/<profile>/`, and the handful of places outside it (Helm's `configs-cm.yaml`, gitops' `seed-job.yaml`) that need a matching edit. |
| 6 | [Secrets via GCP Secret Manager + ExternalSecrets](06-secrets-gcp-secret-manager.md) | How staging/production actually provision secrets (superseding the originally-planned "external Vault" approach — sandbox alone still uses in-cluster Vault): Terraform-managed Secret Manager entries, ESO's `ClusterSecretStore` wiring via Workload Identity, and rotation. |

## Planned runbooks (TODO)

These cover the staging/production hardening that the sandbox set defers. Tracked
in `BACKLOG.md`.

| # | Runbook | Purpose | Status |
|---|---------|---------|--------|
| 7 | Observability | Metrics, logs, and dashboards for the conveyor/judge/reaper daemons, FTS, and storage — what to scrape, what to alert on, where transfers stall. | TODO (later) |
| 8 | Public TLS via cert-manager | Automated certs for the Gateway's public hostnames (`rucio_public_hostname`, `fts_public_hostname`) via a `ClusterIssuer` — CA choice still open (GCP-managed certs avoid Let's Encrypt's per-hostname rate limit, which matters given staging is torn down/recreated regularly; a private CA or LE's staging ACME endpoint are other options). Distinct from the internal self-signed CA (`certs`/`generate-certs.sh`), which stays Terraform/manually rotated. | TODO — premature until production's public-endpoint requirements and CA choice are settled |

## Conventions
Each runbook follows the same skeleton: Purpose, Prerequisites, Configuration
reference, Steps, Verification. Symptom-level troubleshooting lives in
[docs/troubleshooting.md](../troubleshooting.md) rather than inline, to keep runbooks scannable.
