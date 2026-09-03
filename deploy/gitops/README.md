# DEP DLM — GitOps Deployment

Deploy the DEP DLM data orchestration layer via Argo CD or Flux. Design and
rationale live in `docs/gitops-blueprint.md`; this is the operational entry point.

## Layout
- `base/` — shared architecture: per-component values
- `environments/<env>/secrets/` — per-env ClusterSecretStore + `testbed-certs`/
  `testbed-secrets` ExternalSecrets (the only Secrets in any environment)
- `argocd/` — per-env ApplicationSet + app-of-apps entrypoints (`.../secrets`
  is the whole synced tree per environment). `rucio-server`/`rucio-daemons`
  source their chart directly from the `mgajek-cern/helm-charts` fork
  (`targetRevision: master`) rather than from this repo.
- `flux/` — HelmReleases, sources, ESO, staged entrypoints. Two `GitRepository`
  sources are used: `flux-system/gitrepository-dep-dlm-testbed.yaml` (this
  repo, tracks whatever branch is being deployed) and
  `flux-system/gitrepository-rucio-charts-fork.yaml` (the Rucio chart fork,
  always pinned to `master`, independent of this repo's branch — see
  `docs/concepts/gitops-branch-development.md` for why these are kept in
  separate files).

`testbed-configs`/`testbed-patches`/`testbed-scripts`/`testbed-tests` are
**not** Kustomize-generated or GitOps-synced — same as Vault seeding and the
Rucio DB bootstrap, they're rendered once at bootstrap time
(`shared/scripts/render-testbed-configmaps.sh`, via `helm template` against
the umbrella chart — single source of truth with the local/helm-only
deployment path) and applied directly, run automatically by
`init-argocd.sh`/`init-flux.sh` alongside `seed-vault.sh`. This is what
keeps `TOKEN_MODE`/`SCOPE_PROFILE` bootstrap-time flags instead of values
baked into committed manifests, and avoids maintaining two independent
definitions of the same objects that can silently drift apart.

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

`GITOPS_REVISION`/`GITOPS_REPO_URL` only ever override this repo's own
source (the app-of-apps root for Argo, the `dep-dlm-testbed` `GitRepository`
for Flux) — they never affect the `rucio-server`/`rucio-daemons` chart
sources, which always track the `mgajek-cern/helm-charts` fork's `master`
branch regardless of which branch of this repo you're deploying.

Staging/production need external Vault/DB/IdP (see [BACKLOG.md](../../BACKLOG.md)).
