# Troubleshooting

Symptom-level fixes for the sandbox. For config reference (what should be
set and why), see [`docs/patches.md`](patches.md) — this doc is about what
to do when something's already broken.

## Bootstrap & deploy

| Symptom | Cause | Fix |
|---|---|---|
| Daemons `CrashLoopBackOff` early | DB bootstrap / Vault seed not finished | Wait for `rucio-bootstrap-db` and `vault-seed` to reach `Completed`; daemons self-recover |
| `make init` says "already exists" | Stack already seeded; init is idempotent | Harmless — let it continue |
| Config changes don't take effect | `idpsecrets.json`/realm are Vault-seeded via external-secrets; editing repo files alone doesn't update pods | Re-seed Vault + restart, or apply live via `kcadm`. Keycloak only imports a realm on first start — a plain restart won't re-import |

## OIDC authentication (browser / `whoami`)

| Symptom | Cause | Fix |
|---|---|---|
| `CERTIFICATE_VERIFY_FAILED ... unable to get issuer certificate` on `/auth/oidc` | `tls_ca_bundle.pem` lacks the issuer chain | Use the combined bundle (egi-dev: `certs/tls_ca_bundle.pem`) |
| `whoami` → 500, apache worker can't read the CA file | CA mounted `0600 root`; discovery hits `PermissionError(13)` | Mount the CA `0644`; `rollout restart deploy/rucio-server` |
| `Failed to discover token endpoint` / 500 on `/auth/oidc` | Issuer string mismatch, or `admin_issuer` is an alias rather than the real issuer URL | Match the `.well-known` issuer exactly, trailing slash included; set `admin_issuer` to the real issuer URL |
| `Invalid parameter: redirect_uri` at the IdP | `https://localhost` requested, registration not deployed, or an exact path mismatch | Web clients allow `http://localhost` only; exact-match all paths including trailing slash; confirm the IdP client config is actually **deployed**, not pending |
| Redirect goes to the wrong host | `redirect_uris` / `rucio_host`/`auth_host` point elsewhere | Point both at your host; restart the server so it re-reads `idpsecrets.json` |
| Redirect goes to `https://rucio/...` unexpectedly | `oidc.py` picks a redirect URI at random from the registered list | Trim that issuer's `redirect_uris` in `idpsecrets.json` down to the `localhost` forms only |
| Printed URL is `https://` but your port-forward is `http` | Server advertises `https` via `X-Forwarded-Proto` regardless of the actual forward | Just open the `http://` form of the printed URL |
| `invalid_scope` at the authorize endpoint | Requested scope isn't registered/requestable on **that issuer's** interactive client — this is issuer-specific, not universal | Check the issuer's actual registered scope set. Confirmed cases: EGI's `rucio` client needs `openid offline_access storage.read:/ storage.modify:/ aud:rucio`; LS AAI's client has no storage-path scopes at all (`storage.read`/`.modify`/`.create` all map to `""` — see `get_capabilities()` in `docs/patches.md`), so only request `openid profile eduperson_entitlement offline_access` there |
| "no authorization content returned" in browser | Downstream of the IdP-side `invalid_scope` above | Same fix — it's the IdP rejecting the scope, not a `rucio.cfg` problem |
| `unauthorized_client: not enabled to retrieve service account` | A non-service client used for `client_credentials` | Use the service/daemon client, or enable "service account" on it |
| `invalid_target` at the token endpoint, error echoes a Python-list-looking string back | `build_url()` collapsed a multi-value `resource=` into one stringified value instead of repeating the param | Fixed in the current `oidc.py` patch (see `docs/patches.md`) — if you still see this, you're on a stale patch |
| Exchanged token has no `aud` claim, storage rejects it | That issuer's `token_exchange` grant doesn't honor `resource=` (confirmed on EGI) | Switch that issuer to `token_strategy=client_credentials` (`TOKEN_MODE=unmanaged`) |
| Cross-protocol transfer fails: `invalid_client`, `"Audience not found"` | `TOKEN_MODE=managed` (→ `token_strategy=exchange`) used against an issuer that needs unmanaged | Reseed with `TOKEN_MODE=unmanaged` |
| Interactive login works but `rucio upload` 401s at the storage PUT (principal logged as `-`) | Interactive token has no usable `aud`; storage's JWT decoder rejects it before authz runs | Make sure the interactive scope set includes whatever populates `aud` for that issuer (e.g. `aud:rucio` on EGI) — check that issuer's requirements, don't assume one scope list fits all |

## Permissions

| Symptom | Cause | Fix |
|---|---|---|
| `401` at `POST /replicas`, client re-launches browser login | This is **authorization**, not authentication — the client misreads it | Grant the missing account attribute (e.g. `rucio-admin account add-attribute <acct> --key admin --value True`, run as admin) — don't re-authenticate |

## Upload / download (gfal2, client-side)

| Symptom | Cause | Fix |
|---|---|---|
| `gfal2` import/build fails on Jammy | libgfal2 2.20.3 lacks `bring_online_v2`; pip build can't compile it | Use the conda-forge client, not system pip |
| Upload fails: "Scope X not found" | Scope belongs to a different account than the uploader | Upload under a scope the account actually owns (`--scope <account>`) |
| Re-upload of the same filename fails (`Data Identifier Already Exists` / checksum mismatch) | Not a pipeline bug — DIDs are immutable | Use a fresh filename per attempt |
| `Domain name resolution failed` / `connection reset` at the gfal PUT | Missing `/etc/hosts` entry for the storage host, or the port-forward doesn't match the RSE's PFN port | Add the `/etc/hosts` entry; forward the PFN's port, not your forward's left-hand side (Teapot davs `8081`, XRootD davs `1094`) |
| `rucio download` fails instantly, no useful error | Download is a direct client pull, not server-side like a rule — it needs its own port-forward for whichever RSE you're pulling from | Forward that RSE's service on its PFN port; if it's XRD3/XRD4 or TEAPOT1/TEAPOT2 sharing a port, stop the paired forward first |
| `gfal-ls` → "issuer is not trusted" | `X509_CERT_DIR` points at a file, or hash symlinks are missing | Make it a real directory; copy the CA + `*.0` files; `openssl rehash`; export `X509_CERT_DIR` |
| `gfal-ls` → `HTTP 401` | `gfal-ls` sends no token — expected, it isn't `rucio upload` | Judge auth by `rucio upload`, which attaches the bearer token |

## Transfers (rules / FTS)

| Symptom | Cause | Fix |
|---|---|---|
| Rule `STUCK` / `NO_SOURCES`, "dropped by PathDistance" | No RSE distance configured, or no source replica with bytes | Add a distance in both directions; confirm the source DID has bytes |
| Rule `STUCK` + `exchange returned no token aud=<rse>` | FTS token path not seeded | Re-run `make init TOKEN_MODE=managed`; check `ftsdb-0`'s `t_token_provider` |
| Transfer falls back to X.509/cert instead of tokens | RSE not `oidc_support=True`, or scheme isn't `davs`/`https` | `_use_tokens` requires **both** on every endpoint in the hop — set the attribute and confirm scheme |
| `401` on FTS token request | Wrong client mounted by the daemon | Patch the secret the daemon actually mounts, not just any idpsecrets file |
| Copy fails with `HTTP 500` | Storage-side server error, not auth | Check the endpoint's server logs — a 500 (not 401/403) means auth succeeded |
| `401`/`403` on copy | Token lacks the required scope, or the destination doesn't trust the issuer | Verify token scopes and confirm the issuer is registered on that endpoint |
| Source `404` | Replica registered in Rucio but bytes aren't actually present | Use a DID with a physically present replica |

## Quick reference: common failure → likely cause

| Failure | Likely cause |
|---|---|
| `NO_SOURCES` / PathDistance drop | Missing RSE distance |
| `insufficient quota` | No account limit set on the destination RSE |
| Transfer not using tokens | RSE missing `oidc_support`, or wrong scheme |
| `invalid_scope` on login | Requested scope not registered on that issuer's interactive client |
| FTS token `401` | Wrong/unprovisioned daemon client |
| Copy `HTTP 500` | Storage-side server error, not Rucio/auth |
