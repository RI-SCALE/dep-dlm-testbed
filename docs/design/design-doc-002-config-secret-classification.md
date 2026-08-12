# Design-002: Config/Secret Classification for Testbed Config

- **Status:** Proposed
- **Owner:** DEP DLM testbed
- **Related ADR(s):** [ADR-004: Classify Testbed Config by Sensitivity
  (ConfigMap vs Secret)](../adrs/adr-004-classify-testbed-config-by-sensitivity.md)

## Problem

`testbed-configs` is a `configMap:` volume source in the umbrella chart
but a `secret:` volume source in GitOps, for the same logical content —
drift introduced when ESO (Secret-only) took over provisioning without a
per-file sensitivity review. Most of that content is genuinely
non-sensitive, but not all of it — see Classification below.

## Classification

Per-file review of everything currently under `testbed-configs`
(`shared/config/{fts,keycloak,rucio,teapot,xrootd}/`):

| File | Classification | Note |
|---|---|---|
| `fts/fts3config` | **Non-sensitive (sandbox) / Sensitive (staging, production)** | Sandbox's static file has no credentials; staging/production render this file from `fts3config.tftpl`, which embeds `fts_db_password` — confirmed via grep, not assumed. Same filename, different sensitivity by environment. |
| `fts/{managed,unmanaged}.fts3restconfig` | Non-sensitive | No credentials |
| `fts/gfal2_http_plugin.conf` | Non-sensitive | No credentials |
| `keycloak/realm.json` | **Sensitive** | Embeds real client secrets (`rucio-secret`, `fts-secret`, `xrd3-secret`, etc.) — was misclassified as non-sensitive originally |
| `xrootd/authdb` | Non-sensitive | Access rule only, no credentials |
| `xrootd/scitokens.conf` | Non-sensitive | Issuer/audience list only |
| `xrootd/xrdrucio-scitokens.cfg` | Non-sensitive | Cert *paths*, not cert material |
| `teapot/application.yml` | Non-sensitive | Issuer + authz policy only |
| `teapot/config.ini` | Non-sensitive | No credentials |
| `teapot/data.properties` | Non-sensitive | No credentials |
| `teapot/logback.xml` | Non-sensitive | Logging config only |
| `teapot/user-mapping.csv` | Non-sensitive | Subject IDs, not secrets (pseudonymous — fine as ConfigMap, but avoid treating as fully public if that changes) |
| `rucio/userpass-client.cfg` | **Sensitive** | Contains `password = secret` — was misclassified as non-sensitive originally |

Files **not** in `testbed-configs`, unaffected by the ConfigMap/Secret
classification (already correctly Secret): `testbed-certs`,
`server.cfg`/`alembic.ini`/`idpsecrets.json` (currently `rucio-server-cfg`
— object-level restructuring covered under Naming conventions below,
not a sensitivity change), `testbed-patches`.

Net effect: `realm.json` and `userpass-client.cfg` stay Secret. Everything
else in the list above is in scope to become a plain ConfigMap.

## Naming conventions

Existing shared objects follow `testbed-<category>` (`testbed-certs`,
`testbed-configs`, `testbed-scripts`, `testbed-patches`, `testbed-tests`).
`rucio-server-cfg` breaks that pattern deliberately, since it's
rucio-server-specific rather than shared — that part is fine.

**Adopt `testbed-configs` / `testbed-secrets` as the generic pair for
this migration:** `testbed-configs` names the ConfigMap (all files
classified non-sensitive above); `testbed-secrets` names the Secret
holding the residual sensitive files (`realm.json`,
`userpass-client.cfg`) that used to ride along under the same name,
`testbed-configs`, when it was a Secret. This closes the actual naming
gap that made the ConfigMap/Secret drift confusing in the first place —
the same name backing two different object kinds across deployment
paths — by giving each kind its own name, consistently, everywhere.

`testbed-secrets` follows the same `-<scopeProfile>` suffix convention
as `testbed-configs` (`testbed-secrets-<scopeProfile>` for non-`local`
profiles), for the same reason: whichever profile-specific content ends
up in it.

`testbed-certs` and `testbed-patches` are **not** folded into
`testbed-secrets`. They already have clear, self-descriptive names, and
merging them would recreate the same RBAC blast-radius problem this
migration is narrowing — unrelated cert material and unrelated IdP
secrets under one grant, the same reasoning applied to `rucio-server-cfg`
below.

**`rucio-server-cfg` is eliminated, not left as-is.** It was previously
assumed to be rucio-server-specific, justifying its off-pattern name —
that's wrong: `rucio-daemons` mounts the identical three subPaths
(`server.cfg`, `alembic.ini`, `idpsecrets.json`) from the same object. It
was never component-scoped, just mislabeled, which is reason enough to
fold it into the shared `testbed-*` convention. All three files —
including `idpsecrets.json`, despite carrying real external IdP client
secrets for `egi-dev`/`ls-aai-dev` once seeded — join `testbed-secrets`
alongside `realm.json` and `userpass-client.cfg`. Everything sensitive
in this migration's scope lands in one Secret, by design, not split
further.

`volumeName`s stay as previously proposed (`rucio-cfg-server`,
`rucio-cfg-alembic`, `rucio-cfg-idpsecrets`) — pod-spec-local labels,
unaffected by which object they source from. All three now point at
`secretFullName: testbed-secrets`.

## Goals

- Every file classified non-sensitive above is authored and applied as
  a plain GitOps ConfigMap (`testbed-configs`), no Vault/ESO involvement.
- `realm.json` and `userpass-client.cfg` move to a newly-named Secret,
  `testbed-secrets`, replacing their current home under the
  Secret-backed `testbed-configs`.
- `rucio-server-cfg` is eliminated: `server.cfg`, `alembic.ini`, and
  `idpsecrets.json` all join `testbed-secrets`. `testbed-certs` and
  `testbed-patches` are untouched.
- The umbrella chart's `configs-cm.yaml` / `rucio-cfg-secrets.yaml`
  templates are updated to match — they currently bundle `realm.json`
  and `userpass-client.cfg` into the ConfigMap too, the same drift this
  doc fixes on the GitOps side.
- No pod-visible behavior change: mount paths, subPaths, and rendered
  content are identical before and after.
- Each environment migrates independently, not as one atomic cutover.

## Non-goals

- Reclassifying anything already correctly a Secret.
- Schema/CI enforcement of sensitivity classification — a natural
  follow-up once this migration's file set exists to validate a schema
  against, not required to land this.
- Changing `scopeProfile`-based content selection — unaffected by which
  object kind backs it.

## Design

Per environment, per non-sensitive file:

1. Author the content as a ConfigMap manifest (or `configMapGenerator`)
   in `deploy/gitops/environments/<env>/`, keyed the same way the
   current Vault path is keyed (`local` vs `<scopeProfile>`).
2. Flip that file's volume source in the shared values overlays (`fts`,
   `keycloak`, `xrd3`, `xrd4`, `rucio-client`) from `secret:
   secretName: testbed-configs` to `configMap: name: testbed-configs`,
   for that environment only. `realm.json` and `userpass-client.cfg` are
   excluded from this flip — their volume source stays `secret:`, but
   `secretName` changes from `testbed-configs` to `testbed-secrets`.
3. Once step 2 is confirmed working, remove that file's `ExternalSecret`
   and Vault path. Don't remove the Vault path first.

Separately, per environment: retarget `rucio-cfg-server`,
`rucio-cfg-alembic`, and `rucio-cfg-idpsecrets`'s `secretFullName` from
`rucio-server-cfg` to `testbed-secrets`, **in both `rucio-server` and
`rucio-daemons`** — both mount the identical three subPaths today. Once
both are confirmed working, retire the `rucio-server-cfg` object and its
`ExternalSecret`. Same change applies to the umbrella chart's
`rucio-cfg-secrets.yaml` template.

## Touch points

| File / component | Change |
|---|---|
| `deploy/gitops/environments/<env>/values/{fts,keycloak,xrd3,xrd4,rucio-client}.yaml` | Volume source `secret:` → `configMap:` for non-sensitive files; `secretName: testbed-configs` → `testbed-secrets` for `realm.json`/`userpass-client.cfg` |
| `deploy/gitops/environments/<env>/values/{rucio-server,rucio-daemons}.yaml` | `secretFullName: rucio-server-cfg` → `testbed-secrets` for all three files, both components |
| `deploy/gitops/environments/<env>/secrets/testbed-configs.yaml` | Narrowed to just `realm.json`/`userpass-client.cfg`, renamed to target `testbed-secrets` |
| `deploy/gitops/environments/<env>/secrets/rucio-server-cfg.yaml` | Removed; its three keys added to the `testbed-secrets.yaml` above |
| `deploy/gitops/environments/<env>/secrets/kustomization.yaml` | Drop `rucio-server-cfg.yaml` ref; add new ConfigMap manifest(s) |
| `deploy/gitops/environments/<env>/configs/` (new) | New ConfigMap manifests for the non-sensitive files |
| `shared/scripts/seed-vault.sh` | Retarget from `rucio-server-cfg` path to `testbed-secrets`; stop seeding files now GitOps-static |
| `deploy/terraform/modules/secrets/rucio.tf`, `outputs.tf`, `variables.tf` | Output/variable names tied to `rucio-server-cfg` → `testbed-secrets` |
| `deploy/terraform/modules/secrets/configs.tf` | Confirmed via grep: `fts3config.tftpl` embeds `fts_db_password` — stays Vault-routed for staging/production only. `fts3-docker-entrypoint.sh.tftpl`/`fts3rest.conf.tftpl` interpolate non-secret values (`fts_db_host`, `log_level`) but were never in this migration's scope |
| `deploy/helm-charts/dep-dlm-testbed/templates/configs-cm.yaml` | Exclude `realm.json`, `userpass-client.cfg` |
| `deploy/helm-charts/dep-dlm-testbed/templates/rucio-cfg-secrets.yaml` | Produces `testbed-secrets`, now also carrying `realm.json`, `userpass-client.cfg` |
| `deploy/helm-charts/dep-dlm-testbed/values.yaml` | `keycloak`/`rucio-client`/`rucio-server`/`rucio-daemons` blocks retargeted to match |

## Fallback / safety behavior

- Any file not yet reviewed defaults to Secret (ADR-004).
- Per-file, per-environment volume source is a static choice — no
  shared toggle, so environments migrate independently.
- Once all environments are migrated, add a CI check diffing the
  umbrella's declared volume-source kind against each environment's
  overlay, to catch future drift.
- `rucio-server-cfg` retirement touches two components at once
  (`rucio-server`, `rucio-daemons`), plus the umbrella chart's own
  template — retarget all three before removing the old object, not
  one-then-the-other, since a half-migrated state leaves something
  pointing at a soon-to-be-deleted Secret.

## Testing

- `helm template` diff per environment: only the migrated files' object
  kind and volume-source stanza change.
- `kustomize build deploy/gitops/environments/<env>/secrets` per
  environment, for every environment, before merge. An initial
  implementation pass caught exactly the kind of mistake this step exists
  to prevent: a per-environment file silently missing (production's
  `testbed-secrets.yaml`), a wrong namespace copy-pasted from another
  environment, and a `configMapGenerator` split across two files in a way
  Kustomize can't actually resolve. None of these are visible from reading
  the diff casually — `kustomize build` fails loudly on all three.
- Existing environment CI (`egi-dev`, sandbox e2e) passing is the live
  regression signal.

## Sequencing

1. Sandbox, file by file from the Classification table, then the
   `rucio-server-cfg` split (`rucio-server` and `rucio-daemons` both).
2. Staging, once sandbox is clean. `fts3config` excluded from the
   ConfigMap flip here — stays Secret, Terraform-rendered, since it
   embeds `fts_db_password`.
3. Production, once staging is clean. Same `fts3config` exclusion.
4. Add the drift-detection CI check.

## Open questions

- Formal schema/CI enforcement for classification — worth it once this
  migration's file set exists to validate against.
- Should `user-mapping.csv`'s subject-ID content get a lighter
  "internal-only" ConfigMap annotation/RBAC note, given it's
  pseudonymous identifier data rather than fully public config?

**Resolved:** the `.tftpl` question above is answered — confirmed via
`grep '\${' deploy/terraform/modules/secrets/templates/*.tftpl`.
`fts3config.tftpl` embeds `fts_db_password`; every other template in
scope interpolates only non-secret values. `fts3config` for
staging/production is excluded from the sandbox-only ConfigMap flip in
Sequencing below.
