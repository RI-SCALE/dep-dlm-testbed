# Design-001: Per-Issuer OIDC Capability Profiles

- **Status:** Proposed
- **Owner:** DEP DLM testbed / Rucio patches
- **Related:** backlog item "Integrate testbed against LS AAI (Perun)"

## Problem

`oidc.py`, `rse.py`, and `fts3.py` each branch on a single global config value,
`[oidc] scope_profile`, comparing it against the literal string `"egi"` to decide
whether to send RFC 8707 `resource=` or plain `audience=`, how to map scope
names, and whether to drop `offline_access`. This appears independently in six
places across three files:

- `oidc.py`: `request_token()`, `__get_admin_token_oidc()`, `__exchange_token_oidc()`
- `rse.py`: `determine_audience_for_rse()`, `determine_scope_for_rse()` / `_EGI_SCOPE_MAP`
- `fts3.py`: `FTS3Transfertool.__init__()` (FTS's own token-request scope)

`init-testbed.sh` duplicates the same decision in bash, but inconsistently —
some checks use `[ "$SCOPE_PROFILE" != "local" ]`, others `[ "$SCOPE_PROFILE" =
"egi-dev" ]`. These currently agree only because there is exactly one non-local
profile today.

Two further problems, confirmed against the current EGI Check-In deployment:

1. **The switch is one-dimensional (issuer only), but EGI's own constraints are
   two-dimensional (issuer × grant type).** Runbook 2 documents, with a
   reproducible script, that EGI honors `resource=` on `client_credentials` but
   **not** on `token-exchange` — confirmed by decoding the exchanged token and
   observing no `aud` claim. The current code cannot express "resource= on this
   grant, audience= on that grant" for the same issuer; the operational
   workaround is a deployment-wide choice (`token_strategy=client_credentials`
   instead of `exchange`).
2. **Naming drift between layers.** `SCOPE_PROFILE=egi-dev` (Makefile/CI/Helm,
   a directory selector) and `scope_profile=egi` (the literal value read at
   runtime from `rucio.cfg`) are two different vocabularies for the same
   deployment, kept in sync by hand. This works today by luck (one non-local
   profile); it will not survive a second one without a shared join key.

LS AAI / Perun (RT #1538309) is a pending second external IdP. Its actual
constraints — self-service registration, `resource=` support per grant type —
are unknown; the ticket has received only an autoreply.

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

- Guessing LS AAI's capabilities. Until #1538309 answers Marvin's three
  questions (which instance, self-service or not, `resource=` per grant type),
  no LS AAI-specific values are added. Unknown issuers fall back to today's
  default (WLCG) behavior.
- Changing `token_strategy` semantics or the exchange-vs-client_credentials
  choice itself.

## Design

Extend the existing per-issuer `idpsecrets.json` — already loaded by both
`__get_rucio_oidc_clients()` in Python and (trivially, via `jq`) by
`init-testbed.sh` — with an optional `capabilities` block per issuer entry.
No second config file.

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
      "grant_mode": "client_credentials",
      "client_credentials":       { "resource_param": true,  "audience_param": false },
      "admin_client_credentials": { "resource_param": true,  "audience_param": false },
      "token_exchange":           { "resource_param": false, "audience_param": true  },
      "scope_map":   { "storage.read": "read:/", "storage.modify": "write:/", "storage.create": "write:/" },
      "drop_scopes": ["offline_access"]
    }
  }
}
```

**Absent `capabilities` block → today's WLCG default**
(`resource_param: false, audience_param: true` on every grant, no scope
remapping, nothing dropped). Every existing non-EGI deployment needs no change
to this file.

**Resolution is by issuer, not by a profile name.** Both Python and bash read
the same key:

```python
def get_capabilities(issuer: str, grant: str) -> GrantCapabilities:
    entry = _idpsecrets().get(issuer, {})
    caps = entry.get("capabilities", {})
    grant_caps = caps.get(grant, DEFAULT_GRANT_CAPABILITIES)
    return GrantCapabilities(**grant_caps)
```

```bash
grant_mode=$(jq -r --arg iss "$OIDC_ISSUER" \
  '.[$iss].capabilities.grant_mode // "password"' "$IDPSECRETS")
```

## Touch points

| File | Change |
|---|---|
| `oidc.py` | Six `if scope_profile == "egi"` branches → one `get_capabilities(issuer, grant)` call each |
| `rse.py` | `determine_audience_for_rse` / `determine_scope_for_rse` take capabilities for the RSE's configured issuer instead of `_scope_profile() == "egi"` |
| `fts3.py` | `FTS3Transfertool.__init__` looks up capabilities for the FTS-configured issuer |
| `rucio.cfg` | Remove `[oidc] scope_profile` — no longer read anywhere |
| `idpsecrets.json` (per profile dir) | Add `capabilities` block to the `egi-dev` entry; other profiles unchanged |
| `init-testbed.sh` | Replace `$SCOPE_PROFILE` string checks (`!= "local"`, `= "egi-dev"`) with `jq` lookups against `$IDPSECRETS`/`$OIDC_ISSUER` |
| Makefile / CI matrix | `SCOPE_PROFILE` / `CONFIG_PROFILE_DIR` unchanged — remains a legitimate directory selector for which config bundle to render; stops being a second source of runtime truth |

## Fallback / safety behavior

- Unknown issuer, or `idpsecrets.json` unreadable: default to WLCG capabilities
  (`resource_param: false, audience_param: true`). Never default to
  `resource_param: true` for an unconfirmed IdP — sending an unsupported
  parameter is the exact failure mode the EGI repro script demonstrated for
  the inverse case.
- Missing `capabilities` key on an existing entry: same default. No entry
  needs to be touched to keep working.

## Testing

- Unit tests against `GrantCapabilities`/`get_capabilities` with fixture
  `idpsecrets.json` content — no network required.
- Regression test asserting EGI's profile: `client_credentials.resource_param
  is True` and `token_exchange.resource_param is False`, pinned to the runbook
  2 repro finding.
- `egi-dev` CI job becomes the live regression test that refactor did not
  change observed behavior (it already exercises the real branch, confirmed
  by inspecting the rendered `rucio.cfg`).

## Sequencing

1. Land the capability-lookup refactor now, populated with only `wlcg`
   (implicit default) and `egi` (from runbook 2's confirmed constraints).
2. Remove `scope_profile` from `rucio.cfg` and the six literal-string
   branches.
3. Update `init-testbed.sh` to the `jq`-based lookup.
4. Track "add LS AAI capabilities entry" as a separate, follow-up ticket,
   blocked on RT #1538309 actually answering:
   - which instance (`perun-dev` vs `proxy-dev`),
   - self-service or CERN-mediated client registration,
   - `resource=` support per grant type (client_credentials, token-exchange,
     admin).

## Open questions

- Does `resource_param`/`audience_param` need a third state (e.g. "send both")
  for some future IdP, or is the boolean pair sufficient? No evidence yet
  requires more than two independent booleans.
- Should `capabilities` eventually be validated with a schema (e.g. at
  `idpsecrets.json` load time) to fail fast on typos rather than silently
  falling back to defaults? Worth revisiting once a second real profile
  (LS AAI) exists to validate the schema against.
