# Runbook 5 — The Rucio Configs That Matter

## Purpose
A brief reference to the configurations that actually determine whether
token-based TPC transfers work: `rucio.cfg` OIDC settings, FTS `fts3restconfig`,
and RSE attributes. Use it as a checklist when standing up or debugging a stack.

## 1. `rucio.cfg` — OIDC

### Server (`rucio-server`)
```ini
[oidc]
idpsecrets = /opt/rucio/etc/idpsecrets.json
admin_issuer = https://<issuer>/auth/realms/<realm>
expected_audience = rucio
expected_scope = openid profile eduperson_entitlement offline_access
```
- `expected_*` **validate incoming** tokens. Keep `expected_scope` permissive —
  requiring capability scopes here will reject normal user logins that don't carry
  them.

### Daemons (`rucio-daemons`)
```ini
[oidc]
idpsecrets = /opt/rucio/etc/idpsecrets.json
admin_issuer = https://<issuer>/auth/realms/<realm>
expected_audience = rucio
expected_scope = openid profile eduperson_entitlement offline_access

[conveyor]
transfertool = fts3
allow_user_oidc_tokens = True
request_oidc_scope = openid offline_access eduperson_entitlement
```
- The daemon mints the FTS token. With the testbed patch, the scope used for the
  FTS/storage token is set in `fts3.py` (or driven by `request_oidc_scope`):
  `openid profile fts read:/ write:/ eduperson_entitlement offline_access`.

### Client (`rucio.cfg [client]`)
```ini
oidc_scope = openid profile eduperson_entitlement offline_access
```
- Plain scopes for `whoami`/rule creation (talks to the Rucio server, not
  storage). Only add `read:/ write:/` if users run `upload`/`download`, **and**
  only if the interactive IdP client permits those scopes.

## 2. `idpsecrets.json`
```json
{
  "https://<issuer>/auth/realms/<realm>": {
    "issuer": "https://<issuer>/auth/realms/<realm>/",
    "client_id": "<client>",
    "client_secret": "<secret>",
    "redirect_uris": ["<server>/auth/oidc_redirect", "<server>/auth/oidc_code", "<server>/auth/oidc_token"],
    "audience": "rucio",
    "scope": "openid profile eduperson_entitlement offline_access read:/ write:/"
  }
}
```
- **Trailing slash on `issuer`** is required (token-endpoint discovery).
- Server and daemons may mount this from **different secrets** — confirm which one
  each pod mounts before editing.

## 3. FTS `fts3restconfig`
- Managed vs unmanaged variants live in `shared/config/fts/`
  (`managed.fts3restconfig`, `unmanaged.fts3restconfig`).
- Key points: the issuer must be registered so FTS accepts/validates the bearer
  token; token-based TPC needs the providers configured. FTS presents the token
  Rucio supplies to both source and destination endpoints.

## 4. RSE attributes (per RSE)

| Attribute | Purpose | Required for tokens? |
|-----------|---------|----------------------|
| `fts` | FTS endpoint URL | Yes |
| `oidc_support=True` | Enables token auth on this RSE | Yes |
| scheme `davs` or `https` | `_use_tokens` only engages for these | Yes |
| `verify_checksum` | Checksum validation strategy | Optional |
| `sign_url` (s3) | Presigned URL generation for S3 | S3 only |

Plus, not attributes but required for any transfer:
- **Distance** between source and destination (both directions).
- **Account quota** on the destination RSE.

## The `_use_tokens` rule (the gotcha)
A transfer only uses tokens if **every** endpoint on the hop is
`oidc_support=True` **and** scheme is `davs` or `https`. Otherwise Rucio falls
back to X.509/cert auth. (The testbed patches `fts3.py` to allow `https` in
addition to `davs`.)

## Quick verification checklist
```bash
rucio rse show <RSE>                       # oidc_support=True, davs/https, fts set
rucio rse distance show <SRC> <DST>        # distance present
rucio account limit list <account> <RSE>   # quota set
# token carries capability scopes (client_credentials):
#   decode the JWT 'scope' claim — expect read:/ write:/
```

## Common failure → cause map

| Failure | Likely cause |
|---------|--------------|
| `NO_SOURCES` / PathDistance drop | Missing RSE distance |
| `insufficient quota` | No account limit on destination |
| Transfer not using token | RSE missing `oidc_support` or wrong scheme |
| `invalid_scope` on user login | Interactive IdP client lacks the scope |
| FTS token 401 | Wrong/un-provisioned daemon client |
| Copy `HTTP 500` | Storage-side server error (not Rucio/auth) |
