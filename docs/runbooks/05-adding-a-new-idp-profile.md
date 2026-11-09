# Runbook 5 — Adding a new IdP / SCOPE_PROFILE

## Purpose
A repeatable checklist for validating the testbed against another external
IdP (an EGI Check-In-style federation, a site Keycloak, …) without touching
the `local` profile. Read [runbook 02](02-bring-your-own-idp.md) first: it
explains *why* (two-client model, CA trust, token strategies); this runbook
lists *where things go*.

## The pattern
A `SCOPE_PROFILE` (e.g. `egi-dev`, `ls-aai-dev`) selects a set of config files
under `configs/<component>/<profile>/` that overlay the `local` defaults. All
runtimes resolve it generically:

- **Compose:** `CONFIG_PROFILE_DIR`, derived by the Makefile.
- **Helm:** `global.scopeProfile`; `testbed-configs.yaml` and
  `testbed-secrets.yaml` overlay the profile's files.
- **GitOps (sandbox):** `SCOPE_PROFILE=<profile>` at `make argocd-install` /
  `make flux-install`, rendered into `scripts/k8s/vault-seed-job.yaml.tmpl`.

So a new profile needs new files under `configs/`, plus a few explicit
references in the Makefile and CI (§4).

## 1. Check the IdP's token shape
Find the `token_endpoint` in `<issuer>/.well-known/openid-configuration`,
mint a `client_credentials` token and decode it:

```bash
curl -s -u "<client_id>:<client_secret>" \
  -d grant_type=client_credentials -d scope=openid <token_endpoint>
```

Once the profile is wired into the Makefile (§4),
`make verify-idp-token SCOPE_PROFILE=<profile>` does this and more. Check:

- **`iss`, including any trailing slash.** Every value compared against the
  issuer (`idpsecrets.json` key, `rucio.cfg`, Teapot's `trusted_OP`,
  XRootD's `scitokens.conf`) must match it exactly; see "OIDC issuer string
  consistency" in [patches.md](../patches.md). This is the most common
  onboarding bug.
- **`typ` header.** For `at+jwt` (RFC 9068), Storm-WebDAV needs an
  `audiences:` list under `oauth.issuers[]` in Teapot's `application.yml`, and
  `STORM_VERSION` in `deploy/compose/Dockerfile.teapot` must be ≥ 1.13.0.
  Otherwise every WebDAV request fails with 401
  `the given typ value needs to be one of [JWT]`.
- **`sub`.** Note it; Teapot needs it in §2.

## 2. Config files
Copy each file from `egi-dev/` and adapt the issuer URL, audiences and
`resource=` targets, Teapot's `trusted_OP` and XRootD's `issuer`/`base_path`.

| Directory | Files under `<profile>/` |
|---|---|
| `configs/rucio/` | `idpsecrets.json.example`, `oidc-client.cfg`, `server.client-credentials.cfg`, `server.token-exchange.cfg` (only if the IdP supports RFC 8693 token exchange with `resource=`; see runbook 02) |
| `configs/fts/` | `fts3config`, `managed.fts3restconfig`, `unmanaged.fts3restconfig` |
| `configs/teapot/` | `config.ini`, `application.yml`, `data.properties`, `user-mapping.csv` |
| `configs/xrootd/` | `scitokens.conf` |

`user-mapping.csv` needs a row for the client's own `client_credentials`
`sub` from §1: the Teapot test fixtures authenticate as the client and
otherwise fail with "local user for sub claim … does not exist". Add tester
subs later, as identities are mapped (runbook 02).

If the IdP's scopes don't match the WLCG defaults (no `fts` scope, or no
path-scoped `storage.read:/…` scopes), set `fts_client_scope` and
`scope_map`/`drop_scopes` in the issuer's `capabilities` block; see
"Per-issuer OIDC capabilities" in [patches.md](../patches.md).

## 3. Secrets and certificates
- **`idpsecrets.json`:** track only `idpsecrets.json.example` with the
  `<valid client id>` / `<valid client secret>` placeholders. Create the
  real file locally (`cp …/idpsecrets.json.example …/idpsecrets.json`) and
  never commit it. `.gitignore` lists each profile's file individually: add
  `configs/rucio/<profile>/idpsecrets.json`, or replace the entries with
  `configs/rucio/*/idpsecrets.json`.
- **CA trust:** public IdPs are normally covered by the system CA bundle.
  For a self-signed IdP, build a combined bundle (system roots, the Rucio dev
  CA, the issuer's chain) outside `certs/`, and copy it over
  `certs/rucio_ca.pem` only at test time. Never commit the copy.

## 4. References outside `configs/`
- **`Makefile`:** `TEST_OIDC_ENV` and the `verify-idp-token` target branch on
  `SCOPE_PROFILE`; add the profile to both. Make sure `OIDC_TOKEN_URL` is
  exported, otherwise `conftest.py` falls back to a Keycloak-shaped default.
- **CI (optional):** copy `egi-dev.yml` or `ls-aai-dev.yml` and set
  `scope_profile: <profile>`. Start with `token_modes: '["unmanaged"]'`
  unless the IdP supports `resource=` on token exchange and FTS's
  refresh-token exchange. Then add the profile to the per-profile mappings in
  `_run-dep-dlm-testbed.yml` (`OIDC_ISSUER`, `OIDC_TOKEN_URL`,
  `OIDC_EXPECTED_SCOPE`, `OIDC_IDENTITY_SUB`, and the condition on the
  *Render idpsecrets.json* step) and, for staging, in `_e2e-test.yml`.

## 5. Verify
Run runbook 02's Verification section end to end (CA trust, daemon
`client_credentials`, TPC `gfal-copy`, interactive `whoami` and upload) with
`SCOPE_PROFILE=<profile>` exported before `make start` / `make init` and
`RUCIO_CONFIG=configs/rucio/<profile>/oidc-client.cfg`.

## Checklist
- [ ] Token decoded: `iss` (trailing slash), `typ` (`at+jwt`?), client `sub`
- [ ] `configs/{rucio,fts,teapot,xrootd}/<profile>/` created from `egi-dev/`
- [ ] `user-mapping.csv` has the client's `sub` (tester subs later)
- [ ] `fts_client_scope` / `scope_map` / `drop_scopes` set if scopes differ from WLCG
- [ ] Only `idpsecrets.json.example` tracked; `.gitignore` covers the real file
- [ ] Combined CA bundle built, if the issuer isn't system-trusted
- [ ] If `typ: at+jwt`: Storm-WebDAV ≥ 1.13.0 and `audiences:` set
- [ ] `Makefile`: `TEST_OIDC_ENV` (incl. `OIDC_TOKEN_URL`) and `verify-idp-token`
- [ ] (Optional) CI workflow plus per-profile mappings in `_run-dep-dlm-testbed.yml` / `_e2e-test.yml`
- [ ] Runbook 02's Verification passes under the new profile
