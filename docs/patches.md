# Patches

Minimal patches to upstream components enabling OIDC-only token-based
transfers (X.509/GSI is out of scope). Each patch is bind-mounted (Compose)
or ConfigMap-mounted (Kubernetes) over the original file.

## Files touched

| File | Component | Essential change |
|---|---|---|
| `rucio/oidc.py` | Rucio | Adds an account-based RFC 8693 token-exchange subsystem not present upstream (`get_token_for_account_operation`, `__exchange_token_oidc`, `__get_admin_token_oidc`, `__get_admin_account_for_issuer`); fixes discovery-URL construction; adds `aud:<audience>` scope-append for `client_credentials`; `scope_profile`-aware `resource=`/`audience=` selection (EGI vs. WLCG); `save_subject_token()` seeding helper; promotes silent failures to WARNING |
| `rucio/fts3.py` | Rucio | Passes `account` + per-RSE `audience` to `request_token` (upstream has neither); sets `unmanaged_tokens` from `oidc.token_strategy`; selects `fts`/`read:/ write:/` scope via `scope_profile`; skips minting source tokens for S3 sources |
| `rucio/rse.py` | Rucio | Adds `determine_audience_for_rse()`'s `scope_profile=egi` branch and all of `determine_scope_for_rse()`'s EGI path (`_EGI_SCOPE_MAP`) — upstream has only the WLCG hostname/prefix-join logic, unconditionally |
| `rucio/constants.py` | Rucio | `BASE_SCHEME_MAP` (renamed/restructured from upstream's smaller `SCHEME_MAP`): adds `srm`, `gsiftp`, `s3s` as top-level keys and `root`↔`https` cross-protocol compatibility (XRootD↔S3) |
| `fts/middleware.py` | FTS | Stores OIDC issuer without trailing-slash normalization, matching Keycloak's raw `iss` claim |
| `fts/openidconnect.py` | FTS | `get_token_issuer()` returns raw `iss` claim (companion to `middleware.py` — apply/remove together) |
| `fts/JobBuilder.py` | FTS | Accepts asymmetric token/cloud_storage transfers (S3 source needs no token, WebDAV destination does); `_cloud_storage_exists` adds a live DB query (`t_cloudStorage`) to the per-request validation path, fails closed to "token required" on query error |
| `teapot/teapot.py` | Teapot | Replaces `@flaat.is_authenticated()` (live `/userinfo` call) with offline JWT verification (`verify_token()`, JWKS via `PyJWKClient`) plus an explicit audience check — required because FTS presents RFC 8693 token-exchanged tokens that Keycloak's `/userinfo`/`/introspect` reject as non-live-session; also: robust process matching (`_get_proc`) by key parts instead of exact cmdline, explicit `httpx.Timeout` for slow aarch64 JVM cold-start |

## `scope_profile` — the shared config knob

`oidc.py`, `fts3.py`, and `rse.py` all read `config_get("oidc", "scope_profile",
default="wlcg")`. `"wlcg"` (default) preserves stock behavior; `"egi"` opts
into EGI Check-In specifics: `resource=` instead of `audience=`/`aud:` scope,
and WLCG→EGI scope-name mapping. This is orthogonal to the deployment-level
`SCOPE_PROFILE=egi-dev` (which selects *which config files* get mounted) —
`scope_profile=egi` is the value one of those mounted files (`server.client-
credentials.cfg`) sets.

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
