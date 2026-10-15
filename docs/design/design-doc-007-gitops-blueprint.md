# Design-007: GitOps deployment blueprint

- **Status:** Accepted (implemented for sandbox; staging/production authored)
- **Owner:** DEP DLM, RI-SCALE (Marvin Gajek)
- **Related ADR(s):** —

## Problem

Partners need to deploy and operate their own DEP DLM data orchestration
layer (Rucio server + daemons, FTS, optional bundled IdP / storage / Vault).
The only deployable unit today is the testbed umbrella chart
(`deploy/helm-charts/dep-dlm-testbed`), a self-contained, ephemeral stack whose
machinery is wrong outside a testbed:

| Testbed umbrella mechanism | Why it's testbed-only |
|---|---|
| `certs.files` baking PEMs into a Secret from `files/` symlinks | secrets in git/chart |
| `testbed-patches` mounting `oidc.py`/`fts3.py`/`constants.py` over site-packages | a fork over upstream code |
| `bootstrap-db.py` Job (post-install hook) | implicit, unordered hook |
| flat `testbed-configs` slurp + token-mode cfg switch | bakes `keycloak:8443` etc. into config |
| vendored `rucio-daemons` chart (items/lifecycle patch) | local fork of an upstream chart |

## Goals

- Deploy via GitOps with **either Argo CD or Flux** from one engine-agnostic tree.
- Lead with **upstream** charts (rucio/helm-charts, Bitnami PostgreSQL) plus thin
  DEP DLM overlays; keep the umbrella's service composition, not its machinery.
- **No secrets in git**: internal or external Vault behind one abstraction.
- **Progressive externalisation**: environments differ in *what is external*,
  not in structure.
- A working end-to-end sandbox from one install, validated in CI.

## Non-goals

- Provisioning the external Vault, DB, IdP or storage (Terraform, separate work).
- Choosing an ingress controller, API gateway or WAF in front of Rucio; a real
  decision that should be made once, not implied here.
- Observability (see Design-005).
- Upstreaming the Rucio/FTS patches (longer-term; projected from Vault meanwhile).

## Design

### Layout

A shared `base/` holds the architecture; per-environment overlays carry only the
margin (Vault target, component selection, namespace). Each engine has a thin
entrypoint layer over the same tree.

- `base/`: engine-agnostic ExternalSecrets and per-component chart values.
- `environments/<env>/secrets/`: the per-env `ClusterSecretStore` and ExternalSecrets.
- `argocd/`: per-env ApplicationSet (component selection) + app-of-apps entrypoints.
- `flux/`: per-component HelmReleases, HelmRepository sources, a dedicated ESO
  Kustomization and staged per-env entrypoints.

Vault seeding and DB bootstrap are **not** in the tree: they are imperative
one-shot steps (`seed-vault.sh`, `run-bootstrap-db.sh`) invoked by
`init-argocd.sh`/`init-flux.sh`. This lets the FTS token mode and OIDC scope
profile be `--flow`/`--scope-profile` flags rather than committed values.

| Testbed mechanism | Blueprint replacement |
|---|---|
| `certs.files` | External Secrets + Vault |
| `testbed-patches` | projected from Vault as a Secret |
| `bootstrap-db.py` hook | explicit `run-bootstrap-db.sh` step (see Ordering) |
| `testbed-configs` + cfg switch | per-component values in `base/values/`, endpoints via Vault |
| vendored `rucio-daemons` | upstream chart + values; post-render patch only where unavoidable |

### Argo CD → Flux mapping

| Argo construct | Flux equivalent |
|---|---|
| ApplicationSet (list generator) | directory of HelmRelease + per-env Kustomization |
| Application (chart + values) | HelmRelease (`chart.spec.sourceRef` + `valuesFrom`) |
| `repoURL: <chart repo>` | HelmRepository (one per registry) |
| `$values` multi-source valueFiles | `HelmRelease.valuesFrom` → ConfigMap |
| `repoURL: <git> path: <chart>` | HelmRelease with GitRepository sourceRef |
| `repoURL: <git> path: <dir>` (bootstrap) | Flux Kustomization (`path:`) + `dependsOn` |
| sync-wave ordering | `dependsOn` (HelmRelease / Kustomization) |
| app-of-apps root | one env Kustomization aggregating components + secrets |
| `destination.namespace` | `targetNamespace` |
| `automated{prune,selfHeal}` | default in Flux |
| `fullnameOverride` | same, carried over verbatim |

Flux Kustomizations have no cross-directory load restrictor, so a shared
components directory referenced from env overlays works natively (Argo rejects
it); that keeps the Flux side DRY without ApplicationSet templating.

### Environment ladder

Selected with `GITOPS_ENV`:

1. **Sandbox**: everything internal (Keycloak, XRootD, Teapot, PostgreSQL, dev
   Vault seeded by script, self-signed CA, `managed` token flow). Ephemeral;
   the path validated in CI.
2. **Staging**: external IdP and Vault (Kubernetes auth, operator-seeded);
   externalised components are omitted and their endpoints parameterised.
3. **Production**: staging shape plus external storage and HA (scaled
   server/daemons, real DNS/ingress, partner Vault).

### Component selection and endpoints

Components are selected **by presence**, not a toggle schema: which elements
the env's ApplicationSet lists (Argo) or the env kustomization includes (Flux).
The substance of "disable a chart" is pointing its dependents at the external
endpoint, e.g. an external IdP means setting the Rucio OIDC issuer, FTS
`fts3restconfig` and RSE `audience`. Those values live in `base/values/` and
the per-env secrets overlay, so an endpoint change is an overlay edit.

### Secrets

- In-cluster Vault (sandbox) or external Vault (staging/production); the charts
  don't care which.
- External Secrets Operator reconciles first; a `ClusterSecretStore` (same name
  across envs) targets the env's Vault; ExternalSecrets project certs, configs,
  patches and the Rucio config into native Secrets the charts mount.
- Sandbox seeds its dev Vault with `seed-vault.sh` (clones the repo at the
  bootstrapped revision, generates runtime certs, `vault kv put`).
  Staging/production Vaults are seeded out-of-band by an operator.

### Ordering

Enforced by the bootstrap scripts, not by GitOps primitives:

`apps root applied → Vault + ESO waited on by name → secrets root applied →
seed-vault.sh (Vault pod Ready) → run-bootstrap-db.sh (ruciodb Service exists)
→ everything else self-heals via mount retry + selfHeal`

The bootstrap Job mounts ESO-projected Secrets, and a missing Secret is a
kubelet mount failure, so the Secret must exist before the Job's pod is created.

## Touch points

| File / component | Change |
|---|---|
| `deploy/gitops/base/` | engine-agnostic values and ExternalSecrets |
| `deploy/gitops/environments/<env>/secrets/` | per-env `ClusterSecretStore` + ExternalSecrets |
| `deploy/gitops/argocd/` | ApplicationSets + app-of-apps entrypoints |
| `deploy/gitops/flux/` | HelmReleases, HelmRepositories, ESO Kustomization, env entrypoints |
| `init-argocd.sh`, `init-flux.sh` | bootstrap and ordering (`--revision`, `--flow`, `--scope-profile`) |
| `shared/scripts/seed-vault.sh` | sandbox Vault seeding |
| `shared/scripts/run-bootstrap-db.sh` | Rucio DB schema bootstrap |
| `Makefile` | `argocd-install/-uninstall/-open`, `flux-install/-uninstall` |
| `docs/diagrams/` | deployment views per environment |

## Fallback / safety behavior

- **Missing Secret at pod start:** kubelet mount retry; workloads converge once
  ESO projects it, no manual restart.
- **Missing DB schema:** `rucio-daemons` crash-loop on the missing `heartbeats`
  table until `run-bootstrap-db.sh` runs, then recover via restart backoff.
- **No external Vault/DB/IdP (staging/production):** the environment does not
  converge; this is expected and tracked in `BACKLOG.md`, never silently
  substituted by bundled components.
- **CRDs bundled in charts** (e.g. ESO, kube-prometheus-stack): applied with
  `ServerSideApply=true` so large CRDs don't hit annotation size limits.
- **Stable names:** `fullnameOverride` keeps Service names identical across Helm,
  Argo CD and Flux, so in-cluster endpoints don't depend on the engine.

## Testing

- CI deploys the sandbox via Argo CD and Flux and runs the Rucio E2E transfer
  tests against it.
- Locally: `make argocd-install` / `make flux-install` with `GITOPS_ENV=sandbox`,
  then `make test-rucio-transfers` (and `make test-observability` when enabled).
- `make helm-lint` / `make helm-template` for rendering regressions.

## Sequencing

1. Sandbox on both engines, validated in CI (done).
2. Staging/production overlays authored (done); converge once external
   Vault/DB/IdP exist.
3. Provision the externals (Terraform; GCP staging in progress).
4. Ship the runbooks (entry point `deploy/gitops/README.md`):
   1. sandbox quickstart (done);
   2. bring your own IdP;
   3. bring your own storage;
   4. secrets with Vault;
   5. the Rucio configs that matter.

## Open questions

- **Ordering primitives.** Both declarative options were tried and removed:
  sync-waves have no effect across independent ApplicationSet-generated
  Applications (components were `ContainerCreating` before Vault/ESO existed),
  and a `dependsOn`+healthCheck-gated bootstrap Job deadlocks (it waits for
  `rucio-daemons` Healthy, which needs the schema the Job creates). Revisit if
  either engine gains a primitive for this dependency shape.
- **Per-RI deployment.** RI-SCALE has four use cases, each likely needing its own
  staging/production with its own Vault, IdP and storage:
  - **A, fork/template per RI:** cheapest to onboard, but `base/` drifts and
    a fix needs one merge per fork.
  - **B, one repo, per-RI overlays (`environments/ri-<name>-{staging,production}/`),
    `base/` version-pinned:** a fix is a pin bump; a new RI is one directory.

  B is the proposed default and A the fallback for partners needing repo-level
  isolation. Either way: one `ClusterSecretStore` per RI, never shared.
- **Ingress / API gateway** in front of Rucio (WAF, rate limiting, auth
  pre-filtering): open; GCP staging uses the GKE Gateway for now.

## References

- Kustomize: https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/
- Argo CD app-of-apps: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- Argo CD ApplicationSet: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Flux HelmRelease: https://fluxcd.io/flux/components/helm/helmreleases/
- External Secrets Operator: https://external-secrets.io/latest/ (Vault provider: https://external-secrets.io/latest/provider/hashicorp-vault/)
- Alternatives: Vault Agent injector https://developer.hashicorp.com/vault/docs/platform/k8s/injector, SOPS https://fluxcd.io/flux/guides/mozilla-sops/, cert-manager https://cert-manager.io/docs/
- The Twelve-Factor App, config: https://12factor.net/config
