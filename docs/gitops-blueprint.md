# DEP DLM — GitOps Deployment Blueprint (Design Draft)

Status: **draft for review** — no manifests yet. This doc fixes the structure,
the environment ladder, and the toggle surface before any YAML is written.

## Goal

Let partners deploy and operate their own DEP DLM data orchestration layer
(Rucio server + daemons, with optional bundled IdP / storage / Vault) via
GitOps, using the testbed Helm charts as the *blueprint* but tracking
**upstream** charts in production. Argo CD is the lead engine; the layout is
engine-agnostic so Flux is a thin swap.

## Non-goals (and what we deliberately drop from the testbed umbrella)

The testbed umbrella (`deploy/helm-charts/dep-dlm-testbed`) is a self-contained
ephemeral stack. The blueprint keeps its **service composition** but drops its
**machinery**, because the following are testbed-only and wrong for production:

| Testbed umbrella mechanism | Why it's testbed-only | Blueprint replacement |
|---|---|---|
| `certs.files` baking PEMs into a Secret from `files/` symlinks | secrets in git/chart | cert-manager + External Secrets (see Secrets) |
| `testbed-patches` mounting `oidc.py`/`fts3.py`/`constants.py` over site-packages | a fork over upstream code | upstream the patches, or overlay post-render |
| `bootstrap-db.py` Job (post-install hook) | fine, but should be explicit | keep as a documented bootstrap Job/hook |
| flat `testbed-configs` slurp + token-mode cfg switch | bakes `keycloak:8443` etc. | parameterised endpoints from overlay values |
| vendored `rucio-daemons` chart (items/lifecycle patch) | local fork | upstream PR, or Kustomize/Helm post-render patch |

## Repo layout (base + overlays)

Standard Kustomize base+overlay structure, consumed by Argo or Flux:

```
deploy/gitops/
  README.md                 # partner runbook entry point
  base/                     # tool-agnostic: chart refs + shared values
  overlays/
    sandbox/                # everything internal, ephemeral (lead example)
    staging/                # external IdP, secrets via Vault, real certs
    production/             # external IdP + external storage, HA, real DNS
  argocd/                   # app-of-apps / ApplicationSet (lead)
  flux/                     # HelmRelease/Kustomization (optional, later)
```

- Kustomize base/overlays: https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/
- Argo app-of-apps: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- Argo ApplicationSet: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Flux HelmRelease: https://fluxcd.io/flux/components/helm/helmreleases/

## Environment ladder

Progressive externalisation — each rung flips toggles, doesn't restructure.

### 1. Sandbox (lead example) — everything internal
Mirrors the testbed: bundled Keycloak, bundled XRootD/Teapot, in-cluster
Postgres, self-signed CA, `managed` token flow. Ephemeral (kind/minikube or a
throwaway namespace). Purpose: a partner sees a working end-to-end stack in one
`kubectl apply` / one Argo app, then peels pieces away.

### 2. Staging — external IdP + real secrets
`idp.internal: false` pointing at the partner/SSO issuer; certs from
cert-manager; secrets from Vault via External Secrets. Storage may still be
bundled. Single replica is fine.

### 3. Production — external IdP + external storage, HA
IdP and storage external (charts disabled, endpoints parameterised); Rucio
server/daemons HA; real DNS/ingress; secrets from the partner's Vault.

Twelve-Factor config separation (config in env/overlay, not image):
https://12factor.net/config

## Toggle surface (enable/disable + endpoint parameters)

Enabling/disabling components is idiomatic (it's your umbrella's `condition:`).
The key point: **disabling a chart also requires pointing its dependents at the
external endpoint** — the substance is parameterising issuers/audiences/hosts,
not just the on/off switch.

```yaml
idp:
  internal: true                       # deploy bundled Keycloak?
  issuerUrl: ""                        # required when internal: false
  clientSecretRef: idp-client          # ExternalSecret name
storage:
  xrootd: { internal: true, externalHosts: [] }
  webdav: { internal: true, externalHosts: [] }
tokenFlow: managed                     # managed | unmanaged (already supported)
secrets:
  vault:
    internal: true                     # deploy in-cluster Vault, or...
    address: ""                        # ...point ClusterSecretStore at external
extensions:                            # future services, off by default
  discovery: false
  popularity: false
  preparation: false
```

Each toggle = a chart enable/disable **plus** the config its dependents need
(e.g. `idp.internal: false` must set Rucio OIDC + FTS `fts3restconfig` + RSE
`audience` to the external issuer).

## Secrets (internal or external Vault — same abstraction)

The blueprint never holds PEMs or client secrets. It depends on a **secret
abstraction** so internal vs external Vault is one parameter:

- Deploy in-cluster Vault (sandbox/dev) **or** point at an external Vault — the
  charts don't care.
- **External Secrets Operator** with a `ClusterSecretStore` → charts reference
  `ExternalSecret`s that ESO fills from whichever Vault the store targets.
- TLS via **cert-manager** rather than baked PEMs.

Links:
- External Secrets Operator: https://external-secrets.io/latest/
- ESO Vault provider: https://external-secrets.io/latest/provider/hashicorp-vault/
- Vault Agent injection (alternative): https://developer.hashicorp.com/vault/docs/platform/k8s/injector
- cert-manager: https://cert-manager.io/docs/
- SOPS (lighter alt for small setups): https://fluxcd.io/flux/guides/mozilla-sops/

Sandbox may use plain Kubernetes Secrets (documented as sandbox-only); staging
and production use ESO+Vault.

## Runbooks to ship (outline)

Short, task-focused, in `deploy/gitops/README.md`:
1. **Sandbox in 10 minutes** — apply the Argo app, watch it converge, run a transfer.
2. **Bring your own IdP** — set `idp.internal: false`, where issuer/audience/client land.
3. **Bring your own storage** — disable bundled XRootD/Teapot, register external RSEs.
4. **Secrets with Vault** — internal vs external, the `ClusterSecretStore`, required keys.
5. **The Rucio configs that matter** — brief: `rucio.cfg` OIDC, FTS `fts3restconfig`, RSE attrs.
