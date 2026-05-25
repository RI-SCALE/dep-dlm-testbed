# Patches

Minimal patches applied to upstream components to make OIDC-only token-based
transfers work in the testbed. X.509/GSI is explicitly out of scope.
Each patch is applied by bind-mounting the patched file over the original
inside the container (Compose) or via a ConfigMap volume mount (Kubernetes).

---

## Rucio — `transfertool/fts3.py`

**Source:** `rucio/rucio-server` image, Python package
`rucio.transfertool.fts3`

**Upstream ref:**
[rucio/rucio @ main — transfertool/fts3.py](https://github.com/rucio/rucio/blob/master/lib/rucio/transfertool/fts3.py)

### Changes

**1. `_TOKEN_CAPABLE_SCHEMES` — accept `http://` and `https://` in addition to `davs://`**

Upstream `_use_tokens()` only attaches `source_tokens` / `destination_tokens`
to FTS file submissions when the endpoint scheme is `davs`. Teapot's
Storm-WebDAV instance is reachable via `http://` (CANL bypass for
self-signed cert trust). Without this patch, `_use_tokens` returns `False`
for `http://` sources, no per-file tokens are set in `t_file`, and FTS falls
back to presenting the X.509 host cert during TLS handshake — which
Storm-WebDAV rejects with `ssl/tls alert certificate_unknown`. With the patch,
`source_tokens` and `destination_tokens` are populated for `http://`,
`https://`, and `davs://` schemes.

```python
# Patch
_TOKEN_CAPABLE_SCHEMES = frozenset({"davs", "https", "http"})

# Upstream
# endpoint.scheme != 'davs'
```

**2. `job_params` — add `unmanaged_tokens: True`**

Required for FTS to accept pre-fetched bearer tokens supplied by Rucio
rather than managing token exchange itself. Without this flag, FTS ignores
the `source_tokens`/`destination_tokens` fields.

```python
job_params = {
    ...
    "unmanaged_tokens": True,  # patch — not in upstream
}
```

**3. `determine_scope_for_rse` — add `openid` to `extra_scopes`**

Upstream passes `extra_scopes=['offline_access']`; the patch adds `openid`
so the token exchange with Keycloak returns a proper OIDC token with the
`openid` claim, which is required by the testbed's Keycloak realm
configuration.

```python
# Patch
extra_scopes=["offline_access", "openid"]

# Upstream
extra_scopes=['offline_access']
```

### Replacement path

`extra_scopes` (`openid`) is a candidate for upstreaming to Rucio. `_TOKEN_CAPABLE_SCHEMES` should be replaced by configuring Teapot/Storm-WebDAV to serve on `davs://` (TLS) rather than `http://`. `unmanaged_tokens` correctly implements the intended architecture and should remain for the testbed.

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
