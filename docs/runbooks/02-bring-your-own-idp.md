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
- A CA bundle the server trusts that includes the issuer's chain (see "CA trust").

> **EGI Check-In credentials:** the `client_id` / `client_secret` for
> `idpsecrets.json` (interactive and SCIM) are not self-service. Request them from
> **marvin.gajek@cern.ch**. The values in `shared/config/rucio/egi-dev/` are
> placeholders.

## Key concept: two clients, two flows

Rucio uses **two different OIDC clients with two different grant types**, and they
need different scopes:

| Client | Grant type | Used by | Needs capability scopes (`read:/ write:/`)? |
|--------|-----------|---------|---------------------------------------------|
| **Interactive** | `authorization_code` (browser) | `rucio whoami`, `rucio upload`/`download` | **Yes** — only if users run upload/download |
| **Service/daemon** | `client_credentials` | conveyor submitter → FTS → storage (TPC) | **Yes** — always, for server-to-server transfers |

If the IdP issues capability scopes for one grant type but not the other, you get
asymmetric failures: TPC works but `rucio upload` fails with `invalid_scope` /
"no authorization content returned". The fix is registering the scopes on the
**correct client**, not changing `rucio.cfg`.

## CA trust: the server must trust the issuer

Rucio's OIDC discovery (`oic`/`requests`) honours `REQUESTS_CA_BUNDLE`, pointing at
`/etc/grid-security/certificates/rucio_ca.pem`. If that bundle only holds the
internal Rucio CA, discovery fails with `CERTIFICATE_VERIFY_FAILED ... unable to
get issuer certificate`, even though the image's system bundle
(`/etc/pki/tls/certs/ca-bundle.crt`) trusts the issuer. Use a combined bundle =
**system bundle + internal Rucio CA**, not a hand-assembled issuer chain.

> **egi-dev:** a ready combined `rucio_ca.pem` (system roots + Rucio Dev CA,
> trusts the EGI GÉANT/HARICA chain) is checked in at
> `shared/config/rucio/egi-dev/rucio_ca.pem`. To replicate the setup, copy it over
> the active bundle: `cp shared/config/rucio/egi-dev/rucio_ca.pem certs/rucio_ca.pem`.
> Do **not** inline the full system store into a Helm-tracked file — it trips
> Helm's 1 MiB release-secret limit; keep it on the compose-mounted cert path or
> concatenate at runtime.

## Configuration reference — where things land

| Setting | File / location | Example |
|---------|-----------------|---------|
| Issuer (exact string!) | `idpsecrets.json` → `issuer`; top-level key | `https://aai-dev.egi.eu/auth/realms/egi` |
| Client id/secret (request from marvin.gajek@cern.ch) | `idpsecrets.json` → `client_id`/`client_secret` | per-environment |
| Daemon client id/secret | daemon `idpsecrets.json` (its own mounted secret) | service-account client |
| Redirect URIs | `idpsecrets.json` → `redirect_uris` (server only) | `.../auth/oidc_redirect`, `/oidc_code`, `/oidc_token` |
| Audience | `idpsecrets.json` → `audience`; `rucio.cfg [oidc] expected_audience` | `rucio` |
| Issuer + admin issuer | `rucio.cfg [oidc] issuer` / `admin_issuer` | issuer URL (not an alias key) |
| Daemon token strategy | `rucio.cfg [oidc] token_strategy` | `client_credentials` or `exchange` |
| Requested user scope | `rucio.cfg [client] oidc_scope` | `openid profile eduperson_entitlement offline_access` |
| Accepted scope (validation) | `rucio.cfg [oidc] expected_scope` | keep permissive |
| Client host (drives redirect scheme) | `oidc-client.cfg [client] rucio_host`/`auth_host` | `http://localhost:8090` |
| RSE token support | RSE attribute `oidc_support=True` + `davs`/`https` scheme | required for `_use_tokens` |

> **Issuer must match exactly.** Rucio does an exact-string lookup against the
> `idpsecrets.json` key and the issuer advertised by discovery — match the
> `.well-known` value byte-for-byte, including the trailing-slash convention.
> EGI Check-In Dev advertises **no** trailing slash; Keycloak realms usually do.
> A mismatch yields `Failed to discover token endpoint` or a 500 on `/auth/oidc`.
> `admin_issuer` must be the issuer URL, not an alias.

> **token_strategy server cfgs:** the daemon flow is selected by
> `[oidc] token_strategy`; ship the matching server cfg per strategy — e.g.
> `server.client-credentials.cfg` and `server.token-exchange.cfg`.

> **Daemon's idpsecrets:** daemons may mount OIDC config from a *different* secret
> than the server. Update the one the daemon actually mounts, or it keeps the old
> scopes. Verify: `kubectl get pod <submitter-pod> -n <ns> -o yaml | grep -iA3 idpsecret`

## Steps

1. **Register the two clients on the IdP.** Interactive: `authorization_code` +
   Rucio redirect URIs + user scopes. Service: `client_credentials` (service
   account) + capability scopes (`read:/ write:/`).

2. **Set issuer/audience/scopes** in `idpsecrets.json` and `rucio.cfg` per the
   table; ensure CA trust.

3. **Map the external identity to a Rucio account.** A valid token *authenticates*
   but isn't *authorized* until its `SUB`+`ISS` is bound to an account. Run
   **in-pod / in-container** — the dev shell's own client uses OIDC and would
   deadlock on the broken flow:
   ```bash
   # k8s
   kubectl -n <ns> exec deploy/rucio-server -c rucio-server -- \
     rucio-admin identity add --type OIDC \
       --id "SUB=<sub claim>, ISS=<token issuer>" \
       --account <account> --email <email>

   # compose
   docker exec -t compose-rucio-server-1 \
     rucio-admin identity add --type OIDC \
       --id "SUB=<sub claim>, ISS=<token issuer>" \
       --account <account> --email <email>

   # compose (e.g.)
   docker exec -t compose-rucio-server-1 \
      rucio-admin identity add --type OIDC
         --id "SUB=aa886829a0a894933008498cfe62264d899422f55b408560a259311776f0e519@egi.eu, ISS=https://aai-dev.egi.eu/auth/realms/egi" --account randomaccount --email marvin.gajek@cern.ch
   ```
   `SUB`/`ISS` must match the token's claims exactly; `--account` must match the
   account in the client cfg. Get the user's `sub`/email from their EGI Check-In
   personal-info page.

4. **Confirm the storage endpoints trust the issuer** (XRootD `scitokens.conf` /
   Teapot config has the issuer registered).

## Verification

```bash
# CA trust — should print 200 against the bundle REQUESTS_CA_BUNDLE points at
python3 -c "import requests; print(requests.get(
  '<issuer>/.well-known/openid-configuration',
  verify='/etc/grid-security/certificates/rucio_ca.pem').status_code)"

# e.g.
python3 -c "import requests; print(requests.get(
  'https://aai-dev.egi.eu/auth/realms/egi/.well-known/openid-configuration',
  verify='/etc/grid-security/certificates/rucio_ca.pem').status_code)"

# Exec into a daemon pod to ensure daemon client_credentials are correct — should return 200 with capability scopes
python3 -c "
import requests, json, base64
cfg = list(json.load(open('/opt/rucio/etc/idpsecrets.json')).values())[0]
r = requests.post(cfg['issuer']+'/protocol/openid-connect/token',
    auth=(cfg['client_id'], cfg['client_secret']),
    data={'grant_type':'client_credentials','scope':cfg['scope']})
print(r.status_code)
tok=r.json()['access_token']; p=tok.split('.')[1]; p+='='*(-len(p)%4)
print('scope:', json.loads(base64.urlsafe_b64decode(p)).get('scope'))
"

# User flow end to end (browser code flow)
rucio whoami
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CERTIFICATE_VERIFY_FAILED ... unable to get issuer certificate` on `/auth/oidc` | `rucio_ca.pem` lacks the issuer chain | Use combined bundle; for egi-dev copy `shared/config/rucio/egi-dev/rucio_ca.pem` → `certs/rucio_ca.pem` |
| `Invalid parameter: redirect_uri` at IdP | `https://localhost` requested, registration not deployed, or path mismatch | Web clients allow `http://localhost` (not `https://localhost`); exact-match all paths; confirm IdP reconfig is **deployed**, not pending |
| Redirect goes to the wrong host | `redirect_uris` / `rucio_host`/`auth_host` point elsewhere | Point both at your host; restart server so it re-reads `idpsecrets.json` |
| `OIDC authentication failed` but token is valid | Identity not mapped to the account | Run `rucio-admin identity add` (Step 3); SUB/ISS exact, account-matched |
| `invalid_scope` at authorize endpoint | Capability scopes not on the interactive client | Add `read:/ write:/` as client scopes on that client |
| "no authorization content returned" in browser | Downstream of the IdP `invalid_scope` above | Same fix — it's the IdP, not `rucio.cfg` |
| `unauthorized_client: not enabled to retrieve service account` | Non-service client used for `client_credentials` | Use the daemon/service client, or enable service account |
| `Failed to discover token endpoint` / 500 on `/auth/oidc` | Issuer string mismatch or `admin_issuer` is an alias | Match the `.well-known` issuer exactly; set `admin_issuer` to the issuer URL |
| TPC works but `rucio upload` fails | Scopes on service client but not interactive | Add scopes to the interactive client |
| 401 on FTS token request | Wrong client mounted by daemon | Patch the secret the daemon actually mounts |
