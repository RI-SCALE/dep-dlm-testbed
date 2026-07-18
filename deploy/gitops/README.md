# DEP DLM — GitOps Deployment

Deploy the DEP DLM data orchestration layer via Argo CD or Flux. Design and
rationale live in `docs/gitops-blueprint.md`; this is the operational entry point.

## Layout
- `base/` — shared architecture: ExternalSecrets, per-component values
- `environments/<env>/secrets/` — per-env ClusterSecretStore + ExternalSecrets
- `argocd/` — per-env ApplicationSet + app-of-apps entrypoints
- `flux/` — HelmReleases, sources, ESO, staged entrypoints

Vault seeding and the Rucio DB bootstrap are **not** GitOps-synced resources —
they're imperative one-shot steps (`shared/scripts/seed-vault.sh`,
`shared/scripts/run-bootstrap-db.sh`), run automatically by
`init-argocd.sh`/`init-flux.sh` at the right point in the bootstrap sequence.
This is what makes `TOKEN_MODE`/`SCOPE_PROFILE` bootstrap-time flags instead
of values you'd otherwise have to hand-edit into a committed manifest.

## Component selection
Per environment by presence: which elements the env's ApplicationSet lists (Argo)
or the env kustomization includes (Flux). Sandbox runs everything in-cluster;
staging/production omit the externalised components (Keycloak/XRootD/Teapot/Vault/
PostgreSQL) and point their dependents at external endpoints.

## Quickstart (sandbox)

```bash
make argocd-install                        # or: make flux-install
make argocd-uninstall                      # or: make flux-uninstall
```

Override the tracked ref/repo with `GITOPS_REVISION` / `GITOPS_REPO_URL`, and
the FTS token mode / OIDC scope profile with `TOKEN_MODE` / `SCOPE_PROFILE`
(same variables `make start`/`make init` already use):

```bash
make argocd-install TOKEN_MODE=unmanaged SCOPE_PROFILE=egi-dev
```

Staging/production need external Vault/DB/IdP (see [BACKLOG.md](../../BACKLOG.md)).
