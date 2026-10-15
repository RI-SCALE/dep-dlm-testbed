# Patches

Minimal patches to upstream components for OIDC-only, token-based transfers.
Each patched file is mounted over the original (bind mount in Compose,
ConfigMap in Kubernetes).

## Tracking

- `shared/patches/<component>.manifest` maps each patched file to its upstream path.
- `make patches` writes unified diffs to `diffs/<component>/` against the pinned
  refs in the Makefile (`RUCIO_REF`, `FTS_REST_REF`, `TEAPOT_REF`). Each ref
  **must match the image** the file is mounted into.
- `make patches-check` fails CI if a patched file changed without regenerated diffs.

Tags: *(fix)* bug fix, PR-ready · *(propose)* needs upstream discussion · *(local)* testbed-only.

## Changes

| File | Change |
|---|---|
| `rucio/oidc.py` | Reintroduces account-based RFC 8693 exchange *(propose)* · per-issuer `get_capabilities()` *(propose)* · discovery without trailing slash, `requested_token_type`, repeated `resource=`, warnings instead of silent failures *(fix)* · raw `claims` for OPA *(local)* · `aud:` scope, `save_subject_token()` *(local)* |
| `rucio/fts3.py` | `account` passed to `request_token`; FTS scope from capabilities; no OIDC token for `s3s` endpoints *(propose)* · `unmanaged_tokens` from `oidc.token_strategy` *(local)* |
| `rucio/rse.py` | RSE audience/scope from capabilities (EGI: `audience` RSE attribute + `scope_map`) *(propose)* |
| `rucio/constants.py` | `s3s`, `http`, `root`↔`https` in `SCHEME_MAP` *(fix)* |
| `rucio/authentication.py`, `rucio/common.py` | Token claims exposed in the request environ for the OPA policy *(local)* |
| `fts/middleware.py` | Issuer kept exactly as the `iss` claim *(fix)* |
| `fts/tokenproviders.py` | Issuer stored as given *(fix)* |
| `fts/JobBuilder.py` | Token on one side, cloud-storage keys on the other *(propose)* |
| `fts/cloudStorage.py`, `fts/cloud.py` | `region`, `sigv4_header_mode` via REST *(propose)* |
| `teapot/teapot.py` | Offline JWT verification + audience check instead of `/userinfo` *(propose)* |
| `deploy/compose/Dockerfile.teapot` | StoRM WebDAV 1.13.0 for RFC 9068 `at+jwt` ([GH-158](https://github.com/italiangrid/storm-webdav/issues/158)) *(propose)* |

## Rules

- **Issuers** must match the token's `iss` exactly, trailing slash included.
  Strip the slash only when building URLs.
- **Capabilities**: see [design-doc-001](design/design-doc-001-oidc-capability-profiles.md)
  and [ADR-002](adrs/adr-002-store-oidc-capabilities-in-idpsecrets.md).

## FTS configuration (`init-testbed.sh`)

- `/config/token_providers`: issuer registered with and without trailing slash
  (submit uses raw `iss`; the `t_token` FK needs the slash form).
- `/config/cloud_storage`: S3 storage with `region`/`sigv4_header_mode` and keys for the OIDC `user_dn`.
- `/config/se`: `tpc_support=NONE` on the S3 endpoint (forces streamed copies).
