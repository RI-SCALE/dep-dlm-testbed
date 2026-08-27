# Runbook 2 — Bring Your Own IdP

## Purpose
Point Rucio/FTS/RSEs at an external OIDC issuer (EGI Check-In, LS AAI,
Keycloak). Where issuer/audience/client/scopes land, and the two flows
(interactive vs. daemon) that must both work.

## Prerequisites
- Issuer reachable, discovery at `<issuer>/.well-known/openid-configuration`.
- Client with `authorization_code` + `client_credentials` enabled (see below).
- CA bundle trusting the issuer's chain (see "CA trust").

**EGI/LS AAI client registration is not self-service.** Only
`idpsecrets.json.example` (placeholders only) is tracked in git; the real
`idpsecrets.json` per profile is gitignored — create it first, then fill in
your real values:
```bash
cp shared/config/rucio/<profile>/idpsecrets.json.example \
   shared/config/rucio/<profile>/idpsecrets.json
# edit shared/config/rucio/<profile>/idpsecrets.json with your real values
```
Then reseed:
```bash
export GITOPS_ENV=sandbox SCOPE_PROFILE=egi-dev TOKEN_MODE=unmanaged
export GITOPS_REPO_URL=https://github.com/ri-scale/dep-dlm-testbed.git GITOPS_REVISION=main
make argocd-install   # or flux-install
make init
```
Unblock a running sandbox without reseeding (patch Vault directly — use
`kv patch`, not `put`; `dep-dlm/secrets` also holds `server.cfg`/`alembic.ini`).
This patches Vault's live value directly, not the repo file, so it's
unaffected by the `idpsecrets.json`/`.example` split above:
```bash
kubectl exec -n dep-dlm-sandbox vault-0 -- sh -c '
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault kv get -mount=secret -field=idpsecrets.json dep-dlm/secrets
' | sed -e "s|<valid client id>|$OIDC_CLIENT_ID|g" -e "s|<valid client secret>|$OIDC_CLIENT_SECRET|g" > /tmp/idpsecrets.json
kubectl cp /tmp/idpsecrets.json dep-dlm-sandbox/vault-0:/tmp/idpsecrets.json
kubectl exec -n dep-dlm-sandbox vault-0 -- sh -c '
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault kv patch -mount=secret dep-dlm/secrets idpsecrets.json=@/tmp/idpsecrets.json
'
rm /tmp/idpsecrets.json
kubectl annotate externalsecret testbed-secrets -n dep-dlm-sandbox force-sync=$(date +%s) --overwrite
kubectl rollout restart deployment rucio-server rucio-daemons-conveyor-finisher \
  rucio-daemons-conveyor-poller rucio-daemons-conveyor-submitter \
  rucio-daemons-judge-cleaner rucio-daemons-judge-evaluator rucio-daemons-reaper \
  -n dep-dlm-sandbox
```
Doesn't survive a reseed — still update the repo file for anything persistent.
LS AAI: contact `support@aai.lifescience-ri.eu`; CI pulls from
`secrets.LS_AAI_DEV_OIDC_CLIENT_ID`/`_SECRET`
(`.github/workflows/ls-aai-dev.yml`), which performs the same
`.example` → real-file copy before templating. Both `TOKEN_MODE=unmanaged`
*and* `TOKEN_MODE=managed` are confirmed working end-to-end for ls-aai-dev
(see the token-strategy section below).

## One client, two flows

| Flow | Grant | Used by | Needs `read:/ write:/`? |
|------|-------|---------|--------------------------|
| Interactive | `authorization_code` | `rucio whoami`/`upload`/`download` | only if upload/download used |
| Daemon | `client_credentials` | conveyor → FTS → storage | always |

One client, both grants — simplest, works today. Splitting later buys audit
clarity/rotation, but if you do and scopes land on only one grant type:
TPC works, `rucio upload` fails `invalid_scope` — fix registration, not `rucio.cfg`.
**LS AAI has no `read:/`/`write:/` concept at all** (rejected on any grant) — see below.

## Creating the client — EGI Check-In Dev
Not self-service; for whoever has Federation Registry access.
1. Manage Services → register/reconfigure → **OIDC**.
2. Application Type: `Web`.
3. Grant Types: `client credentials` + `authorization code` (+ `token-exchange`
   only if attempting `token_strategy=exchange` — currently non-viable, see below).
4. Token Endpoint Auth: `Client Secret over HTTP Basic`.
5. Scope: `openid`, `profile`, `offline_access`, `eduperson_entitlement`, `read:/`, `write:/`.
6. Redirect URI(s): `http://localhost:8090/auth/oidc_{redirect,code,token}`
   — EGI Check-In only allows `http://localhost` for non-production. **For a
   real deployed hostname (non-localhost), it must be registered explicitly and
   approved** — see the Terraform-managed section below.
7. Enable Refresh Tokens if `token_strategy=exchange`.
8. Submit, self-approve (Dev/Demo only).
9. `client_id`/`client_secret` → the real `idpsecrets.json` (create it from
   `idpsecrets.json.example` first — see Prerequisites).

No per-RSE clients needed for `client_credentials`; would be needed for `exchange`.

## Creating the client — LS AAI
Not self-service — `support@aai.lifescience-ri.eu` or Federation Registry.
1. Grant types: `client_credentials` (required) + `authorization_code` (if
   interactive needed) + `token-exchange` (exchange mode confirmed working
   here, unlike EGI). Enable "Issue refresh tokens".
2. Register Resource Indicators (RFC 8707) per RSE/service, e.g.
   `https://teapot1.example.org/`, `.../xrd3.example.org/`, `.../fts.example.org/`
   — required, `resource=` requests fail without them.
3. Scope set is fixed: `openid`, `profile`, `email`, `offline_access`,
   `eduperson_entitlement`. No `read:/`/`write:/` — handled in `idpsecrets.json`:
   `capabilities.scope_map` maps storage scopes → `""`,
   `capabilities.fts_client_scope = "openid"`, `capabilities.drop_scopes = []`.
   See `docs/patches.md` → "Per-issuer OIDC capabilities".
4. `resource=` honored on both `client_credentials` and `token_exchange`
   (unlike EGI — only the former) — this is what makes `exchange` viable here.
5. Identity must belong to `Life Science Community - Test Environment` —
   register at `https://signup.aai.lifescience-ri.eu/fed/registrar?vo=lifescience_test`
   first if you see an access-denied org-unit page.
6. `client_id`/`client_secret` → the real
   `shared/config/rucio/ls-aai-dev/idpsecrets.json` (create it from
   `idpsecrets.json.example` first — see Prerequisites).

`user-mapping.csv` needs the **client's own** `client_credentials` sub too
(Teapot's `teapot_token` fixture authenticates as the client itself) — decode
a `client_credentials` token to get it, add to
`shared/config/teapot/ls-aai-dev/user-mapping.csv`, or 401
"local user for sub claim ... does not exist".

No per-RSE *clients* on ls-aai-dev — RSEs are resource indicators on the one
testbed client instead.

## CA trust
`REQUESTS_CA_BUNDLE` → `/etc/grid-security/certificates/tls_ca_bundle.pem`.
`rucio_ca.pem` alone = internal CA only → `CERTIFICATE_VERIFY_FAILED` against
an external issuer. Need system bundle + internal CA combined, as `tls_ca_bundle.pem`.

- **egi-dev**: ready combined bundle at
  `shared/config/rucio/egi-dev/tls_ca_bundle.pem` →
  `cp shared/config/rucio/egi-dev/tls_ca_bundle.pem certs/tls_ca_bundle.pem`.
  Don't inline the full system store into a Helm-tracked file (1 MiB release-secret limit).
  `rucio_ca.pem` still separately drives `rucio.cfg`'s `[conveyor] cacert` (FTS/gfal trust).
- **ls-aai-dev**: system-trusted already, no combined bundle needed.

## Configuration reference

| Setting | Location | Example |
|---|---|---|
| Issuer (exact string) | `idpsecrets.json` → `issuer`/top-level key | EGI: `https://aai-dev.egi.eu/auth/realms/egi` — LS AAI: `.../oidc/` (**trailing slash**) |
| Client id/secret | `idpsecrets.json` | per-environment (real file, gitignored — see Prerequisites) |
| Redirect URIs | `idpsecrets.json` → `redirect_uris` | `.../auth/oidc_{redirect,code,token}` |
| Audience | `idpsecrets.json` → `audience`; `rucio.cfg [oidc] expected_audience` | `rucio` |
| Issuer / admin issuer | `rucio.cfg [oidc] issuer` / `admin_issuer` | **issuer URL, not an alias** |
| Daemon token strategy | `rucio.cfg [oidc] token_strategy` | `client_credentials` \| `exchange` |
| Requested user scope | `rucio.cfg [client] oidc_scope` | `openid profile eduperson_entitlement offline_access` |
| Validated scope | `rucio.cfg [oidc] expected_scope` | must match what `scope_map` actually produces |
| Client host | `oidc-client.cfg [client] rucio_host`/`auth_host` | public hostname for real deployments |
| RSE token support | RSE attr `oidc_support=True` + `davs`/`https` scheme | required |
| Per-issuer capabilities | `idpsecrets.json` → `capabilities` | LS AAI: scope_map→`""`, fts_client_scope=`openid`, drop_scopes=`[]` |
| FTS resource-indicator profile | `fts3config` → `OidcResourceIndicatorProfile` | `egi` \| `lsaai` |

**Issuer must match byte-for-byte** everywhere it's compared — `idpsecrets.json`
key, `rucio.cfg` `issuer`/`admin_issuer`, Teapot `trusted_OP`, XRootD
`scitokens.conf`. EGI: no trailing slash. LS AAI: trailing slash. Mismatch →
`Failed to discover token endpoint` or 500 on `/auth/oidc`. See `docs/patches.md`
→ "OIDC issuer string consistency" for build-vs-match distinction.

Daemon flow selects the server cfg to ship:
`server.client-credentials.cfg` or `server.token-exchange.cfg`.

**`token_strategy=exchange` is non-viable against EGI Check-In Dev.**
`resource=` isn't honored on `token-exchange` (only `client_credentials`/
`authorization_code`/`refresh_token`/`device`); exchange only supports
`audience=` matching a *registered client_id*, and no per-RSE clients exist →
exchanged token has no `aud` claim → storage rejects it. **Use
`token_strategy=client_credentials`** (`TOKEN_MODE=unmanaged`) for `egi-dev`.
CI confirms: `managed` → `invalid_client`/"Audience not found"; `unmanaged` passes.

**`token_strategy=exchange` IS viable against LS AAI** (both token modes pass
full suite), via three fixes: `rse.py`'s `determine_scope_for_rse()` always
includes `openid`; `oidc.py`'s `get_token_for_account_operation()` only reuses
a cached token for exchange if it has a `refresh_token`; FTS's
`TokenExchangeExecutor.cpp` recognizes `OidcResourceIndicatorProfile=="lsaai"`
and extracts the URI from `token.audience` rather than assuming `http(s)://`.
Also: RFC 8693 requests need explicit `requested_token_type` for LS AAI
(handled in `oidc.py`'s `__exchange_token_oidc`). Doesn't change the EGI
conclusion — different, IdP-side gap.

**Daemons may mount a different `idpsecrets` secret than the server** — update
the one actually mounted:
`kubectl get pod <submitter-pod> -n <ns> -o yaml | grep -iA3 idpsecret`

## Terraform-managed environments (staging/production)

- `admin_issuer` = real issuer URL, not an alias like `"rucio"` — `rucio.core.oidc`
  keys admin client lookup by this value; mismatch → `KeyError`, every
  `/auth/oidc` call 500s.
- `rucio.cfg [client] rucio_host`/`auth_host` = `http://localhost` — anything
  run *inside* the rucio-server pod needs the in-cluster address; public
  hostname doesn't resolve there.
- `expected_scope` must be derived per profile — no automatic relationship to
  what the client requests; Terraform's default is a generic fallback, not
  correct for any specific profile.
- Redirect URIs need the real public hostname registered with the IdP — but
  EGI's `Web` type appears to force `https://` on the actual redirect
  regardless of registered scheme, so interactive login needs real TLS on the
  Gateway, not just a DNS-correct `http://` URI.
- After any `tf-apply` touching secrets, force sync + restart (ESO's refresh
  interval isn't fast enough to trust blindly):
  ```bash
  kubectl -n <ns> annotate externalsecret testbed-secrets force-sync="$(date +%s)" --overwrite
  kubectl -n <ns> rollout restart deploy/rucio-server
  ```
- `oidc-client.cfg` is Terraform-rendered (`modules/secrets`) — fetch it
  instead of hand-editing:
  ```bash
  gcloud secrets versions access latest --secret=<env>-secrets \
    | jq -r '.["oidc-client.cfg"]' > /tmp/oidc-client.cfg
  export RUCIO_CONFIG=/tmp/oidc-client.cfg
  ```

## Steps

1. Register client (both grants; LS AAI also `token-exchange` + resource indicators if managed mode wanted).
2. Set issuer/audience/scopes per the table; ensure CA trust. Remember
   `idpsecrets.json` itself is gitignored — create it from
   `idpsecrets.json.example` first if you haven't already (see Prerequisites).
3. Map identity to account — **in-pod**, not the dev shell (its own client uses OIDC, deadlocks on a broken flow):
   ```bash
   kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
   rucio-admin identity add --type OIDC \
      --id "SUB=<sub>, ISS=<issuer>" \
      --account randomaccount --email you@example.com
   ```
   EGI issuer: `https://aai-dev.egi.eu/auth/realms/egi`. LS AAI: `https://login.aai.lifescience-ri.eu/oidc/`
   (note trailing slash, and `@lifescience-ri.eu`-suffixed sub). Compose: swap
   for `docker exec -t compose-rucio-server-1`.

4. Confirm storage trusts the issuer (XRootD `scitokens.conf`/Teapot config).
   LS AAI: Storm-WebDAV **≥1.13.0** required (RFC 9068 `at+jwt` tokens rejected
   below that) — `deploy/compose/Dockerfile.teapot`'s `STORM_VERSION`.
5. `TOKEN_MODE=managed` + LS AAI: confirm FTS image has the
   `TokenExchangeExecutor` fixes, or `"[TokenExchange] Failed to get refresh
   token... HTTP 400"` even with correct Rucio-side config.

## Verification

CI (`make test-rucio-transfers`/`test-rucio-deletion`, and
`.github/workflows/ls-aai-dev.yml` for LS AAI both token modes) is the
authoritative check. Below is for isolating a failure to one layer — run
inside the pod being checked (`kubectl -n dep-dlm-sandbox exec deploy/<svc> --`,
or `docker exec compose-<svc>-1` for compose).

```bash
# CA trust — expect 200
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- python3 -c "
import requests
print(requests.get('https://aai-dev.egi.eu/auth/realms/egi/.well-known/openid-configuration',
  verify='/etc/grid-security/certificates/tls_ca_bundle.pem').status_code)"

# Daemon client_credentials sanity — expect 200 + capability scopes in the token
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- python3 -c "
import requests, json, base64
cfg = list(json.load(open('/opt/rucio/etc/idpsecrets.json')).values())[0]
r = requests.post(cfg['issuer']+'/protocol/openid-connect/token',
    auth=(cfg['client_id'], cfg['client_secret']),
    data={'grant_type':'client_credentials','scope':cfg['scope']})
print(r.status_code)
tok = r.json()['access_token']; p = tok.split('.')[1]; p += '=' * (-len(p) % 4)
print('scope:', json.loads(base64.urlsafe_b64decode(p)).get('scope'))"
```

LS AAI equivalent (discovery-resolved token endpoint):
```bash
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- python3 -c "
import requests, json, base64
cfg = json.load(open('/opt/rucio/etc/idpsecrets.json'))['https://login.aai.lifescience-ri.eu/oidc/']
discovery = requests.get(cfg['issuer'].rstrip('/') + '/.well-known/openid-configuration').json()
r = requests.post(discovery['token_endpoint'], auth=(cfg['client_id'], cfg['client_secret']),
    data={'grant_type':'client_credentials','scope':'openid'})
print(r.status_code)
tok = r.json()['access_token']; p = tok.split('.')[1]; p += '=' * (-len(p) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2))"
```

Malformed `OIDC_CLIENT_ID`:
```bash
echo -n "$OIDC_CLIENT_ID" | wc -c   # 36 for a standard UUID
curl -s -u "$OIDC_CLIENT_ID:$OIDC_CLIENT_SECRET" \
  -d 'grant_type=client_credentials' -d 'scope=openid' \
  https://login.aai.lifescience-ri.eu/oidc/token
```

One-pass check (client_credentials, resource=, token-exchange, refresh grant):
`shared/scripts/verify-idp-token.sh` — prefer over manual curl.

FTS's own internal token-exchange (`TOKEN_MODE=managed`, LS AAI):
```bash
kubectl -n dep-dlm-sandbox exec pod/ftsdb-0 -- \
  mysql -ufts -pfts fts -e "SELECT token_id, audience FROM t_token ORDER BY token_id DESC LIMIT 10;"
```

User flow end-to-end (browser code flow; port-forward/`/etc/hosts`/CA setup as runbook 01):
```bash
export RUCIO_CONFIG=/workspaces/dep-dlm-testbed/shared/config/rucio/egi-dev/oidc-client.cfg
rucio whoami   # browser login, paste the code
echo "Hello from egi-dev" >> /tmp/hello-egi.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-egi.txt
```
LS AAI: swap `RUCIO_CONFIG` to `ls-aai-dev/oidc-client.cfg`; remember the
VO-membership prerequisite (access-denied page ≠ OIDC error).
