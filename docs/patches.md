# Patches

Minimal patches to upstream components enabling OIDC-only token-based
transfers (X.509/GSI is out of scope). Each patch is bind-mounted (Compose)
or ConfigMap-mounted (Kubernetes) over the original file.

## Files touched

| File | Component | Essential change |
|---|---|---|
| `rucio/oidc.py` | Rucio | Adds an account-based RFC 8693 token-exchange subsystem not present upstream (`get_token_for_account_operation`, `__exchange_token_oidc`, `__get_admin_token_oidc`, `__get_admin_account_for_issuer`); fixes discovery-URL construction; adds `aud:<audience>` scope-append for `client_credentials`; per-issuer, per-grant-type `resource=`/`audience=` selection via `get_capabilities()` (see below); `save_subject_token()` seeding helper; promotes silent failures to WARNING |
| `rucio/fts3.py` | Rucio | Passes `account` + per-RSE `audience` to `request_token` (upstream has neither); sets `unmanaged_tokens` from `oidc.token_strategy`; derives FTS's own client_credentials scope from `get_capabilities(...).scope_map` (falls back to `"fts"` when empty); skips minting source tokens for S3 sources |
| `rucio/rse.py` | Rucio | `determine_audience_for_rse()`/`determine_scope_for_rse()` consult `get_capabilities()` for `resource_param`/`scope_map`/`drop_scopes` instead of a hardcoded EGI branch — upstream has only the WLCG hostname/prefix-join logic, unconditionally |
| `rucio/constants.py` | Rucio | `BASE_SCHEME_MAP` (renamed/restructured from upstream's smaller `SCHEME_MAP`): adds `srm`, `gsiftp`, `s3s` as top-level keys and `root`↔`https` cross-protocol compatibility (XRootD↔S3) |
| `fts/middleware.py` | FTS | Stores OIDC issuer without trailing-slash normalization, matching Keycloak's raw `iss` claim |
| `fts/openidconnect.py` | FTS | `get_token_issuer()` returns raw `iss` claim (companion to `middleware.py` — apply/remove together) |
| `fts/JobBuilder.py` | FTS | Accepts asymmetric token/cloud_storage transfers (S3 source needs no token, WebDAV destination does); `_cloud_storage_exists` adds a live DB query (`t_cloudStorage`) to the per-request validation path, fails closed to "token required" on query error |
| `teapot/teapot.py` | Teapot | Replaces `@flaat.is_authenticated()` (live `/userinfo` call) with offline JWT verification (`verify_token()`, JWKS via `PyJWKClient`) plus an explicit audience check — required because FTS presents RFC 8693 token-exchanged tokens that Keycloak's `/userinfo`/`/introspect` reject as non-live-session; also: robust process matching (`_get_proc`) by key parts instead of exact cmdline, explicit `httpx.Timeout` for slow aarch64 JVM cold-start |

## Per-issuer OIDC capabilities — `get_capabilities()`

`oidc.py`, `fts3.py`, and `rse.py` all resolve OIDC request-shaping via
`get_capabilities(issuer, grant)` in `oidc.py`, which reads an optional
`capabilities` block per issuer entry in `idpsecrets.json`:

```json
{
  "https://aai-dev.egi.eu/auth/realms/egi": {
    "issuer": "...", "client_id": "...", "client_secret": "...",
    "capabilities": {
      "client_credentials":       { "resource_param": true,  "audience_param": false },
      "admin_client_credentials": { "resource_param": true,  "audience_param": false },
      "token_exchange":           { "resource_param": false, "audience_param": true  },
      "scope_map":   { "storage.read": "read:/", "storage.modify": "write:/", "storage.create": "write:/" },
      "drop_scopes": ["offline_access"]
    }
  }
}
```

An issuer with no `capabilities` block (e.g. the local Keycloak realm) gets
the WLCG default: `resource_param: false`, `audience_param: true`, no scope
remapping. `resource_param`/`audience_param` and `scope_map`/`drop_scopes`
are resolved **per grant type** (`client_credentials`,
`admin_client_credentials`, `token_exchange`), not per issuer as a whole —
EGI Check-In needs this: `resource=` is honored on `client_credentials` but
silently ignored on `token-exchange`, which a single issuer-wide flag cannot
express. See [`docs/design/design-doc-001-oidc-capability-profiles.md`](design/design-doc-001-oidc-capability-profiles.md)
for the full rationale, and [`docs/adrs/adr-002-store-oidc-capabilities-in-idpsecrets.md`](adrs/adr-002-store-oidc-capabilities-in-idpsecrets.md)
for why this lives in `idpsecrets.json` rather than a separate file.

FTS's own `client_credentials` scope (used when FTS itself authenticates to
Rucio) is **not** a separate capability field — `fts3.py` derives it from
the same `scope_map` used for RSE storage-scope translation
(`" ".join(sorted(scope_map.values()))`, falling back to the WLCG literal
`"fts"` when `scope_map` is empty). This resolves to the same value FTS
needs today (EGI: `"read:/ write:/"`), so a dedicated field was judged
unnecessary; if a future IdP ever needs FTS's own scope to diverge from its
RSE scope-mapping, that would be the trigger to add one back.

This replaced an earlier `[oidc] scope_profile` config key (`wlcg`/`egi`,
read via `config_get`) that branched identically across all grant types for
a given issuer and could not express EGI's client_credentials/token-exchange
split. `init-testbed.sh` resolves the same data via its own `_cap()` helper
(inline `python3 -c` reading the same `idpsecrets.json`), but only for the
subset of its `SCOPE_PROFILE`-driven decisions that are genuinely
Rucio-consumed capability data (currently: `resource_param`, for the RSE
audience-attribute shape). The OAuth grant the *init script itself* uses to
bootstrap test identities and seed subject tokens (`grant_mode`:
`password`/`client_credentials`) is **not** stored in `idpsecrets.json` —
nothing in Rucio's Python reads it, so it stays out of `capabilities`
entirely and is resolved by a small dedicated helper,
`_grant_mode_for_profile()`, keyed on `SCOPE_PROFILE` directly. This keeps a
hard line between the two files: `idpsecrets.json` capabilities are read by
Rucio's Python (`get_capabilities()`), `SCOPE_PROFILE` drives decisions read
only by this script. `SCOPE_PROFILE=egi-dev` (Makefile/CI/Helm) is also the
deployment-time directory selector for *which config files get mounted* —
unrelated to, and unchanged by, either lookup.

## FTS DB rows (not source patches, set by `init-testbed.sh`)

Load-bearing, easy to lose on rebuild:

- **`t_se.tpc_support='NONE'`** for both sides of an S3↔WebDAV transfer,
  forcing STREAMED copy mode (Storm-WebDAV can't SigV4-sign a pull from
  Copernicus S3). Source row is permanent; destination rows are set/torn
  down by a test fixture so davs↔davs tests keep pull mode.
- **`t_cloudStorageUser.user_dn`** defaults to the OIDC subject FTS sees
  for oauth2 jobs (not the X.509 DN) — required for SigV4 key lookup to
  resolve at all.

## Replacement paths

Patches below are testbed-local until upstreamed. Confidence in "should this
go upstream as-is" varies — noted per item.

**High confidence — general correctness fixes, not testbed-specific:**
- `oidc.py`'s discovery-URL construction — `urljoin(issuer, '.well-known/...')`
  drops the last path segment when `issuer` lacks a trailing slash (confirmed
  against this testbed's Keycloak issuer); string-concatenation is
  trailing-slash-agnostic. Whether upstream treats this as a bug or expects
  callers to always supply a trailing-slash issuer is worth raising with
  them rather than assuming.
- `constants.py`'s `root`↔`https` scheme compatibility for
  `BASE_SCHEME_MAP`.
- Promoting previously-silent exception handling to WARNING-level logging.

**Worth proposing, needs upstream discussion on API shape:**
- `oidc.py`'s account-based exchange subsystem
  (`get_token_for_account_operation` + supporting functions) — this is new
  functionality, not a fix to an existing upstream function, so it needs a
  design conversation with upstream (API shape, whether it belongs in core
  vs. a plugin) rather than a PR-sized proposal.
- `oidc.py`'s `get_capabilities()`/per-issuer `capabilities` model — the
  underlying problem (different IdPs need different `resource=`/`audience=`
  handling, sometimes per grant type) is general to any multi-IdP Rucio
  deployment, not testbed-specific. Storing it in `idpsecrets.json` is a
  testbed convenience (see ADR-002); upstream may prefer a different
  location or a formal schema.
- `fts3.py`'s `account` + per-RSE `audience` passthrough to `request_token`
  — useful for any token-exchange or audience-scoped-client deployment, but
  changes a function signature others may depend on.
- `JobBuilder.py`'s asymmetric token/cloud_storage validation — legitimate
  for any S3-source/token-destination transfer, not testbed-specific, but
  adds a live DB query to a per-request validation path and touches FTS's
  auth validation logic, so it should get FTS maintainer review on both
  the approach and the performance implication.
- `teapot.py`'s offline JWT verification in place of `flaat`'s live
  `/userinfo` call — the underlying problem (RFC 8693 exchanged tokens
  aren't accepted by `/userinfo`) is general to any WLCG-style token
  consumer behind Teapot, but replacing the auth mechanism outright is a
  bigger change for upstream to evaluate than a bugfix.
- `teapot.py`'s `_get_proc` robustness fix and hardcoded `httpx.Timeout` —
  the matching-by-key-parts logic is a genuine robustness improvement, but
  the timeout value should become a `config.ini` knob before proposing
  upstream, rather than a hardcoded constant.

**Testbed-specific, not intended for upstreaming:**
- `unmanaged_tokens` conditional logic in `fts3.py` — this *is* the
  documented FTS mechanism for pre-fetched long-lived tokens; the
  conditional wiring to `oidc.token_strategy` is testbed integration, not
  a fix.
- `oidc.py`'s `aud:<audience>` scope-append — a workaround for this
  realm's specific Keycloak optional-scope topology; other IdPs may not
  need it.
- `oidc.py`'s `save_subject_token()` — exists only to support the
  testbed's token-seeding flow; production deployments populate subject
  tokens via the real auth-code flow.
