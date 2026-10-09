# Patches

Minimal patches to upstream components that enable OIDC-only, token-based
transfers (X.509/GSI is out of scope). Each patched file is mounted over the
original: bind mount in Compose, ConfigMap in Kubernetes.

Each change is tagged for upstreaming: *(fix)* general bug fix, worth a PR;
*(propose)* general, needs discussion with upstream; *(local)* testbed-specific.

## Files touched

| File | Component | Change |
|---|---|---|
| `rucio/oidc.py` | Rucio | • Account-based RFC 8693 token exchange (`get_token_for_account_operation`), not in upstream *(propose)*<br>• Per-issuer, per-grant `get_capabilities()` (see below) *(propose)*<br>• Discovery URL works without a trailing slash on the issuer *(fix)*<br>• Sends `requested_token_type` explicitly *(fix)*<br>• Sends several audiences as repeated RFC 8707 `resource=` parameters *(fix)*<br>• Previously silent failures logged as warnings *(fix)*<br>• `aud:<audience>` scope for `client_credentials` *(local)*<br>• `save_subject_token()` for token seeding *(local)* |
| `rucio/fts3.py` | Rucio | • Passes `account` and per-RSE `audience` to `request_token` *(propose)*<br>• FTS client scope from capabilities (`fts_client_scope`, else `scope_map`, else `fts`) *(propose)*<br>• No source token for S3 sources *(propose)*<br>• `unmanaged_tokens` from `oidc.token_strategy` *(local)* |
| `rucio/rse.py` | Rucio | • Audience and scope per RSE come from capabilities instead of a hard-coded EGI branch *(propose)*<br>• Scopes mapped to `""` are dropped; falls back to `openid` *(propose)* |
| `rucio/constants.py` | Rucio | • `SCHEME_MAP`: adds `srm`/`gsiftp`, `s3s`, `http`, and `root`↔`https` *(fix)*<br>• Adds `gsiftp`, `srm`, `s3s` to the supported protocols *(fix)* |
| `fts/middleware.py`, `fts/openidconnect.py` | FTS | • Keep the issuer exactly as in the `iss` claim (no added trailing slash); apply or remove both together *(fix)* |
| `fts/tokenproviders.py` | FTS | • Stores the issuer as given, so the issuer lookup at submit time matches (otherwise 403 "Issuer not found") *(fix)* |
| `fts/JobBuilder.py` | FTS | • Allows a token on one side and cloud-storage credentials on the other (S3 source → WebDAV destination) *(propose)*<br>• Checks `t_cloudStorage` on each submission; fails closed *(propose)* |
| `fts/cloudStorage.py`, `fts/cloud.py` | FTS | • Adds `region` and `sigv4_header_mode` for S3 SigV4 signing, settable through the REST API *(propose)* |
| `teapot/teapot.py` | Teapot | • Verifies JWTs offline with the issuer's keys (`jwks_uri` from discovery) plus an audience check, instead of calling `/userinfo`, which rejects exchanged tokens *(propose)*<br>• More robust process matching *(propose)*<br>• Longer HTTP timeout; make it configurable first *(propose)* |
| `deploy/compose/Dockerfile.teapot` | Teapot image | • Builds with StoRM WebDAV 1.13.0, which accepts RFC 9068 `at+jwt` tokens ([GH-158](https://github.com/italiangrid/storm-webdav/issues/158)); 1.12.0 rejects them *(propose)* |

## Per-issuer OIDC capabilities

`get_capabilities(issuer, grant)` reads an optional `capabilities` block per
issuer in `idpsecrets.json`. It controls, per grant type:

- whether to send `resource=` or `audience=`
- `scope_map`: translates storage scopes; map to `""` to drop one
- `drop_scopes`: extra scopes to remove
- `fts_client_scope`: explicit scope for FTS's own `client_credentials`

An issuer without a block gets the WLCG defaults (`audience=`, no
remapping). Grant types: `client_credentials`, `admin_client_credentials`,
`token_exchange`, `authorization_code`.

```json
"capabilities": {
  "client_credentials": { "resource_param": true, "audience_param": false },
  "token_exchange":     { "resource_param": false, "audience_param": true },
  "scope_map":   { "storage.read": "read:/" },
  "drop_scopes": ["offline_access"]
}
```

See [design-doc-001](design/design-doc-001-oidc-capability-profiles.md) and
[ADR-002](adrs/adr-002-store-oidc-capabilities-in-idpsecrets.md).

## Issuer strings must match `iss` exactly

Every configured issuer (the `idpsecrets.json` key, `rucio.cfg`, Teapot,
StoRM WebDAV, FTS) must match the token's `iss` claim exactly, including any
trailing slash. Only strip the slash when building a URL from the issuer,
never when comparing issuers.

## FTS configuration (set by `init-testbed.sh` through the FTS REST API)

- `/config/token_providers`: the issuer is registered with and without a
  trailing slash. Submissions look it up by the raw `iss` claim, while the
  `t_token` foreign key needs the form with the slash.
- `/config/cloud_storage`: the S3 storage with `region` and
  `sigv4_header_mode`, plus the access keys for the OIDC subject FTS sees
  (`user_dn`), so the S3 key lookup succeeds.
- `/config/se`: `tpc_support=NONE` on the S3 endpoint, which forces streamed
  copies.
