# Runbook 2 — Bring Your Own IdP

## Purpose
Point Rucio, FTS, and your RSEs at an external OIDC issuer (e.g. EGI Check-In,
Keycloak) instead of the bundled one. Covers where issuer, audience, client, and
**scopes** must land — including the distinction between the interactive user
flow and the daemon (service) flow, which is the most common source of errors.

## Prerequisites
- An OIDC issuer reachable from the cluster, with a discovery endpoint at
  `<issuer>/.well-known/openid-configuration`.
- Two clients registered on the IdP (see "Two clients" below).
- Storage endpoints (XRootD/WebDAV) that accept the issuer's tokens.

## Key concept: two clients, two flows

The single most important thing to get right is that Rucio uses **two different
OIDC clients with two different grant types**, and they need different scopes:

| Client | Grant type | Used by | Needs capability scopes (`read:/ write:/` or `storage.*`)? |
|--------|-----------|---------|-----------------------------------------------------------|
| **Interactive** | `authorization_code` (browser) | `rucio whoami`, `rucio upload`/`download` (user talks to storage directly) | **Yes** — only if users run upload/download |
| **Service/daemon** | `client_credentials` | conveyor submitter → FTS → storage (TPC) | **Yes** — always, for server-to-server transfers |

If the IdP issues capability scopes for one grant type but not the other, you get
asymmetric failures: TPC transfers work but `rucio upload` fails with
`invalid_scope` / "no authorization content returned". The fix is registering the
scopes on the **correct client**, not changing `rucio.cfg`.

## Configuration reference — where things land

| Setting | File / location | Example |
|---------|-----------------|---------|
| Issuer (trailing slash!) | `idpsecrets.json` → `issuer` | `https://aai-dev.egi.eu/auth/realms/egi/` |
| Interactive client id/secret | `idpsecrets.json` (server) → `client_id`/`client_secret` | server client |
| Daemon client id/secret | daemon `idpsecrets.json` (mounted from its own secret) | service-account client |
| Redirect URIs | `idpsecrets.json` → `redirect_uris` (server only) | `.../auth/oidc_redirect`, `/oidc_code`, `/oidc_token` |
| Audience | `idpsecrets.json` → `audience`; `rucio.cfg [oidc] expected_audience` | `rucio` |
| Requested user scope | `rucio.cfg [client] oidc_scope` | `openid profile eduperson_entitlement offline_access` |
| Accepted scope (validation) | `rucio.cfg [oidc] expected_scope` | keep permissive |
| Daemon → FTS token scope | conveyor token request (patched `fts3.py`) | `openid profile fts read:/ write:/ eduperson_entitlement offline_access` |
| RSE token support | RSE attribute `oidc_support=True` + `davs`/`https` scheme | required for `_use_tokens` |

> **Note on the daemon's idpsecrets:** daemons may mount their OIDC config from a
> *different* k8s secret than the server (e.g. `idp-clients`), not the server's
> `idpsecrets`. Update the one the daemon actually mounts, or the daemon keeps the
> old scopes. Verify with:
> ```bash
> kubectl get pod <submitter-pod> -n <ns> -o yaml | grep -iA3 idpsecret
> ```

## Steps

1. **Register the two clients on the IdP.** Interactive client: enable
   `authorization_code` + the Rucio redirect URIs + the scopes users need.
   Service client: enable `client_credentials` (service account) + capability
   scopes (`read:/ write:/` or `storage.read`/`storage.write`).

2. **Set the issuer/audience/scopes** in `idpsecrets.json` and `rucio.cfg` per the
   table above. Roll `rucio-auth` and the conveyor daemons.

3. **Confirm the storage endpoints trust the issuer** (XRootD `scitokens.conf` /
   Teapot config has the issuer registered).

## Verification

```bash
# Daemon (client_credentials) — should return 200 with capability scopes
python3 -c "
import requests, json, base64
cfg = list(json.load(open('/opt/rucio/etc/idpsecrets.json')).values())[0]
r = requests.post(cfg['issuer']+'protocol/openid-connect/token',
    auth=(cfg['client_id'], cfg['client_secret']),
    data={'grant_type':'client_credentials','scope':cfg['scope']})
print(r.status_code)
tok=r.json()['access_token']; p=tok.split('.')[1]; p+='='*(-len(p)%4)
print('scope:', json.loads(base64.urlsafe_b64decode(p)).get('scope'))
"

# Interactive (authorization_code) — hit the authorize endpoint in a browser:
#   <issuer>/protocol/openid-connect/auth?response_type=code&client_id=<ID>
#     &redirect_uri=<REGISTERED>&scope=<scopes>&state=test
# A returned ?code=... means the scopes are permitted; error=invalid_scope means not.

# User flow end to end
rucio whoami
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `invalid_scope` at authorize endpoint | Capability scopes not assigned to the interactive client | Add `read:/ write:/` as client scopes on that client in the IdP |
| "no authorization content returned" in browser | Downstream symptom of the IdP `invalid_scope` above | Same fix — it's the IdP, not `rucio.cfg` |
| `unauthorized_client: not enabled to retrieve service account` | Using a non-service client for `client_credentials` | Use the daemon/service client, or enable service account on it |
| `Failed to discover token endpoint` | `issuer` missing trailing slash | Add trailing `/` in `idpsecrets.json` |
| TPC works but `rucio upload` fails | Scopes on service client but not interactive client | Add scopes to the interactive client |
| 401 on FTS token request | Wrong client (server vs daemon) mounted by daemon | Patch the secret the daemon actually mounts |
