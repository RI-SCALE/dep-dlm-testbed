# Runbook 2 — Bring Your Own IdP

## Purpose
Point Rucio, FTS and your RSEs at an external OIDC issuer (e.g. EGI Check-In,
LS AAI, Keycloak) instead of the bundled one. Covers where issuer, audience,
client and **scopes** must land — including the distinction between the
interactive user flow and the daemon (service) flow, the most common source
of errors.

## Prerequisites
- An OIDC issuer reachable from the cluster, with a discovery endpoint at
  `<issuer>/.well-known/openid-configuration`.
- A client registered on the IdP with both `authorization_code` and
  `client_credentials` grant types enabled (see "One client, two flows" below).
- Storage endpoints (XRootD/WebDAV) that accept the issuer's tokens.
- A CA bundle the server trusts that includes the issuer's chain (see "CA trust").

> **EGI Check-In credentials:** the `client_id` / `client_secret` for
> `idpsecrets.json` are not self-service. Replace the `<valid client id>` /
> `<valid client secret>` placeholders in
> `shared/config/rucio/egi-dev/idpsecrets.json`, then reseed via the gitops
> target (not the raw seed script) so Argo/Flux and Vault re-render
> consistently. Export the env vars first rather than passing them inline —
> this also matches how CI invokes it:
>
> ```bash
> export GITOPS_ENV=sandbox
> export GITOPS_REPO_URL=https://github.com/ri-scale/dep-dlm-testbed.git
> export GITOPS_REVISION=main
> export SCOPE_PROFILE=egi-dev
> export TOKEN_MODE=unmanaged   # egi-dev only passes with client_credentials —
>                                # see the token_strategy caveat below
> make argocd-install   # or: make flux-install
> make init
> ```
>
> **To unblock a running sandbox without a reseed**, patch Vault directly
> instead (use `kv patch`, not `put` — `dep-dlm/secrets` also holds
> `server.cfg` and `alembic.ini`):
> ```bash
> kubectl exec -n dep-dlm-sandbox vault-0 -- sh -c '
>   VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
>   vault kv get -mount=secret -field=idpsecrets.json dep-dlm/secrets
> ' | sed -e "s|<valid client id>|$OIDC_CLIENT_ID|g" -e "s|<valid client secret>|$OIDC_CLIENT_SECRET|g" > /tmp/idpsecrets.json
> kubectl cp /tmp/idpsecrets.json dep-dlm-sandbox/vault-0:/tmp/idpsecrets.json
> kubectl exec -n dep-dlm-sandbox vault-0 -- sh -c '
>   VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
>   vault kv patch -mount=secret dep-dlm/secrets idpsecrets.json=@/tmp/idpsecrets.json
> '
> rm /tmp/idpsecrets.json
> kubectl annotate externalsecret testbed-secrets -n dep-dlm-sandbox force-sync=$(date +%s) --overwrite
> kubectl rollout restart deployment rucio-server rucio-daemons-conveyor-finisher \
>   rucio-daemons-conveyor-poller rucio-daemons-conveyor-submitter \
>   rucio-daemons-judge-cleaner rucio-daemons-judge-evaluator rucio-daemons-reaper \
>   -n dep-dlm-sandbox
> ```
> This doesn't survive a reseed — still update the repo file for anything
> persistent.

> **LS AAI credentials:** same non-self-service caveat applies — client
> registration on `login.aai.lifescience-ri.eu` requires LS AAI support
> involvement (contact `support@aai.lifescience-ri.eu` or Federation
> Registry access if already granted). Real credentials go into the
> `<valid client id>`/`<valid client secret>` placeholders in
> `shared/config/rucio/ls-aai-dev/idpsecrets.json`. Reseed the same way as
> EGI above, with `SCOPE_PROFILE=ls-aai-dev`. Both `TOKEN_MODE=unmanaged`
> *and* `TOKEN_MODE=managed` are confirmed working end-to-end for ls-aai-dev
> (see the token-strategy section below). In CI, this profile is seeded
> from `secrets.LS_AAI_DEV_OIDC_CLIENT_ID`/`_SECRET` — see
> `.github/workflows/ls-aai-dev.yml`, which runs both token modes.

## One client, two flows

`idpsecrets.json` is keyed by issuer, not by grant type, so a single
registered client can serve both flows Rucio needs, as long as the IdP
registration enables both grant types and both scope sets:

| Flow | Grant type | Used by | Needs capability scopes (`read:/ write:/`)? |
|------|-----------|---------|---------------------------------------------|
| Interactive | `authorization_code` (browser) | `rucio whoami`, `rucio upload`/`download` | Yes — only if users run upload/download |
| Service/daemon | `client_credentials` | conveyor submitter → FTS → storage (TPC) | Yes — always, for server-to-server transfers |

This is what egi-dev currently does (one client, both grants enabled). Splitting
into two separate clients is a production-hardening option worth considering
later — it buys audit clarity, a smaller blast radius if a daemon's mounted
secret leaks, and independent rotation/revocation — but isn't required for
this to work and collapses the most common failure mode from this setup
(capability scopes present on one client but not the other) since there's
only one scope set to get right.

If you do split clients and the IdP issues capability scopes for one grant
type but not the other, you get asymmetric failures: TPC works but
`rucio upload` fails with `invalid_scope` / "no authorization content
returned". Fix by registering scopes on the correct client, not by changing
`rucio.cfg`.

> **LS AAI note:** its scope set is more restrictive than EGI's — there is
> no WLCG-style path-scoped concept at all (`read:/`, `write:/` are
> rejected outright, on any grant). This isn't an asymmetric-scopes problem
> in the usual sense; it's handled at a different layer entirely — see
> "Creating the client in LS AAI" below.

## Creating the client in EGI Check-In Dev

Client registration is **not self-service** for this project — see
Prerequisites. This section documents what gets requested, for anyone with
Federation Registry access to replicate it.

1. EGI Federation Registry → **Manage Services** → register a new service (or
   request reconfiguration of an existing one).
2. **Protocol Specific** → **OIDC**.
3. **Application Type**: `Web`.
4. **Grant Types**: enable `client credentials` and `authorization code`
   (add `token-exchange` only if you plan to use `token_strategy=exchange` —
   see the caveat below for why that's currently non-viable against egi-dev).
5. **Token Endpoint Authorization Method**: `Client Secret over HTTP Basic`.
6. **Scope**: at least `openid`, `profile`, `offline_access`,
   `eduperson_entitlement`, `read:/`, `write:/`.
7. **Redirect URI(s)**: `http://localhost:8090/auth/oidc_redirect`,
   `/auth/oidc_code`, `/auth/oidc_token`. EGI Check-In only allows
   `http://localhost` (not `https://`) for non-production registrations.
8. **Refresh Tokens**: enable if using `token_strategy=exchange` (needs
   `offline_access`).
9. Submit and self-approve on Dev/Demo (production needs admin approval —
   see EGI's [SP integration workflow](https://docs.egi.eu/providers/check-in/sp/)).
10. Copy `client_id`/`client_secret` into `idpsecrets.json` (see Prerequisites).

> **No per-RSE clients exist on egi-dev today.** Not required for
> `client_credentials` mode; *would* be required for `token_strategy=exchange`
> (see below).

## Creating the client in LS AAI

Also not self-service — requires LS AAI support (`support@aai.lifescience-ri.eu`)
or Federation Registry access. What's been confirmed working for this
project and how it differs from the EGI flow above:

1. **Grant types**: enable `client_credentials` (required — this is what
   the daemon/TPC path uses) and `authorization_code` if the interactive
   flow is needed. **Also enable `token-exchange`** — `token_strategy=exchange`
   (managed mode) is confirmed working end-to-end against LS AAI once the
   FTS and Rucio-side fixes below are applied. Also enable **"Issue refresh
   tokens for this client"** — confirmed required and present on the
   working registration.
2. **Register Resource Indicators (RFC 8707)** for every RSE/service this
   client transfers to/from, e.g. `https://teapot1.example.org/`,
   `https://teapot2.example.org/`, `https://xrd3.example.org/`,
   `https://xrd4.example.org/`, `https://fts.example.org/`. Confirmed
   present and required on the working registration — without a resource
   registered, `resource=` requests for that value are rejected.
3. **Scope set is fixed and restrictive.** Unlike EGI, LS AAI's client only
   accepts a specific scope list: `openid`, `profile`, `email`,
   `offline_access`, `eduperson_entitlement`. There is **no** WLCG-style
   path-scoped concept — `read:/`, `write:/`-shaped scopes are rejected
   outright on `client_credentials` and `token_exchange`. This is handled
   entirely in `idpsecrets.json`, not by requesting different scopes at
   registration time:
   - `capabilities.scope_map` maps every storage scope
     (`storage.read`/`storage.modify`/`storage.create`) to `""` — dropped
     from the request, not remapped to an LS AAI equivalent.
   - `capabilities.fts_client_scope` is set explicitly to `"openid"`,
     since FTS's own client_credentials auth call has nothing meaningful to
     derive from the (intentionally empty) `scope_map`.
   - `capabilities.drop_scopes` is empty (`[]`) for LS AAI — confirmed via
     `shared/scripts/verify-idp-token.sh`'s refresh-token-grant check that
     LS AAI issues and honors `offline_access` cleanly on both
     `client_credentials` and `token_exchange`.
   - See `docs/patches.md`'s "Per-issuer OIDC capabilities" section for
     the full mechanism and rationale.
4. **`resource=` (RFC 8707) is honored on both `client_credentials` and
   `token_exchange`** — unlike EGI, where it's only honored on the former.
   Combined with the FTS-side fix described below, this is what makes
   `token_strategy=exchange` viable against LS AAI, unlike EGI.
5. **The test-phase environment requires VO membership.** The
   authenticating identity must belong to
   `Life Science Community - Test Environment` before login succeeds. If
   you see an access-denied page listing required organizational units,
   register at
   `https://signup.aai.lifescience-ri.eu/fed/registrar?vo=lifescience_test`
   with the same identity first; propagation can take a few minutes.
6. Copy `client_id`/`client_secret` into
   `shared/config/rucio/ls-aai-dev/idpsecrets.json`.

> **`user-mapping.csv` needs the client's own `client_credentials` sub,
> too** — not just end-user subs. Teapot's automated test fixtures
> (`conftest.py`'s `teapot_token`) authenticate *as the client itself*, not
> a federated user, and will 401 with "local user for sub claim ... does
> not exist" without a row for it in
> `shared/config/teapot/ls-aai-dev/user-mapping.csv`. Decode a
> `client_credentials` token from the client to get this `sub` (same
> first-step as any new-IdP onboarding — see runbook 06, step 0).

> **No per-RSE *client* registrations exist on ls-aai-dev today** — RSEs
> are registered as **resource indicators** on the single testbed client
> instead (see step 2 above), which is what makes `resource=` work without
> per-RSE OAuth clients the way EGI's exchange path would need.

## CA trust: the server must trust the issuer

Rucio's OIDC discovery honours `REQUESTS_CA_BUNDLE`, pointing at
`/etc/grid-security/certificates/tls_ca_bundle.pem`. `rucio_ca.pem` in the
same directory holds **only** the internal Rucio CA — using it for OIDC
discovery against an external issuer fails with `CERTIFICATE_VERIFY_FAILED
... unable to get local issuer certificate`, confirmed against
`aai-dev.egi.eu` (200 via `tls_ca_bundle.pem`, SSL handshake failure via
`rucio_ca.pem`). Use a combined bundle = system bundle + internal Rucio CA,
mounted as `tls_ca_bundle.pem`.

> **egi-dev:** a ready combined bundle (system roots + Rucio Dev CA, trusts
> the EGI GÉANT/HARICA chain) is checked in at
> `shared/config/rucio/egi-dev/tls_ca_bundle.pem`. To replicate:
> `cp shared/config/rucio/egi-dev/tls_ca_bundle.pem certs/tls_ca_bundle.pem`.
> Don't inline the full system store into a Helm-tracked file — trips Helm's
> 1 MiB release-secret limit; keep it on the compose-mounted cert path or
> concatenate at runtime.
>
> `rucio_ca.pem` still matters separately — it's what `rucio.cfg`'s
> `[conveyor] cacert` points at for FTS/gfal transfers, a different trust
> path from OIDC discovery. Verify each with its own bundle (see
> Verification).

> **ls-aai-dev:** LS AAI's TLS chain is system-trusted in this testbed's
> base images — confirmed with no CA-related failures across both token
> modes. No combined bundle has been needed, unlike egi-dev.

## Configuration reference — where things land

| Setting | File / location | Example |
|---------|-----------------|---------|
| Issuer (exact string!) | `idpsecrets.json` → `issuer`; top-level key | EGI: `https://aai-dev.egi.eu/auth/realms/egi` — LS AAI: `https://login.aai.lifescience-ri.eu/oidc/` (**note trailing slash**, unlike EGI) |
| Client id/secret | `idpsecrets.json` → `client_id`/`client_secret` | per-environment |
| Redirect URIs | `idpsecrets.json` → `redirect_uris` (server only) | `.../auth/oidc_redirect`, `/oidc_code`, `/oidc_token` |
| Audience | `idpsecrets.json` → `audience`; `rucio.cfg [oidc] expected_audience` | `rucio` |
| Issuer + admin issuer | `rucio.cfg [oidc] issuer` / `admin_issuer` | issuer URL (not an alias key) |
| Daemon token strategy | `rucio.cfg [oidc] token_strategy` | `client_credentials` or `exchange` |
| Requested user scope | `rucio.cfg [client] oidc_scope` | `openid profile eduperson_entitlement offline_access` |
| Accepted scope (validation) | `rucio.cfg [oidc] expected_scope` | keep permissive |
| Client host (drives redirect scheme) | `oidc-client.cfg [client] rucio_host`/`auth_host` | `http://localhost:8090` |
| RSE token support | RSE attribute `oidc_support=True` + `davs`/`https` scheme | required for `_use_tokens` |
| Per-issuer grant capabilities | `idpsecrets.json` → `capabilities` (`resource_param`, `scope_map`, `drop_scopes`, `fts_client_scope`) | LS AAI: `scope_map` maps storage scopes to `""`, `fts_client_scope: "openid"`, `drop_scopes: []` |
| FTS resource-indicator profile | `fts3config` → `OidcResourceIndicatorProfile` | `egi` or `lsaai` — makes FTS's own internal token-exchange send `resource=` instead of `audience=`; see managed-mode note below |

> **Issuer must match exactly.** Rucio does an exact-string lookup against the
> `idpsecrets.json` key and the issuer advertised by discovery — match the
> `.well-known` value byte-for-byte, including trailing-slash convention.
> EGI Check-In Dev advertises **no** trailing slash; Keycloak realms usually
> do; **LS AAI's `iss` claim does include a trailing slash**
> (`https://login.aai.lifescience-ri.eu/oidc/`). Mismatch →
> `Failed to discover token endpoint` or 500 on `/auth/oidc`. `admin_issuer`
> must be the issuer URL, not an alias.
>
> This exact-match requirement applies everywhere the issuer string is
> compared, not just `idpsecrets.json` — `rucio.cfg`'s `issuer`/
> `admin_issuer`, Teapot's `trusted_OP`, and XRootD's `scitokens.conf`
> issuer entry all need the same byte-for-byte value. See
> `docs/patches.md`'s "OIDC issuer string consistency" section for the
> distinction between *building* a URL (safe to strip a trailing slash
> before appending a path) and *matching* a claim (must not be normalized).

> **token_strategy server cfgs:** the daemon flow is selected by
> `[oidc] token_strategy`; ship the matching server cfg —
> `server.client-credentials.cfg` or `server.token-exchange.cfg`.

> **`token_strategy=exchange` is currently non-viable against EGI Check-In
> Dev.** `resource=` (RFC 8707) is honored on `client_credentials`,
> `authorization_code`, `refresh_token` and `device` grants, but **not** on
> `token-exchange`. On exchange, EGI only supports `audience=`, which must
> match a **registered client_id** — no equivalent of "any URI". Since
> per-RSE clients aren't registered, an exchanged token comes back with
> **no `aud` claim at all**, which storage endpoints reject.
>
> EGI has confirmed plans to extend Keycloak to honor `resource=` on
> token-exchange too — no ETA. Until then, **use
> `token_strategy=client_credentials`** (`server.client-credentials.cfg`,
> i.e. `TOKEN_MODE=unmanaged`) for `SCOPE_PROFILE=egi-dev`. Confirmed in CI:
> the cross-protocol transfer test fails under `TOKEN_MODE=managed` with
> `{"error":"invalid_client","error_description":"Audience not found"}` and
> passes under `TOKEN_MODE=unmanaged`. A repro script confirming the gap
> (mint via `client_credentials`+`resource=`, exchange via RFC 8693,
> observe the exchanged token has no `aud` claim).

> **`token_strategy=exchange` IS viable against LS AAI** — both
> `TOKEN_MODE=unmanaged` and `TOKEN_MODE=managed` are confirmed passing the
> full XRootD/Teapot/cross-protocol suite end-to-end. Getting there
> required three coordinated fixes:
> - `rse.py`'s `determine_scope_for_rse()` — always include `openid` in the
>   constructed scope (LS AAI issues no refresh token for a
>   `client_credentials` request missing it).
> - `oidc.py`'s `get_token_for_account_operation()` — only prefer a cached
>   subject token for exchange if it actually has a `refresh_token`, not
>   just a matching scope substring (prevents a scope-incomplete token
>   from getting permanently reselected on retry).
> - FTS's `TokenExchangeExecutor.cpp` — recognize `OidcResourceIndicatorProfile=="lsaai"`
>   and extract the URI-shaped value from `token.audience` (a
>   space-joined, unordered multi-value `aud` claim) rather than assuming
>   it starts with `http(s)://`, then send only that value as `resource=`.
>
> Also LS AAI-specific: RFC 8693 token-exchange requests must include an
> explicit `requested_token_type` parameter or LS AAI rejects them with
> `"No requested_token_type parameter value provided"` — Keycloak/EGI
> apparently default this. Already handled in `oidc.py`'s
> `__exchange_token_oidc`.
>
> **This does not change the EGI conclusion above** — EGI's blocker is a
> genuine IdP-side gap unrelated to any of the three LS AAI bugs. Don't
> assume an EGI fix from FTS/Rucio alone would unblock it.

> **Daemon's idpsecrets:** daemons may mount OIDC config from a *different*
> secret than the server. Update the one the daemon actually mounts, or it
> keeps old scopes. Verify:
> `kubectl get pod <submitter-pod> -n <ns> -o yaml | grep -iA3 idpsecret`

## Steps

1. **Register the client on the IdP** with both `authorization_code` (+
   redirect URIs + user scopes) and `client_credentials` (+ capability
   scopes `read:/ write:/`, or LS AAI's equivalent fixed scope set — see
   "Creating the client in LS AAI" above) enabled. For LS AAI, also enable
   `token-exchange` and register resource indicators if managed mode is
   wanted.

2. **Set issuer/audience/scopes** in `idpsecrets.json` and `rucio.cfg` per
   the table above; ensure CA trust.

3. **Map the external identity to a Rucio account.** A valid token
   *authenticates* but isn't *authorized* until its `SUB`+`ISS` is bound to
   an account. Run **in-pod / in-container** — the dev shell's own client
   uses OIDC and would deadlock on the broken flow:

```bash
   kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
     rucio-admin identity add --type OIDC \
       --id "SUB=aa886829a0a894933008498cfe62264d899422f55b408560a259311776f0e519@egi.eu, ISS=https://aai-dev.egi.eu/auth/realms/egi" \
       --account randomaccount --email marvin.gajek@cern.ch
```

   (Compose: `docker exec -t compose-rucio-server-1 rucio-admin identity add ...`, same flags.)

   `SUB`/`ISS` must match the token's claims exactly; `--account` must match
   the account in the client cfg. Get the user's `sub`/email from their EGI
   Check-In personal-info page.

   LS AAI equivalent — note the `@lifescience-ri.eu` suffix on the sub and
   the trailing-slash issuer:

```bash
   kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
     rucio-admin identity add --type OIDC \
       --id "SUB=28f7bc3a2d32a4a722f6eb24f77f7fbe42eb6471@lifescience-ri.eu, ISS=https://login.aai.lifescience-ri.eu/oidc/" \
       --account randomaccount --email marvin.gajek@cern.ch
```

   (Compose: same, swapping `kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server --`
   for `docker exec -t compose-rucio-server-1`.)

4. **Confirm the storage endpoints trust the issuer** (XRootD
   `scitokens.conf` / Teapot config has the issuer registered).

   For LS AAI specifically, also confirm the **Storm-WebDAV version behind
   Teapot is ≥1.13.0**. LS AAI issues RFC 9068 `at+jwt`-typed access
   tokens; Storm-WebDAV versions before 1.13.0 reject these with
   `"the given typ value needs to be one of [JWT]"` regardless of otherwise
   correct `application.yml` configuration. Check/set this via
   `deploy/compose/Dockerfile.teapot`'s `STORM_VERSION` build arg.

5. **If using `TOKEN_MODE=managed` against LS AAI**, confirm the FTS image
   in use includes the `TokenExchangeExecutor` fixes noted above. An FTS
   image built before those fixes will reproduce `"[TokenExchange] Failed
   to get refresh token for source token: HTTP 400 : Server Error"` even
   with fully correct Rucio-side config.

## Verification

CI's `make test-rucio-transfers` / `make test-rucio-deletion` run the full
XRootD/Teapot/cross-protocol suite end-to-end against egi-dev (under
`TOKEN_MODE=unmanaged` only — see the EGI caveat above) and, via
`.github/workflows/ls-aai-dev.yml`, against ls-aai-dev under **both**
`TOKEN_MODE=unmanaged` and `TOKEN_MODE=managed` — that's the authoritative
check for both profiles. The commands below are for manual debugging when a
CI failure needs isolating to a specific layer. Run inside the pod that
needs checking — `rucio-server` or `fts` below, depending on what you're
isolating. (Compose equivalent: swap
`kubectl -n dep-dlm-sandbox exec deploy/<svc> --` for
`docker exec compose-<svc>-1`.)

```bash
# CA trust — should print 200 against the bundle REQUESTS_CA_BUNDLE points at
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- python3 -c "
import requests
print(requests.get(
  'https://aai-dev.egi.eu/auth/realms/egi/.well-known/openid-configuration',
  verify='/etc/grid-security/certificates/tls_ca_bundle.pem').status_code)
"

# Daemon client_credentials sanity — should return 200 with capability scopes
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- python3 -c "
import requests, json, base64
cfg = list(json.load(open('/opt/rucio/etc/idpsecrets.json')).values())[0]
r = requests.post(cfg['issuer']+'/protocol/openid-connect/token',
    auth=(cfg['client_id'], cfg['client_secret']),
    data={'grant_type':'client_credentials','scope':cfg['scope']})
print(r.status_code)
tok = r.json()['access_token']; p = tok.split('.')[1]; p += '=' * (-len(p) % 4)
print('scope:', json.loads(base64.urlsafe_b64decode(p)).get('scope'))
"
```

For LS AAI, the equivalent client_credentials sanity check needs the token
endpoint resolved via discovery rather than a Keycloak-shaped path:

```bash
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- python3 -c "
import requests, json, base64
cfg_all = json.load(open('/opt/rucio/etc/idpsecrets.json'))
cfg = cfg_all['https://login.aai.lifescience-ri.eu/oidc/']
discovery = requests.get(cfg['issuer'].rstrip('/') + '/.well-known/openid-configuration').json()
r = requests.post(discovery['token_endpoint'],
    auth=(cfg['client_id'], cfg['client_secret']),
    data={'grant_type':'client_credentials','scope':'openid'})
print(r.status_code)
tok = r.json()['access_token']; p = tok.split('.')[1]; p += '=' * (-len(p) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2))
"
```

Isolating a bad/malformed `OIDC_CLIENT_ID` — confirm length first:

```bash
echo -n "$OIDC_CLIENT_ID" | wc -c   # should print 36 for a standard UUID

curl -s -u "$OIDC_CLIENT_ID:$OIDC_CLIENT_SECRET" \
  -d 'grant_type=client_credentials' -d 'scope=openid' \
  https://login.aai.lifescience-ri.eu/oidc/token
```

`shared/scripts/verify-idp-token.sh` runs `client_credentials`, `resource=`,
`token-exchange`, and refresh-grant checks in one pass. Prefer it over
manual curl commands for routine verification.

```bash
# For TOKEN_MODE=managed (LS AAI), check FTS's own internal token-exchange
# directly — separate from anything Rucio does:
kubectl -n dep-dlm-sandbox exec pod/ftsdb-0 -- \
  mysql -ufts -pfts fts -e \
  "SELECT token_id, audience FROM t_token ORDER BY token_id DESC LIMIT 10;"
```

```bash
# User flow end to end (browser code flow). Port-forwards, /etc/hosts and CA
# trust dir setup are identical to the local profile — see runbook 01.
export RUCIO_CONFIG=/workspaces/dep-dlm-testbed/shared/config/rucio/egi-dev/oidc-client.cfg
rucio whoami   # browser login via aai-dev.egi.eu, paste the code

echo "Hello from egi-dev" >> /tmp/hello-egi.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-egi.txt
```

For LS AAI, swap `RUCIO_CONFIG` to `ls-aai-dev/oidc-client.cfg` and remember
the VO-membership prerequisite above (an identity not yet in
`lifescience_test` sees an access-denied page at login, not an OIDC error):

```bash
export RUCIO_CONFIG=/workspaces/dep-dlm-testbed/shared/config/rucio/ls-aai-dev/oidc-client.cfg
rucio whoami

echo "Hello from ls-aai-dev" >> /tmp/hello-lsaai.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-lsaai.txt
```
