# Design-002: Config/Secret Classification for Testbed Config

- **Status:** Implemented
- **Owner:** DEP DLM testbed
- **Related ADR(s):** [ADR-004: Classify Testbed Config by Sensitivity
  (ConfigMap vs Secret)](../adrs/adr-004-classify-testbed-config-by-sensitivity.md)

## Problem

`testbed-configs` was a `configMap:` volume source in the umbrella
chart but a `secret:` volume source in GitOps, for the same logical
content — drift introduced when ESO (Secret-only) took over
provisioning without a per-file sensitivity review. Most of the content
was genuinely non-sensitive; a few files weren't.

## Classification (final)

| Content | Object | Notes |
|---|---|---|
| Host/CA certs | `testbed-certs` (Secret) | Unaffected by this migration |
| `server.cfg`, `alembic.ini`, `idpsecrets.json` | `testbed-secrets` (Secret) | Real IdP client secrets (`idpsecrets.json`) and DB/OIDC config |
| `realm.json` | `testbed-secrets` (Secret) | Embeds real Keycloak client secrets |
| `userpass-client.cfg` | `testbed-secrets` (Secret) | Contains a literal password |
| `fts3config` | `testbed-secrets` (Secret) | Embeds `fts_db_password` in staging/production; kept Secret everywhere for coherence rather than varying by environment |
| `fts3restconfig` | `testbed-configs` (ConfigMap) | No credentials. `managed`/`unmanaged` variant resolved once at generation time into a single `fts3restconfig` key — no runtime selection in any consumer |
| `gfal2_http_plugin.conf`, `authdb`, `scitokens.conf`, `xrdrucio-scitokens.cfg` | `testbed-configs` (ConfigMap) | No credentials |
| `application.yml`, `config.ini`, `data.properties`, `logback.xml`, `user-mapping.csv` | `testbed-configs` (ConfigMap) | No credentials; `user-mapping.csv` is pseudonymous subject IDs, not secrets |
| Python source patches | `testbed-patches` (ConfigMap) | Not in original scope — reclassified once `rucio-server`/`rucio-daemons` gained ConfigMap-mount support (see Generation mechanism) |
| Bootstrap/entrypoint scripts | `testbed-scripts` (ConfigMap) | Same reasoning as patches |
| E2E test suite | `testbed-tests` (ConfigMap) | Same reasoning as patches |

`testbed-certs` and `testbed-secrets` are the only Secrets anywhere in
either deployment path. Everything else is a ConfigMap.

## Naming

`testbed-<category>` throughout. `rucio-server-cfg` (the old,
component-scoped-sounding name for what's actually shared content —
`rucio-daemons` mounts the identical subPaths) is retired; its content
joins `testbed-secrets`.

`scopeProfile`/`tokenMode` selection happens **once, at generation
time** — not by generating one object per profile and having every
consumer re-select which to mount. A single `testbed-configs` and a
single `testbed-secrets`, correct by construction, in every
environment.

## Generation mechanism

The umbrella chart's own templates
(`deploy/helm-charts/dep-dlm-testbed/templates/testbed-*.yaml`) are the
single source of truth for `testbed-configs`/`testbed-patches`/
`testbed-scripts`/`testbed-tests` across **both** deployment paths.
GitOps renders the same templates directly
(`shared/scripts/render-testbed-configmaps.sh`, via
`helm template --show-only`) rather than maintaining a second,
independent definition of the same objects — closing the exact class
of drift this doc exists to prevent. Confirmed in practice: an earlier,
glob-based GitOps generator excluded only two filenames rather than
the whole `rucio/` directory, and `idpsecrets.json` (plus its
per-profile companion `idpsecrets.json.secret.pem`) leaked into a
ConfigMap as a result. Fixed by excluding by directory, then by
retiring the second definition entirely.

This mechanism runs once per bootstrap, in every environment — same
posture already accepted for Vault-seeded `testbed-secrets` and the
namespace-substituted `ClusterSecretStore`: not continuously
GitOps-reconciled, re-run manually
(`render-testbed-configmaps.sh --scope-profile ... --token-mode ...`)
to pick up a different profile or updated source content.

`testbed-secrets` is provisioned per environment's existing secrets
backend (Vault/ESO for sandbox, GCP Secret Manager/Terraform for
staging/production) — unaffected by this doc, which only ever
concerned which object kind non-sensitive content lands in.
