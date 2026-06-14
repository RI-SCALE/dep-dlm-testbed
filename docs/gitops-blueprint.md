# DEP DLM — GitOps Deployment Blueprint

Status: **implemented** — Argo CD and Flux deployment paths are in the tree and
validated end-to-end on the sandbox environment in CI. Staging and production are
authored but need external Vault/DB/IdP to converge (tracked in `BACKLOG.md`).

This document explains the *intent* and the *shape* of the deployment. For exact
manifests, directory contents, chart versions, and sync ordering, read the tree
under `deploy/gitops/` — those details change with the code and are deliberately
not duplicated here.

## Goal

Let partners deploy and operate their own DEP DLM data orchestration layer (Rucio
server + daemons, with optional bundled IdP / storage / Vault) via GitOps, using
the testbed Helm charts as the *blueprint* while leading with **upstream** charts
(rucio/helm-charts, Bitnami PostgreSQL) plus thin DEP DLM overlays. The layout is
engine-agnostic: the same `base/` and `environments/` tree drives both Argo CD and
Flux, so a partner can pick either engine.

## What we drop from the testbed umbrella

The testbed umbrella (`deploy/helm-charts/dep-dlm-testbed`) is a self-contained
ephemeral stack. The blueprint keeps its **service composition** but replaces its
**machinery**, because the following are testbed-only and wrong for production:

| Testbed umbrella mechanism | Why it's testbed-only | Blueprint replacement |
|---|---|---|
| `certs.files` baking PEMs into a Secret from `files/` symlinks | secrets in git/chart | External Secrets + Vault (see Secrets) |
| `testbed-patches` mounting `oidc.py`/`fts3.py`/`constants.py` over site-packages | a fork over upstream code | projected from Vault as a Secret; upstream the patches longer-term |
| `bootstrap-db.py` Job (post-install hook) | implicit hook | explicit, gated DB-bootstrap Job (see Ordering) |
| flat `testbed-configs` slurp + token-mode cfg switch | bakes `keycloak:8443` etc. | per-component values under `base/values/`, projected via Vault |
| vendored `rucio-daemons` chart (items/lifecycle patch) | local fork | upstream chart + values; post-render patch only where unavoidable |

## Layout

A shared `base/` holds the architecture; per-environment overlays carry only the
margin (Vault target, component selection, namespace). Both engines consume the
same `base/` and `environments/` tree; each engine has its own thin entrypoint
layer.

- `base/` — engine-agnostic: ExternalSecrets, per-component chart values, the
  DB-bootstrap Job.
- `environments/<env>/secrets/` — the per-env `ClusterSecretStore` (+ a seed Job
  in sandbox) and the ExternalSecrets, plus the bootstrap Job gated behind them.
- `argocd/` — per-env ApplicationSet (component selection) + app-of-apps
  entrypoints.
- `flux/` — per-component HelmReleases, HelmRepository sources, a dedicated ESO
  Kustomization, and staged per-env entrypoints.

Below table shows the **Argo→Flux construct mapping**:

| Argo construct                          | Flux equivalent                                  |
|-----------------------------------------|--------------------------------------------------|
| ApplicationSet (list generator)         | directory of HelmRelease + per-env Kustomization |
| Application (chart + values)            | HelmRelease (chart.spec.sourceRef + valuesFrom)  |
| repoURL: <chart repo>                   | HelmRepository source object (one per registry)  |
| $values multi-source valueFiles         | HelmRelease.valuesFrom -> ConfigMap of values    |
| repoURL: <git> path: <chart>            | HelmRelease w/ chart.spec.sourceRef GitRepository|
| repoURL: <git> path: <dir> (bootstrap)  | Flux Kustomization (path:) + dependsOn           |
| sync-wave ordering                      | HelmRelease.dependsOn / Kustomization.dependsOn  |
| app-of-apps root                        | one env Kustomization aggregating components+secrets |
| destination.namespace                   | HelmRelease.targetNamespace / Kustomization.targetNamespace |
| automated{prune,selfHeal}               | Flux is pruning+self-healing by default          |
| fullnameOverride (naming discipline)    | SAME — carries over verbatim                      |

**Key asymmetry:** Flux Kustomization has NO cross-dir load-restrictor, so a shared
components/ dir referenced from env overlays works natively (the thing Argo
rejected). That's why this layout is DRY without ApplicationSet templating.

Reference docs:

- Kustomize base/overlays: https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/
- Argo app-of-apps: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- Argo ApplicationSet: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Flux HelmRelease: https://fluxcd.io/flux/components/helm/helmreleases/

## Environment ladder

Progressive externalisation — each rung changes *what is external*, not the
structure. Pick the environment with `GITOPS_ENV` (sandbox | staging | production).

1. **Sandbox** (lead example) — everything internal: bundled Keycloak, XRootD,
   Teapot, in-cluster PostgreSQL, an in-cluster dev Vault seeded by a Job,
   self-signed CA, `managed` token flow. Ephemeral (kind or a throwaway
   namespace). A partner sees a working end-to-end stack from one install, then
   peels pieces away. This is the path validated in CI.

2. **Staging** — external IdP + real secrets: the `ClusterSecretStore` points at
   a real Vault (Kubernetes auth, operator-seeded, no seed Job); components that
   move external (Keycloak/XRootD/Teapot/Vault/PostgreSQL) are omitted from the
   ApplicationSet / env kustomization and their endpoints parameterised.

3. **Production** — as staging, plus external storage and HA: Rucio server/daemons
   scaled, real DNS/ingress, secrets from the partner's Vault.

Config separation (config in env/overlay, not image): https://12factor.net/config

## Component selection and endpoints

Components are selected **per environment by presence**, not by a toggle schema:
in Argo, which elements the env's ApplicationSet lists; in Flux, which resources
the env kustomization includes. Sandbox includes everything; staging/production
omit the externalised components.

The substance of "disable a chart" is **pointing its dependents at the external
endpoint**, not just the on/off switch — e.g. using an external IdP means setting
the Rucio OIDC issuer, the FTS `fts3restconfig`, and the RSE `audience` to that
issuer. Those values live in `base/values/` and the per-env secrets overlay (for
endpoints carried via Vault), so changing an endpoint is an overlay edit, not a
structural change.

## Secrets (internal or external Vault — same abstraction)

The blueprint never holds PEMs or client secrets in git. It depends on a secret
abstraction so internal vs external Vault is one parameter:

- An in-cluster Vault (sandbox) **or** an external Vault (staging/production) —
  the charts don't care which.
- **External Secrets Operator** reconciles first so its CRDs exist before any
  ExternalSecret. A `ClusterSecretStore` (same name across envs) targets whichever
  Vault the environment uses; ExternalSecrets project the certs/configs/patches and
  the Rucio config into native Secrets that the charts mount.
- Sandbox seeds its dev Vault with a Job (clones the repo, generates the runtime
  certs, loads everything via `vault kv put`); staging/production assume the Vault
  is seeded out-of-band by an operator.

Links:
- External Secrets Operator: https://external-secrets.io/latest/
- ESO Vault provider: https://external-secrets.io/latest/provider/hashicorp-vault/
- Vault Agent injection (alternative): https://developer.hashicorp.com/vault/docs/platform/k8s/injector
- cert-manager: https://cert-manager.io/docs/
- SOPS (lighter alt for small setups): https://fluxcd.io/flux/guides/mozilla-sops/

## Ordering (both engines)

The stateful infra and secrets must exist before the workloads, and the DB schema
before the daemons. The same logical order is enforced on each engine by its native
mechanism:

`ESO → core (Vault + PostgreSQL) → secrets (seed + ExternalSecrets) → DB bootstrap → components`

- **Argo CD**: sync-waves order the apply; the bootstrap Job lives in the secrets
  Application and is wave-ordered *behind* the ExternalSecrets, so it mounts secrets
  that already exist.
- **Flux**: `dependsOn` + `wait` between staged Kustomizations, with a Job
  healthCheck gating the components stage on the schema being created.

The key reason this ordering exists: the bootstrap Job mounts ESO-projected
Secrets, and a missing Secret is a mount-time (kubelet) failure — so the Secret
must exist before the Job's pod is created, not merely be waited for inside it.

## Runbooks to ship

Short, task-focused (entry point: `deploy/gitops/README.md`). Currently only the
sandbox path is documented end-to-end; the rest are outstanding (tracked in
`BACKLOG.md`):

1. **Sandbox quickstart** — install, watch it converge, run a transfer.
2. **Bring your own IdP** — external issuer; where issuer/audience/client land
   (Rucio OIDC, FTS `fts3restconfig`, RSE `audience`).
3. **Bring your own storage** — omit bundled XRootD/Teapot, register external RSEs.
4. **Secrets with Vault** — internal vs external, the `ClusterSecretStore`, the
   required Vault keys.
5. **The Rucio configs that matter** — brief: `rucio.cfg` OIDC, FTS
   `fts3restconfig`, RSE attributes.
