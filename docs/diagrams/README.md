# Deployment-View Diagrams

Generated, not hand-drawn. The source of truth is code (`deploy/gitops/`),
the diagram is a rendering of it, not an independent artifact that can drift.

## Regenerate

```bash
pip install diagrams --break-system-packages
apt-get install -y graphviz   # provides the `dot` binary diagrams shells out to
cd docs/diagrams
python3 sandbox.py
python3 staging.py
python3 production.py
```

Each script writes its PNG to `generated/`. Commit the PNGs alongside the
`.py` source so the diagrams render on GitHub without anyone needing to run
Python locally.

## What the three diagrams show

The progression is the point: same architecture, decreasing internal
footprint, increasing scale.

| | Sandbox | Staging | Production |
|---|---|---|---|
| IdP | bundled Keycloak, self-signed CA | external (EGI Check-In / LS AAI / partner) | external |
| Vault | in-cluster dev, seeded by Job | partner-operated, K8s auth | partner-operated |
| PostgreSQL | in-cluster | managed/external | managed/external |
| Storage RSEs | bundled XRootD + Storm-WebDAV | external source/destination RSEs | external source/destination RSEs |
| Rucio server/daemons | single replica | single replica | scaled |
| Gateway API / TLS | — (test harness only) | TLS (staging domain, staging/internal CA) | TLS (real public DNS, CA trusted by partner clients) |

**Ingress controller or Gateway API (WAF, rate limiting, auth
pre-filtering ahead of Rucio's own OIDC check) are both open questions,
deliberately not modeled**, since picking one (e.g.
Traefik vs. a cloud-native Gateway API, with or without an API gateway in
front) is a real decision that should happen once, not be implied by
diagram omission.

## Who consumes each environment

| Environment | Primary stakeholder | Purpose |
|---|---|---|
| Sandbox | Developers | Iterate on patches/config locally, no external dependencies to coordinate |
| Staging | DEP DLM / RI integration engineers | Validate a specific RI's end-to-end scenario against real external Vault/IdP/storage before it's trusted with real data |
| Production | RI end users (researchers, downstream services) | Real transfers, real data, real SLAs — nothing here should be a surprise if staging validated the same shape first |

**Staging and production are deliberately drawn near-identical** — per the
GitOps blueprint's environment ladder, staging already externalizes
everything except the Rucio+FTS data-orchestration core; production keeps
that same shape and only adds scale (replica count) and a real Gateway API/DNS
front door. If a future revision of the blueprint puts a real structural
difference between the two (not just scale), split `production.py` further
rather than letting the two silently drift apart while still claiming to be
"the same shape."

## On Terraform / public-cloud provisioning

Staging and production currently assume the external Vault, DB, IdP, and
storage endpoints already exist and are wired in via the environment
overlay (`deploy/gitops/environments/{staging,production}/secrets/`) — see
`docs/gitops-blueprint.md`'s environment ladder. The stated next step is
provisioning those externals themselves via Terraform against a public
cloud, so staging/production can be stood up end-to-end rather than
assuming pre-existing infrastructure. These three diagrams show the
*consumption* side (what the GitOps layer expects to already exist); a
Terraform-provisioning diagram would be a natural fourth, showing the
*supply* side (Vault/DB/IdP/storage instances being created) — worth adding
once that Terraform work has an actual shape to diagram, rather than
speculating on it now.

## On RI-SCALE needing four deployments per use case

The reasonable reading, given the blueprint's explicit goal ("let partners
deploy and operate their own DEP DLM layer") and RI-SCALE being a multi-RI
research infrastructure project, is that the staging/production shape shown
here gets **instantiated independently once per use case** — each with its
own external Vault, IdP, and storage endpoints — rather than one shared
staging/production pair serving all four.

Secrets should be isolated per RI by construction: a distinct
`ClusterSecretStore` per RI, never shared, extending the same isolation
pattern already used per-environment in `environments/*/secrets/`.

**Recommended:** one repo, `base/` version-pinned, environments grow
per-RI (Option B below).** This is the standard shape for this kind of
fan-out — Terraform's module-registry pattern, Helm library charts, Argo
CD's own multi-cluster app-of-apps guidance all converge on "shared
library referenced by pin, thin per-tenant overlay," not "fork the whole
tree per tenant." A `base/` security fix becomes a per-RI pin bump, not
four manual merges, and onboarding RI #5 is one overlay directory, not a
new repo to keep in sync forever. The fork/template shape (Option A) is
documented below as the fallback for a partner who genuinely needs
repo-level separation (their own CI, their own access control) — worth
supporting, just not the default.

**A — Fork/template per RI.** Each RI clones the whole tree; `base/` drifts
independently per fork.

```
dep-dlm-gitops/                     ← template repo
├── argocd/ base/ flux/
└── environments/{sandbox,staging,production}/secrets/

ri-bbmri/dep-dlm-gitops/            ← RI #1's fork, own Vault
ri-enes/dep-dlm-gitops/             ← RI #2's fork, own Vault
ri-eiscat/dep-dlm-gitops/           ← RI #3's fork, own Vault
ri-bioimaging/dep-dlm-gitops/       ← RI #4's fork, own Vault
```

Cheapest to onboard a new RI (click template); no shared-version visibility
— a `base/` security fix requires four manual merges.

**B — One repo, per-RI environment overlays.** `base/` stays single-copy,
version-pinned; each RI gets its own overlay directory instead of its own
repo.

```
dep-dlm-gitops/
├── base/                                    ← shared, tagged (v1.4.0, ...)
├── argocd/ or flux/
└── environments/
    ├── sandbox/secrets/
    ├── ri-bbmri-staging/secrets/        ri-bbmri-production/secrets/       ← own Vault
    ├── ri-enes-staging/secrets/         ri-enes-production/secrets/        ← own Vault
    ├── ri-eiscat-staging/secrets/       ri-eiscat-production/secrets/      ← own Vault
    └── ri-bioimaging-staging/secrets/   ri-bioimaging-production/secrets/  ← own Vault
```

Same secrets isolation as A (each RI's `ClusterSecretStore` targets its own
Vault, or its own KV path if sharing infra), but `base/` fixes are a pin
bump per RI, not a merge, and a 5th RI is one overlay directory, not a new
repo.

B needs a version-pin discipline partners must actually follow — worth
weighing against A's lower onboarding friction if a specific RI genuinely needs full repo isolation, but B is the default starting point.
