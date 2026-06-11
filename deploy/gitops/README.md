# DEP DLM — GitOps Deployment (Argo CD)

One **base** (the architecture) + thin **overlays** (the per-env margin). Every
environment uses the identical secret mechanism — Vault → External Secrets
Operator → native Secret → pod mount — validated end-to-end on the sandbox.

> Design rationale: [`docs/gitops-blueprint.md`](../../docs/gitops-blueprint.md).

## Layout

```
deploy/gitops/
  base/
    externalsecrets/   # ESO ExternalSecrets recreating the umbrella's Secrets
                       #   testbed-certs / testbed-configs / testbed-patches / rucio-server-cfg
                       #   (each dataFrom.extract on a Vault path — shared by ALL envs)
    values/            # per-component chart values mirroring the umbrella mounts
    applications/      # Argo Applications (upstream Rucio + bundled testbed charts)
  overlays/
    sandbox/           # dev Vault + store + seed Job + ephemeral overrides
    staging/           # real Vault (k8s auth), external IdP, persistent DB — NO seed
    production/        # + external storage, HA
  argocd/              # app-of-apps roots (one per env)
  flux/                # reserved
```

## The secret mechanism (same everywhere)

```
Vault (secret/dep-dlm/{certs,configs,patches,rucio})
   └─ ClusterSecretStore "dep-dlm-vault"   (same NAME every env; only the
        provider differs: dev token in sandbox, k8s-auth in staging/prod)
        └─ ExternalSecret (base/externalsecrets, dataFrom.extract)
             └─ Secret testbed-certs / testbed-configs / testbed-patches / rucio-server-cfg
                  └─ pod volumeMount  (base/values/*, identical to the umbrella)
```

The umbrella used to template these Secrets from `files/` symlinks. The
blueprint replaces that with Vault + ESO, so nothing holds PEMs in git.

## Sandbox quick start

```bash
# 1. Bootstrap Argo + the sandbox app-of-apps (installs ESO, Vault, store).
make gitops-sandbox \
  ARGOCD_REPO_URL=<your-fork> ARGOCD_REVISION=<your-branch>

# 2. Seed the dev Vault with the testbed's existing files.
#    Either the in-cluster Job (overlays/sandbox/seed-job.yaml, a PreSync hook),
#    or locally from the repo root:
NS=dep-dlm-sandbox FLOW=managed ./deploy/gitops/overlays/sandbox/seed-vault.sh

# 3. Watch ESO project the Secrets, then the components converge.
kubectl -n dep-dlm-sandbox get externalsecret
kubectl -n argocd get applications
```

The sandbox→staging→production margin is intentionally tiny: same base, same
ExternalSecrets, same component values. Overlays change only the Vault target,
the seed step (sandbox-only), toggles (internal vs external IdP/storage),
replicas, and persistence.

## Known TODOs (carried, not hidden)

- **Chart versions** are placeholders (`rucio-server`/`-daemons` 40.0.0, Vault
  0.28.1, ESO 0.10.7, PG 18.3.0) — pin to real published versions.
- **repoURL/targetRevision** in the Applications + app-of-apps point at a
  placeholder fork/branch — set to yours, or merge to the tracked default branch.
- **rucio-daemons post-render patch**: the upstream chart still doesn't render
  `secretMounts[].items` or `.lifecycle`; without an Argo post-render patch the
  CA won't mount at the expected path. (The testbed vendored chart patched this.)
- **scripts gap**: `base/values/xrootd.yaml` references `testbed-scripts-xrootd`;
  seed `dep-dlm/scripts-xrootd` + add an ExternalSecret, or rely on the image
  entrypoint. Same for any FTS entrypoint.
- **dep-dlm-secretstore** Argo bug (store never created standalone) is resolved
  here by putting the store in the overlay kustomization rather than its own app.
