# Runbook 6 — Adding a New IdP / SCOPE_PROFILE

## Purpose
Generalizes the egi-dev work into a repeatable checklist for validating the
testbed against a *different* external IdP (another EGI Check-In-style
federation, a site Keycloak, etc.) without touching the `local` profile.

Read runbook 02 first — this doc only lists *where things go*; runbook 02
covers *why* (the two-client model, CA trust, token_strategy caveats).

## The pattern

A `SCOPE_PROFILE` is a name (e.g. `egi-dev`) that selects a parallel set of
config files alongside the `local` defaults. Compose resolves the profile via
`CONFIG_PROFILE_DIR` (Makefile-derived, empty for `local`); Helm resolves it
via `global.scopeProfile` + the per-profile ConfigMap
(`testbed-configs-<profile>`, see `configs-cm.yaml`). Both read from the same
`<profile>/` subdirectories under `shared/config/`.

To add a profile named `<profile>`, create `<profile>/` subdirectories and
files as listed below — nothing outside `shared/config/` needs a new file,
only edits to reference the new profile name where noted.

## 1. Config files to add (mirror egi-dev's layout exactly)

| Directory | Files to add under `<profile>/` |
|---|---|
| `shared/config/rucio/` | `idpsecrets.json`, `oidc-client.cfg`, `server.client-credentials.cfg`, `server.token-exchange.cfg` (only if the new IdP supports RFC 8693 token-exchange with `resource=` — see runbook 02's caveat before assuming it does) |
| `shared/config/fts/` | `fts3config`, `managed.fts3restconfig`, `unmanaged.fts3restconfig` |
| `shared/config/teapot/` | `config.ini`, `application.yml`, `data.properties`, `user-mapping.csv` |
| `shared/config/xrootd/` | `scitokens.conf` |

Copy the `egi-dev/` version of each as a starting point and edit:
issuer URL, audience/`resource=` targets, `trusted_OP` (teapot), scitokens
`issuer`/`base_path` (xrootd), and — critically — **leave `user-mapping.csv`
with placeholder subs**; real subs get added per-tester as identities are
mapped (see runbook 02 Step 3), the same way `aa886829a0...@egi.eu` was
added for egi-dev.

## 2. `idpsecrets.json` — do not commit real secrets

The checked-in file must keep `<valid client id>` / `<valid client secret>`
placeholders (same convention as `shared/config/rucio/egi-dev/idpsecrets.json`).
`.gitignore` does **not** exclude `*.json`, so this file *is* tracked —
real credentials go in only on the machine/cluster running the test, and are
re-seeded via Vault or `helm --set`, never committed.

## 3. Certs

If the new IdP's TLS chain isn't already covered by the system CA bundle
(unlikely for a real public IdP, common for another self-signed testbed),
regenerate the combined bundle the way egi-dev's
`shared/config/rucio/egi-dev/rucio_ca.pem` was built: system roots + the
internal Rucio Dev CA + the new issuer's chain. Do **not** add a full
`<profile>/rucio_ca.pem` to `certs/` — that directory stays profile-agnostic
(see `.gitignore`: everything under `certs/*.pem` is ignored except
`rucio_ca.key.pem`, `rucio_ca.pem`, `tls_ca_bundle.pem`); keep any
profile-specific combined bundle under `shared/config/rucio/<profile>/` as
egi-dev does, and copy it over `certs/rucio_ca.pem` only at test time
(never commit the copy).

## 4. Wiring — where `<profile>` needs to be *referenced*, not just placed

Nothing in `deploy/` needs new *files* for a new profile — the umbrella Helm
chart's `configs-cm.yaml` already globs `files/configs/*/<any-profile>/*`
generically, and every `deploy/compose/docker-compose.*.yml` already resolves
config paths through `${CONFIG_PROFILE_DIR}`, so compose needs zero edits.
A few places do need a one-line addition:

- `deploy/helm-charts/dep-dlm-testbed/templates/configs-cm.yaml` —
  the `{{- range $profile := list "egi-dev" }}` loop is currently hardcoded
  to one profile name; add `"<profile>"` to that list so its per-profile
  ConfigMap actually renders.
- `deploy/gitops/environments/sandbox/secrets/seed-job.yaml` — **this one is
  not runtime-configurable.** Its own header comment states `SCOPE_PROFILE`
  is static: "there is no CLI flag or kustomize patch wired up to override
  it at deploy time. To change it, edit the env value here directly and
  commit." So the gitops/ArgoCD-or-Flux path needs a real, committed edit
  to this file's `SCOPE_PROFILE` env value before a new profile takes
  effect — unlike compose (env var) or direct `helm install` (`--set
  global.scopeProfile=...`), both resolved purely at invocation time.
- `.github/workflows/` — if the new profile needs its own CI (mirroring
  `egi-dev.yml`), copy that workflow, set `scope_profile: <profile>` and
  `token_modes` appropriately (start with `["unmanaged"]` unless you've
  confirmed the IdP supports `resource=` on `token-exchange`).

Everything else — `Makefile`'s `CONFIG_PROFILE_DIR` derivation, the seed-job's
`$PDIR` computation *once `SCOPE_PROFILE` above is set*, `init-testbed.sh`'s
`$SCOPE_PROFILE` branches — already takes the profile name as a variable and
needs no code changes.

## 5. Validate

Follow runbook 02's Verification section end to end (CA-trust check, daemon
client_credentials check, TPC `gfal-copy` script, interactive `whoami` +
upload) with `RUCIO_CONFIG` pointed at
`shared/config/rucio/<profile>/oidc-client.cfg` and
`SCOPE_PROFILE=<profile>` exported before `make init`/`make start`.

## Checklist summary

- [ ] `shared/config/{rucio,fts,teapot,xrootd}/<profile>/*` created from egi-dev templates
- [ ] `idpsecrets.json` has placeholders only, real values injected out-of-band
- [ ] Combined CA bundle built if the new issuer isn't system-trusted
- [ ] `<profile>` added to `configs-cm.yaml`'s per-profile ConfigMap loop
- [ ] (gitops runtime only) `seed-job.yaml`'s `SCOPE_PROFILE` env edited and committed
- [ ] (Optional) new CI workflow copied from `egi-dev.yml`
- [ ] Runbook 02's Verification steps all pass under the new profile
