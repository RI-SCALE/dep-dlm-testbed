# Design-001: DLM Source/Destination Token Issuers

- **Status:** Proposed
- **Owner:** DEP DLM testbed
- **Related ADR(s):** [ADR-006: Multi-Entry AAI Credential File vs
  Static Single-AAI Config](../adrs/adr-006-multi-aai-credential-file.md)
  — resolves that ADR's Open Point on multi-binding RSEs, scoped to
  the FTS3 src/dst token-acquisition path.

## Problem

DLM transfers move between a source and destination RSE, which may
sit behind different issuers. `transfertool/fts3.py`'s FTS3
token-acquisition path already resolves `audience`/`scope` per-RSE via
`core.rse.determine_audience_for_rse`/`determine_scope_for_rse`
(called separately for source and destination), both derived purely
from each RSE's own `davs` protocol config (`get_rse_protocols`) —
already correctly per-RSE, no credential involvement.

What is not per-RSE is the credential set used to actually request the
token: `core.oidc.request_token` authenticates every call with
module-level globals (`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`,
`OIDC_PROVIDER_ENDPOINT`), loaded once for the whole Rucio instance via
`__load_oidc_configuration()`. Source and destination RSEs behind
different issuers currently share the same credentials regardless.
This is exactly the single-issuer limitation ADR-006 addresses, and
this design resolves it for FTS3's src/dst token-acquisition path
specifically.

## Goals

- FTS3's token-acquisition path resolves a distinct credential binding
  for a transfer's source RSE and destination RSE independently.
- Reuses the existing keyed `idp-secrets.json` file from ADR-006
  unchanged — no new file format.
- Extends the existing per-RSE resolution pattern
  (`determine_audience_for_rse`/`determine_scope_for_rse`) rather than
  inventing a parallel mechanism.
- Uses a generic attribute name (`issuer_binding`), not tied to "AAI"
  specifically, consistent with how `oidc_*` RSE attributes are
  already named in Rucio (`common/constants.py`).

## Non-goals

- General N-binding-per-RSE representation — still open in ADR-006.
- JSON-valued RSE attributes, or moving bindings into RSE protocol
  definitions — both remain open alternatives in ADR-006; this design
  picks the narrowest option sufficient for src/dst only.
- Secrets-manager migration — unchanged from ADR-006's Rejected
  Alternative.
- Changing `determine_audience_for_rse`/`determine_scope_for_rse` —
  confirmed already correctly per-RSE, out of scope.
- Token refresh/caching mechanics inside `request_token` — only which
  credential set it authenticates with.

## Design

Two named RSE attributes, both resolving into `idp-secrets.json`:

- `issuer_binding_src` — binding key for the source RSE
- `issuer_binding_dst` — binding key for the destination RSE

Resolution order per role:
1. `issuer_binding_{role}` if set
2. else `issuer_binding` (single-binding fallback, avoids re-tagging
   every existing single-issuer RSE)
3. else resolution fails — see Fallback

`core.oidc.request_token` gains a `binding` parameter (the resolved
`idp-secrets.json` entry — `client_id`/`client_secret`/provider
endpoint) instead of reading `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/
`OIDC_PROVIDER_ENDPOINT` from module globals. `transfertool/fts3.py`'s
FTS3 token-acquisition block resolves `issuer_binding_src`/
`issuer_binding_dst` for the source and destination RSE respectively,
alongside its existing `determine_audience_for_rse`/
`determine_scope_for_rse` calls, and passes the resolved binding into
`request_token`.

Following the `OIDC_BASE_PATH`/`OIDC_SUPPORT` naming pattern, the three
keys (`issuer_binding`, `issuer_binding_src`, `issuer_binding_dst`)
should be defined as named constants in `common/constants.py`.
Registering them into the `RSE_ATTRS_STR` literal type is optional
polish, not required — confirmed `get_rse_attribute`'s typed overloads
are static-typing sugar only; the single real implementation does an
untyped `key: str` lookup with no runtime difference for unregistered
keys.

## Touch points

| File / component | Change |
|---|---|
| `common/constants.py` | Add `ISSUER_BINDING`, `ISSUER_BINDING_SRC`, `ISSUER_BINDING_DST` constants, following `OIDC_BASE_PATH`/`OIDC_SUPPORT` |
| `core/oidc.py` (`request_token`) | Accept a resolved credential binding parameter instead of reading `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/`OIDC_PROVIDER_ENDPOINT` module globals |
| `transfertool/fts3.py` (FTS3 token-acquisition block) | Resolve `issuer_binding_src`/`issuer_binding_dst` alongside existing `determine_audience_for_rse`/`determine_scope_for_rse` calls; pass into `request_token` |
| `core/rse.py` (`RSE_ATTRS_STR`) | Optionally register the three new keys for typed `get_rse_attribute` lookups — non-blocking |
| RSE attribute documentation | Document `issuer_binding[_src\|_dst]` as the generic ADR-006 convention |
| `idp-secrets.json` | No format or content change |

## Fallback / safety behavior

- No binding resolves for a role → transfer fails fast with an
  explicit error naming the RSE and role, not a silent default to the
  current global `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`.
- Binding key set but missing from `idp-secrets.json` → same fail-fast
  behavior, no fallback to another entry.
- Existing single-issuer deployments using only the current global
  `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/`OIDC_PROVIDER_ENDPOINT`
  config (no `issuer_binding` set on any RSE) continue to work
  unchanged — `request_token` should treat an unresolved binding as
  "use the existing global config" only for backward compatibility
  during rollout, not as a long-term silent fallback (see Open
  questions).

## Testing

- Unit: resolution order (role-specific → fallback → fail) for all
  three cases; `request_token`'s new `binding` parameter overriding
  the module globals correctly.
- Integration: a transfer between two RSEs with different
  `issuer_binding_src`/`issuer_binding_dst` values successfully
  acquires two distinct tokens from two different providers.
- Regression: existing deployments relying on global
  `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET` (no RSE bindings set) continue
  transferring without reconfiguration.

## Sequencing

1. Add constants to `common/constants.py`.
2. Extend `request_token` to accept an optional `binding` parameter,
   falling back to existing module globals when absent — keeps this
   change backward-compatible before any RSE is tagged.
3. Implement `issuer_binding_src`/`issuer_binding_dst`/`issuer_binding`
   resolution in `transfertool/fts3.py`'s FTS3 token block.
4. Document the attribute convention.
5. Tag RSE pairs needing distinct src/dst issuers in the testbed.
6. Note resolution back in ADR-006's Open Points as resolved for this
   case.

## Open questions

- Should `request_token`'s module-global fallback (step 2 above) be
  permanent, or should it eventually be removed so every deployment is
  forced to declare bindings explicitly? Affects long-term
  maintainability vs. rollout friction.
- Does this convention need to be adopted by any other component
  reading RSE attributes besides FTS3's token path, or is it scoped
  there only for now?
- If a future RSE needs more than one binding for a reason other than
  src/dst (e.g. multiple protocols per RSE), does that reopen ADR-006's
  general N-binding question, or is src/dst assumed to remain the only
  multi-binding case in practice?
- Confirm whether `request_token`'s existing MD5-keyed cache
  (`audience`+`scope`) needs the binding/client_id folded into the
  cache key too — otherwise two different credential bindings
  requesting the same audience/scope could incorrectly share a cached
  token.
