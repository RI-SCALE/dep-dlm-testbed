# DEP DLM — GitOps (de-duplicated layout)

Refactored per review feedback to remove per-environment Application duplication.

## Layout
```
apps/            # ONE Application body per component (shared across envs)
                 #   namespace carries a placeholder, patched per env
base/
  values/        # per-component chart values
  externalsecrets/  # the 6 testbed-* ExternalSecrets (shared)
  bootstrap/     # DB bootstrap Job (namespace un-pinned — works in any env)
environments/
  <env>/
    kustomization.yaml      # selects WHICH components + patches namespace
    secrets/                # ESO store + (sandbox) seed + ExternalSecrets
argocd/          # app-of-apps-<env> roots (apps + secrets)
flux/            # Flux equivalent (secrets layer reuses; components need HelmRelease)
```

## How enable/disable works
A component is in an environment iff its `apps/<component>.yaml` is listed in
`environments/<env>/kustomization.yaml`. Namespace is patched there too. No
duplicated Application files — the review's main critique, addressed.

- sandbox    : all 10 components, dev Vault, ephemeral PG, in-cluster seed
- staging    : omits keycloak/xrootd/teapot (external IdP+storage), vault
               (external), postgresql (external DB) — 3 sandbox bugs fixed by omission
- production : same omissions + HA (rucio-server replicaCount via values override)

## VERIFIED vs NEEDS-LOCAL-CHECK
Verified here: every file parses as YAML; every kustomization resource path
resolves to a real file.
NOT verifiable in this sandbox (no kustomize/Argo, and github releases blocked):
  - `kustomize build environments/<env>` actually renders (run it locally)
  - Argo resolves the $values multi-source + the namespace patch together
  - first-sync convergence
Run before trusting:
  kustomize build deploy/gitops/environments/sandbox     # must succeed
  kustomize build deploy/gitops/environments/sandbox/secrets

## Copy-from-working-tree (intentionally NOT regenerated to avoid drift)
  base/values/*.yaml          (your working per-component values)
  environments/sandbox/secrets/seed-job.yaml  (your 3-stage seed pipeline)
  environments/{staging,production}/secrets/clustersecretstore.yaml  (real Vault)
