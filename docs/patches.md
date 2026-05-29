# Patches

Minimal patches applied to upstream components to make OIDC-only token-based
transfers work in the testbed. X.509/GSI is explicitly out of scope.
Each patch is applied by bind-mounting the patched file over the original
inside the container (Compose) or via a ConfigMap volume mount (Kubernetes).

---

## Rucio — `transfertool/fts3.py`

**Source:** `rucio/rucio-server` image, Python package `rucio.transfertool.fts3`
**Upstream ref:** [rucio/rucio @ main — transfertool/fts3.py](https://github.com/rucio/rucio/blob/master/lib/rucio/transfertool/fts3.py)

### Changes

**1. `_file_from_transfer` — pass `account` and per-RSE `audience` to `request_token`**

Upstream calls `request_token(audience, scope)` for source and destination
storage tokens. The testbed adds `account=rws.account` and uses the
per-RSE audience derived via `determine_audience_for_rse(rse_id)`. The
`account` argument routes the call through the exchange path in the
patched `oidc.py` (managed mode); in unmanaged mode the same call falls
through to `client_credentials`, where the patched `oidc.py` activates
the matching `aud:<audience>` optional scope. The patch also raises
`TransferToolWrongAnswer` when `request_token` returns `None`, so
silent token-acquisition failures become visible.

```python
# Patch
src_token = request_token(src_audience, src_scope, account=rws.account)
if src_token is None:
    raise TransferToolWrongAnswer(
        f"Could not procure source token for {transfer.src.rse.name}"
    )
# Upstream
t_file["source_tokens"].append(request_token(src_audience, src_scope))
```

**2. `build_job_params` — set `unmanaged_tokens` based on `oidc.token_strategy`**

In unmanaged mode FTS must accept pre-fetched bearer tokens as-is and
skip the `TOKEN_PREP` exchange and refresh. In managed mode FTS owns
the lifecycle and the flag must be absent. The patch reads
`oidc.token_strategy` and sets the flag conditionally:

```python
token_strategy = config_get(
    "oidc", "token_strategy", raise_exception=False, default="client_credentials"
)
if token_strategy != "exchange":
    job_params["unmanaged_tokens"] = True
```

This is paired with `AllowNonManagedTokens=True` in
`unmanaged.fts3restconfig`. The two settings must agree.

## Rucio — `core/oidc.py`

**Source:** `rucio/rucio-server` image, Python package `rucio.core.oidc`
**Upstream ref:** [rucio/rucio @ main — core/oidc.py](https://github.com/rucio/rucio/blob/master/lib/rucio/core/oidc.py)

### Changes

**1. OIDC discovery URL — string concatenation instead of `urljoin`**

Upstream constructs the discovery URL with
`urljoin(issuer, '.well-known/openid-configuration')`, which strips the
last path segment when `issuer` lacks a trailing slash — for the
Keycloak issuer `https://keycloak:8443/realms/rucio` it yields
`/realms/.well-known/openid-configuration` (HTTP 404). The patch uses
`issuer.rstrip('/') + '/.well-known/openid-configuration'`, which is
both `urljoin`-safe and trailing-slash-agnostic.

**2. `request_token` — route through `get_token_for_account_operation` for exchange**

When `oidc.token_strategy == 'exchange'` and an `account` is provided,
the patch routes through `get_token_for_account_operation`, performing
RFC 8693 token-exchange against the account's seeded subject token.
Without an account or exchange strategy the call falls through to the
upstream `client_credentials` path.

**3. `request_token` — append `aud:<audience>` scope in the `client_credentials` branch**

Keycloak's `audience` POST parameter on a `client_credentials` grant
does **not** activate an audience-mapper that lives inside an *optional*
client scope. In this testbed the per-RSE `aud:*` scopes are optional
(so managed-mode exchanged tokens can carry a single audience). To make
unmanaged-mode tokens carry the audience, the patch appends
`aud:<audience>` to the requested scope so Keycloak activates the
optional scope and runs its mapper:

```python
requested_scope = scope
if audience:
    aud_scope = f"aud:{audience}"
    if aud_scope not in requested_scope.split():
        requested_scope = f"{requested_scope} {aud_scope}".strip()
```

The cache key uses `requested_scope`, not `scope`, to avoid serving an
audience-less cached token when an audience-bearing one is requested.

**4. `__exchange_token_oidc` — caller's audience wins; guarantee `openid` scope**

Upstream's exchange used the subject token's audience by default; the
patch inverts the precedence so the caller's per-RSE audience (set in
`fts3.py`) takes priority. The patch also guarantees `openid` is in
the requested scope so exchanged tokens are accepted by OIDC
userinfo-based validators (Teapot's pre-offline-JWT auth path; not
needed once Teapot validates JWTs offline, but harmless).

**5. `save_subject_token` — wrapper to seed subject tokens with an explicit account**

A thin wrapper around the internal token-saver used by `validate_jwt`,
exposed so `init-testbed.sh` can persist subject tokens for an
explicitly-named account. `validate_jwt` resolves accounts via
`get_default_account`, which is ambiguous when one OIDC identity maps
to multiple accounts.

**6. Permanent WARNING logging on swallowed exceptions**

Two `except` blocks in the exchange path previously logged at `DEBUG`
and silently returned `None`. The patch promotes them to `WARNING` and
logs when `request_token` returns `None`, so token-acquisition failures
surface in production logs rather than vanishing.

### Realm coupling

Patch changes 3 and 4 above only work because the testbed's Keycloak
realm exposes per-RSE audience scopes (`aud:xrd3`, `aud:xrd4`,
`aud:teapot1`, `aud:teapot2`) as **optional** client scopes on the
`rucio` and `fts` clients, with `include.in.token.scope: false` on
each mapper. Switching them to default scopes would put every audience
on every token (breaks managed-mode single-audience tokens); removing
the optional declaration breaks unmanaged-mode entirely. See
`shared/config/keycloak/realm.json`.

## Replacement paths

**Candidates for upstreaming to Rucio:**

- Discovery-URL `urljoin` fix in `oidc.py` (correctness bug for issuers
  without trailing slashes; affects any non-Keycloak IdP whose issuer
  omits the slash too).
- `account` and per-RSE `audience` passthrough in `fts3.py` storage
  token requests (required for any token-exchange or
  audience-scoped-client deployment, not specific to this testbed).
- Audience-precedence inversion in `__exchange_token_oidc` (per-RSE
  audience is the more useful default than the subject token's
  audience).
- WARNING-level logging on the previously silent failure paths.

**Testbed-specific, retained by design:**

- `unmanaged_tokens` is the documented FTS mechanism for pre-fetched
  long-lived tokens; the conditional setting based on `token_strategy`
  is how Rucio is expected to integrate with both modes.
- The `aud:<audience>` scope-append in `oidc.py`'s `client_credentials`
  branch is a workaround for Keycloak's optional-scope semantics; it's
  correct behaviour for *this* realm topology, but other IdPs may not
  need it. Worth keeping behind the existing patched path rather than
  upstreaming as default.
- `save_subject_token` exists only to support the testbed's seeding
  flow; production deployments use the auth-code flow to populate
  subject tokens.

---

## Rucio — `common/constants.py`

**Source:** `rucio/rucio-server` image, Python package
`rucio.common.constants`

**Upstream ref:**
[rucio/rucio @ main — common/constants.py](https://github.com/rucio/rucio/blob/master/lib/rucio/common/constants.py)

### Changes

**1. `BASE_SCHEME_MAP` — add `https` to `root` compatible schemes and vice versa**

Upstream maps `root` only to `['root']`. The patch extends this to
`['root', 'https']` and adds `https` → `root` compatibility, enabling
XRootD → S3 (`root://` source, `https://` destination) and S3 → XRootD
(`https://` source, `root://` destination) cross-protocol transfers.
Without this, the conveyor submitter raises `MISMATCH_SCHEME` and the
request goes immediately STUCK.

```python
# Patch
"root": ["root", "https"],
"https": ["https", "http", "davs", "srm+https", "cs3s", "root"],

# Upstream
'root': ['root'],
'https': ['https', 'davs', 'srm+https', 'cs3s'],
```

**2. Formatting only** — all other diff hunks are cosmetic (Black-style
reformatting, single → double quotes). No semantic changes.

### Replacement path

The `BASE_SCHEME_MAP` change is a candidate for upstreaming or for
configuring via the Rucio `conveyor` config section once the relevant
config knob exists. Track against the Rucio issue tracker.

---

## FTS — `fts-rest-flask/middleware.py`

**Source:** `fts-rest-flask` package inside the FTS container

**Upstream ref:**
[fts/fts-rest-flask @ 3.14.x-release — middleware.py](https://gitlab.cern.ch/fts/fts-rest-flask/-/blob/3.14.x-release/src/fts3rest/fts3rest/config/middleware.py)

### Changes

**1. `load_providers` — do not normalize issuer URL with trailing slash**

Upstream adds a trailing slash to the issuer URL read from the database
(`provider_url + "/"`). Keycloak's OIDC discovery endpoint returns `iss`
claims **without** a trailing slash (e.g.
`https://keycloak:8443/realms/rucio`). When the providers dict is keyed
with a trailing slash but `get_token_issuer()` returns a bare URL, the
lookup fails and token-based auth is rejected.

The patch stores the issuer exactly as returned by the database, without
normalization, so the key matches the raw `iss` claim.

```python
# Patch — store as-is
# provider_url stored without trailing slash to match raw iss claim

# Upstream
if provider_url and not provider_url.endswith("/"):
    provider_url = provider_url + "/"
```

**2. Formatting only** — all other diff hunks are comments added upstream
or whitespace. No semantic changes.

### Replacement path

Aligning the Keycloak issuer URL to include a trailing slash is not viable —
Keycloak derives the `iss` claim directly from the realm URL and does not
expose a direct issuer override. Setting `frontendUrl` affects all Keycloak
URLs, not just the `iss` claim.

File a bug against fts-rest-flask to remove or make the trailing-slash
normalization configurable. The OIDC specification does not require a trailing
slash on issuer URLs and Keycloak omits it by convention.

---

## FTS — `fts-rest-flask/openidconnect.py`

**Source:** `fts-rest-flask` package inside the FTS container

**Upstream ref:**
[fts/fts-rest-flask @ 3.14.x-release — openidconnect.py](https://gitlab.cern.ch/fts/fts-rest-flask/-/blob/3.14.x-release/src/fts3rest/fts3rest/lib/openidconnect.py)

### Changes

**1. `get_token_issuer` — return raw `iss` claim without trailing slash**

Upstream inlines the issuer extraction and relies on the normalized
(trailing-slash) key in the providers dict. The patch extracts
`get_token_issuer()` as a separate method that returns the raw `iss`
claim from the JWT payload without modification, keeping it consistent
with the middleware.py patch above.

```python
# Patch
def get_token_issuer(self, access_token):
    unverified_payload = jwt.decode(access_token, options=jwt_options_unverified())
    issuer = unverified_payload["iss"]
    # Return issuer as-is — no trailing slash normalization
    return issuer
```

### Replacement path

Same as `middleware.py` — the two patches are complementary halves of the
same fix and must be applied or removed together.

---

## Teapot — `teapot.py`

**Source:** `teapot` package inside the Teapot container

**Upstream ref:**
[interTwin-eu/teapot @ main — teapot.py](https://github.com/interTwin-eu/teapot/blob/main/teapot.py)

### Changes

**1. `_get_proc` — match process by key parts instead of full command string**

Upstream matches a running Storm-WebDAV process by comparing the full
command string exactly. This is fragile — minor differences in whitespace,
argument ordering, or JVM version flags cause the match to fail, leaving
Teapot unable to find and manage the subprocess. The patch extracts key
identifying parts (`storm-webdav-server.jar`, `java.io.tmpdir`) and checks
that all are present in the process command line.

```python
# Patch
key_parts = [p for p in cmd.split()
             if "storm-webdav-server.jar" in p or "java.io.tmpdir" in p]
if all(part in cmdline for part in key_parts):
    return proc

# Upstream
if cmd == " ".join(proc.cmdline()):
    return proc
```

**2. `httpx.Timeout` — retain explicit timeout for aarch64 JVM cold-start**

The upstream code at the Storm-WebDAV readiness check uses the global
`httpx.AsyncClient` timeout of `connect=10.0, read=None`. The patch
replaces the per-call timeout with explicit values to bound the
readiness probe on slow aarch64 CI runners where the JVM cold-start
can take 20-40 seconds. See [run](https://github.com/RI-SCALE/dep-dlm-testbed/actions/runs/26224436098/job/77167597491) failing with:

```bash
12:01:20 INFO    conftest: === Warming up teapot1 Storm-WebDAV instance ===
12:03:17 INFO    conftest:   [1] teapot1 returned HTTP 500 — retrying in 10s
ERROR
```

```python
# Patch
resp = httpx.get(
    "https://" + config["Storm-webdav"]["SERVER_ADDRESS"] + ":" + str(port) + "/",
    verify=context1,
    timeout=httpx.Timeout(connect=5.0, read=30.0, write=5.0, pool=5.0),
)

# Upstream
resp = httpx.get(
    "https://" + config["Storm-webdav"]["SERVER_ADDRESS"] + ":" + str(port) + "/",
    verify=context1,
)
```

Observed failure on aarch64 CI without this patch: Teapot returns HTTP 500
during warm-up while the Storm-WebDAV JVM is still initialising, causing
the readiness loop to time out before the instance becomes healthy.

### Replacement path

The `_get_proc` robustness fix and the explicit `httpx.Timeout` are both
candidates for upstreaming to
[interTwin-eu/teapot](https://github.com/interTwin-eu/teapot).
The timeout value should be made configurable via `config.ini` rather than
hardcoded, to accommodate varying hardware performance.
