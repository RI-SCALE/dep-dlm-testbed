# Design-003: DLM Source/Destination Token Resolution

- **Status:** Proposed
- **Owner:** DEP DLM testbed
- **Related ADR(s):** [ADR-006: Multi-Entry AAI Credential File vs
  Static Single-AAI Config](../adrs/adr-006-multi-aai-credential-file.md)
  — implements the single `issuer_binding` RSE attribute for FTS3's
  per-transfer token-acquisition path. Does not touch ADR-006's open
  point on multi-binding RSEs, which doesn't apply here: each RSE
  needs exactly one issuer binding, resolved twice per transfer (once
  for the source RSE, once for the destination RSE), not two bindings
  on one RSE.

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
This is exactly the single-issuer limitation ADR-006 addresses.

Which issuer an RSE trusts is a property of the RSE itself, not of the
role (source or destination) it plays in a given transfer — so this
only needs ADR-006's single `issuer_binding` attribute, looked up once
per RSE involved in the transfer, not a src/dst-specific attribute
pair.

## Goals

- FTS3's token-acquisition path resolves each RSE's own credential
  binding, independently for the source RSE and destination RSE of a
  transfer.
- Reuses the existing keyed `idp-secrets.json` file and
  `issuer_binding` attribute from ADR-006 unchanged — no new attribute,
  no new file format.
- Extends the existing per-RSE resolution pattern
  (`determine_audience_for_rse`/`determine_scope_for_rse`) rather than
  inventing a parallel mechanism.

## Non-goals

- Multi-binding-per-RSE representation — not needed here; each RSE has
  exactly one `issuer_binding`. ADR-006's open point on that topic is
  unaffected by this design.
- JSON-valued RSE attributes, or moving bindings into RSE protocol
  definitions — not needed for this single-binding case.
- Secrets-manager migration — unchanged from ADR-006's Rejected
  Alternative.
- Changing `determine_audience_for_rse`/`determine_scope_for_rse` —
  confirmed already correctly per-RSE, out of scope.
- Token refresh/caching mechanics inside `request_token` — only which
  credential set it authenticates with.

## Design

Reuse ADR-006's single `issuer_binding` RSE attribute as-is. FTS3's
token-acquisition block resolves it twice per transfer — once for the
source RSE, once for the destination RSE — using their respective
`rse_id`s:

1. `issuer_binding` set on the RSE → resolve into `idp-secrets.json`
2. else resolution fails — see Fallback

`core.oidc.request_token` gains a `binding` parameter (the resolved
`idp-secrets.json` entry — `client_id`/`client_secret`/provider
endpoint) instead of reading `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/
`OIDC_PROVIDER_ENDPOINT` from module globals. `transfertool/fts3.py`'s
FTS3 token-acquisition block resolves `issuer_binding` for
`source.rse.id` and separately for `transfer.dst.rse.id`, alongside
its existing `determine_audience_for_rse`/`determine_scope_for_rse`
calls, and passes each resolved binding into its respective
`request_token` call.

`ISSUER_BINDING` should be defined as a named constant in
`common/constants.py`, following the `OIDC_BASE_PATH`/`OIDC_SUPPORT`
pattern. Registering it into the `RSE_ATTRS_STR` literal type is
optional polish, not required — confirmed `get_rse_attribute`'s typed
overloads are static-typing sugar only; the single real implementation
does an untyped `key: str` lookup with no runtime difference for
unregistered keys.

## Touch points

| File / component | Change |
|---|---|
| `common/constants.py` | Add `ISSUER_BINDING` constant, following `OIDC_BASE_PATH`/`OIDC_SUPPORT` |
| `core/oidc.py` (`request_token`) | Accept a resolved credential binding parameter instead of reading `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/`OIDC_PROVIDER_ENDPOINT` module globals |
| `transfertool/fts3.py` (FTS3 token-acquisition block) | Resolve `issuer_binding` separately for `source.rse.id` and `transfer.dst.rse.id`, alongside existing `determine_audience_for_rse`/`determine_scope_for_rse` calls; pass each into its `request_token` call |
| `core/rse.py` (`RSE_ATTRS_STR`) | Optionally register `ISSUER_BINDING` for typed `get_rse_attribute` lookups — non-blocking |
| RSE attribute documentation | Document `issuer_binding` as ADR-006's convention, resolved once per RSE regardless of transfer role |
| `idp-secrets.json` | No format or content change |

## Fallback / safety behavior

- `issuer_binding` unset on an RSE involved in the transfer → transfer
  fails fast with an explicit error naming the RSE, not a silent
  default to the current global `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`.
- `issuer_binding` set but the key doesn't exist in `idp-secrets.json`
  → same fail-fast behavior, no fallback to another entry.
- Existing single-issuer deployments using only the current global
  `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/`OIDC_PROVIDER_ENDPOINT`
  config (no `issuer_binding` set on any RSE) continue to work
  unchanged — `request_token` should treat an unresolved binding as
  "use the existing global config" only for backward compatibility
  during rollout, not as a long-term silent fallback (see Open
  questions).

## Testing

- Unit: resolution (bound → resolved entry; unbound → fail) for a
  single RSE.
- Integration: a transfer between two RSEs with different
  `issuer_binding` values successfully acquires two distinct tokens
  from two different providers.
- Regression: existing deployments relying on global
  `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET` (no RSE bindings set) continue
  transferring without reconfiguration.

## Sequencing

1. Add `ISSUER_BINDING` constant to `common/constants.py`.
2. Extend `request_token` to accept an optional `binding` parameter,
   falling back to existing module globals when absent — keeps this
   change backward-compatible before any RSE is tagged.
3. Implement `issuer_binding` resolution in `transfertool/fts3.py`'s
   FTS3 token block, called once per RSE (source and destination).
4. Document the attribute convention.
5. Tag RSEs needing a non-default issuer in the testbed.

## Open questions

- Should `request_token`'s module-global fallback (step 2 above) be
  permanent, or should it eventually be removed so every deployment is
  forced to declare bindings explicitly? Affects long-term
  maintainability vs. rollout friction.
- Does this convention need to be adopted by any other component
  reading RSE attributes besides FTS3's token path, or is it scoped
  there only for now?
- Confirm whether `request_token`'s existing MD5-keyed cache
  (`audience`+`scope`) needs the binding/client_id folded into the
  cache key too — otherwise two different credential bindings
  requesting the same audience/scope could incorrectly share a cached
  token.
- **User-delegated token exchange is out of scope for this design and has a real, unresolved dependency, not just  a resolution-shape question.** If conveyor's service-account-only assumption
  (ADR-006's NOTE) is ever revisited, cross-issuer exchange between a
  transfer's source and destination RSE only works if those two
  issuers already trust each other — either directly, via federation
  (e.g. EGI Check-in / WLCG IAM), or indirectly, via a mediating Security
  Token Service (STS) that both issuers separately trust and that
  translates a token from issuer A into one issuer B accepts. Token
  exchange does not manufacture trust between unrelated issuers on its
  own. Confirming whether the target issuers are federated, or whether
  a mediating STS would need to be introduced, is a question for the
  AAI/IAM operators (see ADR-006's `consulted`), not something this
  design or Rucio's code can resolve. An STS is new infrastructure —
  same category ADR-006 already declined to add (see its Rejected
  Alternative) — so it should only be pursued if federation between
  the specific issuers in play turns out not to exist. Until confirmed,
  any user-delegated flow crossing an unfederated issuer boundary
  should fall back to the service-credential flow this design already
  implements, rather than attempting exchange.

  Note also that `idp-secrets.json`'s entries are shaped for the
  client_credentials grant this design uses (`client_id`/
  `client_secret` authenticate DLM itself to obtain a token). In a
  token-exchange flow, the subject being exchanged is the user's own
  token, supplied at request time — not read from this file. The
  `client_id`/`client_secret` in a resolved entry may still be needed
  to authenticate the *requesting client* in some exchange grants, but
  their role shifts from "obtain a token" to "authorize this specific
  exchange," and `issuer_binding` still correctly identifies which
  entry to use either way — only what `request_token` (or its future
  exchange-flow equivalent) does with that entry changes.
