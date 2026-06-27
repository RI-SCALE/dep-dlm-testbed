# DEP DLM — GitOps Deployment

Deploy the DEP DLM data orchestration layer via Argo CD or Flux. Design and
rationale live in `docs/gitops-blueprint.md`; this is the operational entry point.

## Layout
- `base/` — shared architecture: ExternalSecrets, per-component values, DB-bootstrap Job
- `environments/<env>/secrets/` — per-env ClusterSecretStore (+ seed Job in sandbox) + ExternalSecrets
- `argocd/` — per-env ApplicationSet + app-of-apps entrypoints
- `flux/` — HelmReleases, sources, ESO, staged entrypoints

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

Override the tracked ref/repo with `GITOPS_REVISION` / `GITOPS_REPO_URL`.
Staging/production need external Vault/DB/IdP (see [BACKLOG.md](../../BACKLOG.md)).
