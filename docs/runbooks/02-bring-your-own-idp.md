# Runbook 2 — Bring Your Own IdP

## Purpose
Point Rucio, FTS and your RSEs at an external OIDC issuer (e.g. EGI Check-In,
Keycloak) instead of the bundled one. Covers where issuer, audience, client and
**scopes** must land — including the distinction between the interactive user
flow and the daemon (service) flow, the most common source of errors.

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
> kubectl delete job vault-seed-once -n dep-dlm-sandbox --ignore-not-found
> make argocd-install   # or: make flux-install
> ```
>
> **To unblock a running sandbox without a reseed**, patch Vault directly
> instead (use `kv patch`, not `put` — `dep-dlm/rucio` also holds
> `server.cfg` and `alembic.ini`):
> ```bash
> kubectl exec -n dep-dlm-sandbox vault-0 -- sh -c '
>   VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
>   vault kv get -mount=secret -field=idpsecrets.json dep-dlm/rucio
> ' | sed -e "s|<valid client id>|$OIDC_CLIENT_ID|g" -e "s|<valid client secret>|$OIDC_CLIENT_SECRET|g" > /tmp/idpsecrets.json
> kubectl cp /tmp/idpsecrets.json dep-dlm-sandbox/vault-0:/tmp/idpsecrets.json
> kubectl exec -n dep-dlm-sandbox vault-0 -- sh -c '
>   VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
>   vault kv patch -mount=secret dep-dlm/rucio idpsecrets.json=@/tmp/idpsecrets.json
> '
> rm /tmp/idpsecrets.json
> kubectl annotate externalsecret rucio-server-cfg -n dep-dlm-sandbox force-sync=$(date +%s) --overwrite
> kubectl rollout restart deployment rucio-server rucio-daemons-conveyor-finisher \
>   rucio-daemons-conveyor-poller rucio-daemons-conveyor-submitter \
>   rucio-daemons-judge-cleaner rucio-daemons-judge-evaluator rucio-daemons-reaper \
>   -n dep-dlm-sandbox
> ```
> This doesn't survive a reseed — still update the repo file for anything
> persistent.

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
later — it buys audit clarity (a token's source is unambiguous), a smaller
blast radius if a daemon's mounted secret leaks, and independent
rotation/revocation — but isn't required for this to work, and collapses
the most common failure mode from this setup (capability scopes present on
one client but not the other) since there's only one scope set to get right.

If you do split clients, and the IdP issues capability scopes for one grant
type but not the other, you get asymmetric failures: TPC works but
`rucio upload` fails with `invalid_scope` / "no authorization content
returned". Fix by registering scopes on the correct client, not by changing
`rucio.cfg`.

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

## Configuration reference — where things land

| Setting | File / location | Example |
|---------|-----------------|---------|
| Issuer (exact string!) | `idpsecrets.json` → `issuer`; top-level key | `https://aai-dev.egi.eu/auth/realms/egi` |
| Client id/secret | `idpsecrets.json` → `client_id`/`client_secret` | per-environment |
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
> `.well-known` value byte-for-byte, including trailing-slash convention.
> EGI Check-In Dev advertises **no** trailing slash; Keycloak realms usually
> do. Mismatch → `Failed to discover token endpoint` or 500 on `/auth/oidc`.
> `admin_issuer` must be the issuer URL, not an alias.

> **token_strategy server cfgs:** the daemon flow is selected by
> `[oidc] token_strategy`; ship the matching server cfg —
> `server.client-credentials.cfg` or `server.token-exchange.cfg`.

> **`token_strategy=exchange` is currently non-viable against EGI Check-In
> Dev.** `resource=` (RFC 8707) is honored on `client_credentials`,
> `authorization_code`, `refresh_token` and `device` grants, but **not** on
> `token-exchange`. On exchange, EGI only supports `audience=`, which must
> match a **registered client_id** — no equivalent of "any URI". Since
> per-RSE clients aren't registered, an exchanged token comes back with **no
> `aud` claim at all**, which storage endpoints reject.
>
> EGI has confirmed plans to extend Keycloak to honor `resource=` on
> token-exchange too — no ETA. Until then, **use
> `token_strategy=client_credentials`** (`server.client-credentials.cfg`,
> i.e. `TOKEN_MODE=unmanaged`) for `SCOPE_PROFILE=egi-dev`. Confirmed in CI:
> the cross-protocol transfer test fails under `TOKEN_MODE=managed` with
> `{"error":"invalid_client","error_description":"Audience not found"}`, and
> passes under `TOKEN_MODE=unmanaged`.
>
> Repro script confirming the gap (client id/secret redacted):
> ```bash
> #!/usr/bin/env bash
> set -euo pipefail
> CID="<client id>"; CSECRET="<client secret>"
> ISSUER="https://aai-dev.egi.eu/auth/realms/egi"
> TOKEN_URL="${ISSUER}/protocol/openid-connect/token"
>
> # Step 1: mint a subject token via client_credentials + resource=
> SUBJECT_TOKEN=$(docker exec compose-fts-1 curl -s -u "${CID}:${CSECRET}" \
>   -d 'grant_type=client_credentials' \
>   -d 'resource=https://fts.example.org/' \
>   -d 'scope=openid profile eduperson_entitlement offline_access read:/ write:/' \
>   "$TOKEN_URL" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
>
> # Step 2: exchange it (RFC 8693), targeting a different resource
> EXCHANGE_RESPONSE=$(docker exec compose-fts-1 curl -s -u "${CID}:${CSECRET}" \
>   -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
>   -d "subject_token=${SUBJECT_TOKEN}" \
>   -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
>   -d 'requested_token_type=urn:ietf:params:oauth:token-type:access_token' \
>   -d 'resource=https://xrd3.example.org/' \
>   -d 'scope=openid read:/ write:/' \
>   "$TOKEN_URL")
>
> # Step 3: decode the exchanged token — aud will be absent
> echo "$EXCHANGE_RESPONSE" | python3 -c "
> import sys, json, base64
> resp = json.load(sys.stdin)
> t = resp['access_token']
> p = t.split('.')[1]; p += '=' * (-len(p) % 4)
> claims = json.loads(base64.urlsafe_b64decode(p))
> print(json.dumps(claims, indent=2))
> print('aud present:', 'aud' in claims)
> "
> ```
> Expected: `aud present: False`.

> **Daemon's idpsecrets:** daemons may mount OIDC config from a *different*
> secret than the server. Update the one the daemon actually mounts, or it
> keeps old scopes. Verify:
> `kubectl get pod <submitter-pod> -n <ns> -o yaml | grep -iA3 idpsecret`

## Steps

1. **Register the client on the IdP** with both `authorization_code` (+
   redirect URIs + user scopes) and `client_credentials` (+ capability
   scopes `read:/ write:/`) enabled.

2. **Set issuer/audience/scopes** in `idpsecrets.json` and `rucio.cfg` per
   the table above; ensure CA trust.

3. **Map the external identity to a Rucio account.** A valid token
   *authenticates* but isn't *authorized* until its `SUB`+`ISS` is bound to
   an account. Run **in-pod / in-container** — the dev shell's own client
   uses OIDC and would deadlock on the broken flow:

   ```bash
   # k8s (e.g.)
   kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
     rucio-admin identity add --type OIDC \
       --id "SUB=aa886829a0a894933008498cfe62264d899422f55b408560a259311776f0e519@egi.eu, ISS=https://aai-dev.egi.eu/auth/realms/egi" \
       --account randomaccount --email marvin.gajek@cern.ch

   # compose (e.g.)
   docker exec -t compose-rucio-server-1 \
     rucio-admin identity add --type OIDC \
       --id "SUB=aa886829a0a894933008498cfe62264d899422f55b408560a259311776f0e519@egi.eu, ISS=https://aai-dev.egi.eu/auth/realms/egi" \
       --account randomaccount --email marvin.gajek@cern.ch
   ```
   `SUB`/`ISS` must match the token's claims exactly; `--account` must match
   the account in the client cfg. Get the user's `sub`/email from their EGI
   Check-In personal-info page.

4. **Confirm the storage endpoints trust the issuer** (XRootD
   `scitokens.conf` / Teapot config has the issuer registered).

## Verification

CI's `make test-rucio-transfers` / `make test-rucio-deletion` run the full
XRootD/Teapot/cross-protocol suite end-to-end against egi-dev under
`TOKEN_MODE=unmanaged` — that's the authoritative check. The scripts below
are for manual debugging when a CI failure needs isolating to a specific
layer (CA trust vs. daemon credentials vs. TPC itself).

```bash
# CA trust — should print 200 against the bundle REQUESTS_CA_BUNDLE points at
python3 -c "import requests; print(requests.get(
  'https://aai-dev.egi.eu/auth/realms/egi/.well-known/openid-configuration',
  verify='/etc/grid-security/certificates/tls_ca_bundle.pem').status_code)"

# Daemon client_credentials sanity — should return 200 with capability scopes
python3 -c "
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

```bash
# Manual TPC sanity check via client_credentials directly against the IdP.
# Only works with token_strategy=client_credentials (TOKEN_MODE=unmanaged).
# Under token_strategy=exchange this bypasses the daemon path entirely, so a
# pass here does NOT confirm exchange-mode works — see the caveat above.

# k8s
kubectl -n dep-dlm-sandbox exec deploy/fts -- \
  env OIDC_CLIENT_ID="$OIDC_CLIENT_ID" OIDC_CLIENT_SECRET="$OIDC_CLIENT_SECRET" \
  bash -c '
    TOKEN=$(curl -s -u "$OIDC_CLIENT_ID:$OIDC_CLIENT_SECRET" \
      -d grant_type=client_credentials \
      -d "scope=read:/ write:/" \
      -d "resource=https://teapot2.example.org/" \
      https://aai-dev.egi.eu/auth/realms/egi/protocol/openid-connect/token \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get(\"access_token\") or d)")
    export BEARER_TOKEN="$TOKEN"
    TS=$(date +%s)
    SRC="davs://teapot1:8081/data/test/src-$TS.txt"
    DST="davs://teapot2:8081/data/test/dst-$TS.txt"
    echo tpc > /tmp/s.txt
    gfal-copy -v file:///tmp/s.txt "$SRC"
    gfal-copy -v "$SRC" "$DST" 2>&1 | grep -iE "ssl|handshake|certificate|verify|error|done|copying|exit"
  '

# compose
docker exec -e OIDC_CLIENT_ID -e OIDC_CLIENT_SECRET compose-fts-1 bash -c '
  TOKEN=$(curl -s -u "$OIDC_CLIENT_ID:$OIDC_CLIENT_SECRET" \
    -d grant_type=client_credentials \
    -d "scope=read:/ write:/" \
    -d "resource=https://teapot2.example.org/" \
    https://aai-dev.egi.eu/auth/realms/egi/protocol/openid-connect/token \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get(\"access_token\") or d)")
  export BEARER_TOKEN="$TOKEN"
  TS=$(date +%s)
  SRC="davs://teapot1:8081/data/test/src-$TS.txt"
  DST="davs://teapot2:8081/data/test/dst-$TS.txt"
  echo tpc > /tmp/s.txt
  gfal-copy -v file:///tmp/s.txt "$SRC"
  gfal-copy -v "$SRC" "$DST" 2>&1 | grep -iE "ssl|handshake|certificate|verify|error|done|copying|exit"
'
```

```bash
# User flow end to end (browser code flow). Port-forwards, /etc/hosts, and CA
# trust dir setup are identical to the local profile — see runbook 01's
# "Run it (login + upload)" if not done yet. Only egi-dev-specific change is
# RUCIO_CONFIG. Skip the `keycloak` /etc/hosts entry from runbook 01 — the
# issuer here is aai-dev.egi.eu, a real public host, not a local port-forward
# target; rucio/teapot1/xrd3 entries are still needed. Everything else in
# runbook 01 (XRootD upload, replication, driving the conveyor by hand)
# carries over as-is — swap in the identity/config from this runbook.
export RUCIO_CONFIG=/workspaces/dep-dlm-testbed/shared/config/rucio/egi-dev/oidc-client.cfg
rucio whoami   # browser login via aai-dev.egi.eu, paste the code

# whoami only proves auth; confirm authorization end-to-end with an upload
# (requires the identity mapping from Step 3 above):
echo "Hello from egi-dev" >> /tmp/hello-egi.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-egi.txt
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CERTIFICATE_VERIFY_FAILED ... unable to get issuer certificate` on `/auth/oidc` | `tls_ca_bundle.pem` lacks the issuer chain | Use combined bundle; for egi-dev, `certs/tls_ca_bundle.pem` |
| `Invalid parameter: redirect_uri` at IdP | `https://localhost` requested, registration not deployed, or path mismatch | Web clients allow `http://localhost` only; exact-match all paths; confirm IdP reconfig is **deployed**, not pending |
| Redirect goes to the wrong host | `redirect_uris` / `rucio_host`/`auth_host` point elsewhere | Point both at your host; restart server so it re-reads `idpsecrets.json` |
| `OIDC authentication failed` but token is valid | Identity not mapped to the account | Run `rucio-admin identity add` (Step 3); SUB/ISS exact, account-matched |
| `invalid_scope` at authorize endpoint | Capability scopes missing on the client's interactive grant | Add `read:/ write:/` as client scopes |
| "no authorization content returned" in browser | Downstream of the IdP `invalid_scope` above | Same fix — it's the IdP, not `rucio.cfg` |
| `unauthorized_client: not enabled to retrieve service account` | Non-service client used for `client_credentials` | Use the service/daemon client, or enable service account |
| `Failed to discover token endpoint` / 500 on `/auth/oidc` | Issuer string mismatch or `admin_issuer` is an alias | Match `.well-known` issuer exactly; set `admin_issuer` to the issuer URL |
| TPC works but `rucio upload` fails | Scopes present on service grant but not interactive grant | Add scopes to the interactive grant |
| 401 on FTS token request | Wrong client mounted by daemon | Patch the secret the daemon actually mounts |
| Exchanged token has no `aud` claim, storage rejects it | `resource=` not honored on `token-exchange` grant (EGI-specific, confirmed) | Switch to `token_strategy=client_credentials` (`TOKEN_MODE=unmanaged`); see caveat above |
| Cross-protocol transfer fails with `{"error":"invalid_client","error_description":"Audience not found"}` | `TOKEN_MODE=managed` (→ `token_strategy=exchange`) used against egi-dev | Reseed with `TOKEN_MODE=unmanaged` |
