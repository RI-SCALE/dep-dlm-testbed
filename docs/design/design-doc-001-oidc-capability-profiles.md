# Design-001: Per-Issuer OIDC Capability Profiles

- **Status:** Implemented
- **Owner:** DEP DLM testbed / Rucio patches
- **Related:** backlog item "Integrate testbed against LS AAI (Perun)"
- **Related ADR:** [ADR-002: Store Per-Issuer OIDC Grant Capabilities in idpsecrets.json](../adrs/adr-002-store-oidc-capabilities-in-idpsecrets.md)

## Problem

`oidc.py`, `rse.py`, and `fts3.py` each branch on a single global config value,
`[oidc] scope_profile`, comparing it against the literal string `"egi"` to decide
whether to send RFC 8707 `resource=` or plain `audience=`, how to map scope
names, and whether to drop `offline_access`. This appeared independently in six
places across three files:

- `oidc.py`: `request_token()`, `__get_admin_token_oidc()`, `__exchange_token_oidc()`
- `rse.py`: `determine_audience_for_rse()`, `determine_scope_for_rse()` / `_EGI_SCOPE_MAP`
- `fts3.py`: `FTS3Transfertool.__init__()` (FTS's own token-request scope)

`init-testbed.sh` duplicated the same decision in bash, but inconsistently —
some checks used `[ "$SCOPE_PROFILE" != "local" ]`, others `[ "$SCOPE_PROFILE" =
"egi-dev" ]`. These agreed only because there was exactly one non-local
profile.

Two further problems, confirmed against the EGI Check-In deployment:

1. **The switch was one-dimensional (issuer only), but EGI's own constraints are
   two-dimensional (issuer × grant type).** Runbook 2 documents, with a
   reproducible script, that EGI honors `resource=` on `client_credentials` but
   **not** on `token-exchange` — confirmed by decoding the exchanged token and
   observing no `aud` claim. The old code could not express "resource= on this
   grant, audience= on that grant" for the same issuer; the operational
   workaround was a deployment-wide choice (`token_strategy=client_credentials`
   instead of `exchange`).
2. **Naming drift between layers.** `SCOPE_PROFILE=egi-dev` (Makefile/CI/Helm,
   a directory selector) and `scope_profile=egi` (the literal value read at
   runtime from `rucio.cfg`) were two different vocabularies for the same
   deployment, kept in sync by hand.

LS AAI / Perun (RT #1538309) is a pending second external IdP. Its actual
constraints — self-service registration, `resource=` support per grant type —
remain unknown; the ticket has received only an autoreply. No LS AAI-specific
capability values are added by this change.

## Goals

- Replace the binary `scope_profile` switch with a structure that varies by
  **issuer** and by **grant type**, matching the granularity EGI has already
  demonstrated it needs.
- Single join key across Python and bash: the issuer URL, not a free-text
  profile name.
- No behavior change for existing WLCG or EGI deployments.
- No new config file.
- Onboarding a new IdP (once its constraints are confirmed) is a data change,
  not a code change.

## Non-goals

- Guessing LS AAI's capabilities. Until #1538309 answers the open questions
  (which instance, self-service or not, `resource=` per grant type), no LS
  AAI-specific values are added. Unknown issuers fall back to the WLCG
  default behavior.
- Changing `token_strategy` semantics or the exchange-vs-client_credentials
  choice itself. `token_strategy` decides which grant flow Rucio uses for a
  transfer at all; it is a deployment-wide operational choice, orthogonal to
  the capability model here. It remains a single global value today; making
  it per-issuer (mirroring what `scope_profile` needed) is a separate,
  future design if a future IdP needs it.
- Storing data in `idpsecrets.json` that only `init-testbed.sh` consumes.
  `capabilities` is scoped strictly to fields `get_capabilities()` in Python
  actually reads (see below) — the script's own bootstrapping decisions
  (e.g. which OAuth grant it uses to seed test identities) are kept out of
  this file and resolved separately, even where they correlate with an
  issuer's capabilities.

## Design

Extends the existing per-issuer `idpsecrets.json` — already loaded by
`__get_rucio_oidc_clients()` in Python — with an optional `capabilities`
block per issuer entry. No second config file. See ADR-002 for why this
location was chosen over a standalone profiles file.

```json
{
  "https://aai-dev.egi.eu/auth/realms/egi": {
    "issuer": "https://aai-dev.egi.eu/auth/realms/egi",
    "client_id": "<valid client id>",
    "client_secret": "<valid client secret>",
    "redirect_uris": ["..."],
    "audience": "rucio",
    "scope": "openid profile eduperson_entitlement offline_access read:/ write:/",
    "SCIM": { "client_id": "...", "client_secret": "..." },

    "capabilities": {
      "client_credentials":       { "resource_param": true,  "audience_param": false },
      "admin_client_credentials": { "resource_param": true,  "audience_param": false },
      "token_exchange":           { "resource_param": false, "audience_param": true  },
      "scope_map":   { "storage.read": "read:/", "storage.modify": "write:/", "storage.create": "write:/" },
      "drop_scopes": ["offline_access"]
    }
  }
}
```

Every field under `capabilities` has a Python consumer via `get_capabilities()`
(`oidc.py`, `rse.py`, `fts3.py`). Nothing here is present solely for
`init-testbed.sh`'s benefit — see the touch-points section below for the one
field (the init script's own bootstrapping grant) that was deliberately kept
*out* of this file for exactly that reason.

FTS's own `client_credentials` scope (used when FTS itself authenticates to
Rucio) is derived from `scope_map` rather than a dedicated field —
`fts3.py` computes `" ".join(sorted(scope_map.values()))`, falling back to
the WLCG literal `"fts"` when `scope_map` is empty. This was initially
designed as a separate `fts_service_scope` field, since FTS's own scope is
conceptually distinct from `scope_map`'s job of translating RSE
storage-scope names (`storage.read`, `storage.modify`, ...) for per-transfer
source/destination tokens — but since both resolve to the same string for
EGI today (`"read:/ write:/"`), the dedicated field was dropped as
unnecessary duplication. If a future IdP needs FTS's own scope to diverge
from its RSE scope-mapping, reintroducing a dedicated field is the fix at
that point, not before.

The `capabilities` key is unprefixed, matching the naming of sibling keys
already present in the file (`audience`, `scope`, `SCIM`) that are similarly
not part of the OIDC dynamic client registration schema `oic`'s
`RegistrationResponse` expects. `__get_rucio_oidc_clients()` explicitly
filters `capabilities` out before constructing `RegistrationResponse(**...)`,
so its presence never risks interfering with client registration regardless
of how tolerant the underlying `oic` library is of unknown kwargs.

**Absent `capabilities` block → WLCG default**
(`resource_param: false, audience_param: true` on every grant, no scope
remapping, nothing dropped — FTS's own scope falls back to `"fts"` since
`scope_map` is empty). Every non-EGI deployment needs no change to this
file.

**Resolution is by issuer, not by a profile name.**

```python
def get_capabilities(issuer: str, grant: str) -> GrantCapabilities:
    entry = _idpsecrets().get(issuer, {})
    caps = entry.get("capabilities", {})
    grant_caps = caps.get(grant, DEFAULT_GRANT_CAPABILITIES)
    return GrantCapabilities(**grant_caps)
```

Bash reads the same file via an inline `python3 -c` helper (`_cap()` in
`init-testbed.sh`), matching the script's existing convention for JSON
handling elsewhere (e.g. `seed_subject_tokens`) rather than introducing a new
`jq` dependency on the `rucio-server` image:

```bash
_cap() {
    local path="$1" default="$2"
    _exec rucio-server env \
        CAP_ISSUER="$OIDC_ISSUER" CAP_PATH="$path" CAP_DEFAULT="$default" \
        CAP_FILE="$IDPSECRETS_PATH_IN_CONTAINER" \
        python3 -c "
import json, os
try:
    with open(os.environ['CAP_FILE']) as f:
        data = json.load(f)
    val = data.get(os.environ['CAP_ISSUER'], {}).get('capabilities', {})
    for part in os.environ['CAP_PATH'].split('.'):
        val = val[part]
    print(str(val).lower())
except Exception:
    print(os.environ['CAP_DEFAULT'])
"
}
```

(`str(val).lower()` normalizes JSON booleans to bash-comparable `"true"`/
`"false"`, since Python's default `print(bool)` renders `"True"`/`"False"`.)

`_cap()` is scoped to fields that also have a Python consumer — currently
`client_credentials.resource_param`, used to shape the RSE `audience`
attribute the same way `oidc.py`'s `_is_uri_audience()` gate does. The OAuth
grant `init-testbed.sh` uses for its *own* bootstrapping requests
(`grant_mode`: `password` vs. `client_credentials`) is resolved by a
separate helper, `_grant_mode_for_profile()`, keyed directly on
`$SCOPE_PROFILE` rather than read from `idpsecrets.json` — see touch points
below.

`IDPSECRETS_PATH_IN_CONTAINER` is a fixed path
(`/opt/rucio/etc/idpsecrets.json`), not derived from `$SCOPE_PROFILE`.
`SCOPE_PROFILE` already does its job earlier, at deploy time, selecting
*which* `idpsecrets.json` content gets rendered/mounted at that fixed path;
by the time `init-testbed.sh` runs, `_cap()`'s resolution happens purely by
`$OIDC_ISSUER` against whatever is already mounted. This keeps the issuer URL
as the single join key for every capability `_cap()` reads, with no
dependency on `$SCOPE_PROFILE` being in sync with the mounted file's content.

## Touch points

| File | Change |
|---|---|
| `oidc.py` | Six `if scope_profile == "egi"` branches → one `get_capabilities(issuer, grant)` call each |
| `rse.py` | `determine_audience_for_rse` / `determine_scope_for_rse` take capabilities for `ADMIN_ISSUER_ID` instead of `_scope_profile() == "egi"`; `_EGI_SCOPE_MAP` removed in favor of `capabilities.scope_map` |
| `fts3.py` | `FTS3Transfertool.__init__` looks up capabilities for `ADMIN_ISSUER_ID`, deriving FTS's own client_credentials scope from `scope_map.values()` (falling back to `"fts"`) instead of a hardcoded `"read:/ write:/"` literal |
| `rucio.cfg` | `[oidc] scope_profile` removed — no longer read anywhere |
| `idpsecrets.json` (per profile dir) | `capabilities` block added to both the `local`/Keycloak entries and the `egi-dev` entry; contains only Python-consumed fields (no `grant_mode` — see below) |
| `init-testbed.sh` | See below — capability-shaped decisions with a Python consumer migrated to `_cap()`; the script's own bootstrapping-grant decision moved to a dedicated `_grant_mode_for_profile()` helper instead; profile-scoped infrastructure/test wiring left on raw `$SCOPE_PROFILE` |
| Makefile / CI matrix | `SCOPE_PROFILE` / `CONFIG_PROFILE_DIR` unchanged — remains the directory selector for which config bundle to render; no longer a second source of *runtime* capability truth for the fields Python actually reads |

### `init-testbed.sh`: three categories of `$SCOPE_PROFILE`-driven decision

Not every `$SCOPE_PROFILE` check in this script was a capability decision in
disguise, and not every capability-shaped decision has a Python consumer.
Three distinct cases ended up handled three different ways:

**1. Migrated to `_cap()` / `idpsecrets.json`** (has a Python consumer too):

- `configure_rses()` (×2, XRD and TEAPOT loops) — URI-vs-bare-hostname shape
  for the `audience` RSE attribute, via `_cap
  "client_credentials.resource_param" "false"`, mirroring the same boolean
  `_is_uri_audience()` gate in `oidc.py`.

**2. Resolved via `_grant_mode_for_profile()`, keyed on `$SCOPE_PROFILE`
directly** (no Python consumer — deliberately kept out of `idpsecrets.json`):

- `setup_accounts_and_identities()` — whether the password grant is
  available at all for identity registration.
- `seed_subject_tokens()` — which grant (`client_credentials` vs.
  `password`) the seeding script uses to mint the initial subject token.
- `verify_token_exchange()`'s self-test skip — whether the password-grant
  self-test mint against `randomaccount`/`secret` is meaningful for this
  profile.

  These three all describe the *init script's own* bootstrapping behavior,
  not a fact `get_capabilities()` or any Rucio Python code needs at runtime.
  Storing it in `idpsecrets.json` would put non-Python-consumed data in a
  file whose contents `get_capabilities()` is otherwise a complete
  description of — `_grant_mode_for_profile()` keeps that file's scope
  exact, at the cost of one more `$SCOPE_PROFILE`-keyed helper.

**3. Left on raw `$SCOPE_PROFILE` checks** (not capability data at all):

- `setup_fts_oidc_provider()` — decides *which OIDC client FTS itself
  authenticates as* (its own local Keycloak `fts`/`fts-secret` credential vs.
  reusing the EGI client Rucio uses) and which `t_token_provider` rows to
  seed. This is FTS's credential topology, not a per-request parameter shape
  or a grant-mode choice — it doesn't belong in `GrantCapabilities` or in
  `_grant_mode_for_profile()`, and coupling it to either would make an
  unrelated fact silently ride along with something that could vary
  independently for a future IdP.

## Fallback / safety behavior

- Unknown issuer, or `idpsecrets.json` unreadable: default to WLCG
  capabilities (`resource_param: false, audience_param: true`, empty
  `scope_map` so FTS's own scope falls back to `"fts"`). Never default to
  `resource_param: true` for an unconfirmed IdP — sending an unsupported
  parameter is the exact failure mode the EGI repro script demonstrated for
  the inverse case.
- Missing `capabilities` key on an existing entry: same default. No existing
  entry needs to be touched to keep working.
- `_cap()` in bash follows the identical fallback contract: any failure to
  read the file, find the issuer, or find the field falls through to the
  caller-supplied default rather than raising.
- `_grant_mode_for_profile()` defaults to `"password"` for any
  `$SCOPE_PROFILE` value it doesn't explicitly recognize (currently only
  `egi-dev` maps to `"client_credentials"`), matching `_cap()`'s
  fail-to-default behavior for the same field before this change.

## Testing

- Unit tests against `GrantCapabilities`/`get_capabilities` with fixture
  `idpsecrets.json` content — no network required.
- Regression test asserting EGI's profile: `client_credentials.resource_param
  is True` and `token_exchange.resource_param is False`, pinned to the
  runbook 2 repro finding.
- `egi-dev` CI job serves as the live regression test that the refactor did
  not change observed behavior.

## Sequencing

1. ~~Land the capability-lookup refactor, populated with only `wlcg`
   (implicit default) and `egi` (from runbook 2's confirmed constraints).~~
   Done.
2. ~~Remove `scope_profile` from `rucio.cfg` and the six literal-string
   branches.~~ Done.
3. ~~Update `init-testbed.sh` to the capability-lookup helper, migrating only
   the checks that were genuinely capability-shaped.~~ Done.
4. ~~Remove `grant_mode` from `idpsecrets.json` and resolve it via a
   dedicated `_grant_mode_for_profile()` helper instead, since it has no
   Python consumer and doesn't belong in a file scoped to
   `get_capabilities()`-read data.~~ Done.
5. Track "add LS AAI capabilities entry" as a separate, follow-up ticket,
   blocked on RT #1538309 actually answering:
   - which instance (`perun-dev` vs `proxy-dev`),
   - self-service or CERN-mediated client registration,
   - `resource=` support per grant type (client_credentials, token-exchange,
     admin).

## Open questions

- Does `resource_param`/`audience_param` need a third state (e.g. "send
  both") for some future IdP, or is the boolean pair sufficient? No evidence
  yet requires more than two independent booleans.
- Should `capabilities` eventually be validated with a schema (e.g. at
  `idpsecrets.json` load time) to fail fast on typos rather than silently
  falling back to defaults? Worth revisiting once a second real profile (LS
  AAI) exists to validate the schema against.
- Should `token_strategy` become per-issuer, matching what `scope_profile`
  needed? No evidence yet — EGI's current workaround
  (`token_strategy=client_credentials` deployment-wide) is sufficient until a
  second IdP's constraints are known.
