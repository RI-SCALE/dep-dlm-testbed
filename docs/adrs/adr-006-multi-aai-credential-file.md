---
status: proposed
date: 2026-07-08
decision-makers: WP4, DEP architecture team
consulted: RSE operators, AAI/IAM operators
informed: DEP component owners
---
# Multi-Entry AAI Credential File vs Static Single-AAI Config

## Context and Problem Statement

Rucio already supports multiple AAI/IdP configurations: `idpsecrets.json` is keyed by IdP nickname, and users can select an issuer explicitly (e.g. via `--oidc-issuer`). Separately, Rucio RSEs can carry arbitrary key/value attributes, and OIDC-related RSE attributes already exist (`oidc_support`, `oidc_base_path`).

What is missing is a standard **RSE → AAI/IdP binding**: a first-class attribute that tells Rucio "this RSE authenticates against issuer X," and a mechanism that uses that binding to automatically resolve the correct entry in the credential file. Today the relationship between an RSE and the issuer/credentials used for token acquisition is not represented as a configuration concept at all — it would have to be inferred or hardcoded per component.

This gap becomes a hard blocker once a component must deal with more than one AAI at once — e.g. DLM needs source and destination tokens from different AAIs, and RSEs may each sit behind a different issuer. The decision below is about introducing that RSE-to-AAI binding abstraction, and choosing the mechanism (a keyed credential file) that resolves it — not about adding multi-issuer support to Rucio, which already exists.

**NOTE:** Transfers are executed by background daemons (conveyor)
rather than in the context of an interactive user session, so the
tokens involved are understood to be service-level (client
credentials) rather than delegated user identity. If that holds, the
binding only ever needs to resolve to one fixed service credential per
RSE, with no per-user routing to design for — worth confirming with
the Rucio team rather than assuming.

If this assumption is ever revisited in favor of user-delegated token
exchange, `issuer_binding` resolving one static credential per RSE is
not sufficient on its own: token exchange across two RSEs bound to
*different* issuers additionally requires those issuers to trust each
other (federation, or a mediating token service) — this ADR's file-
and-attribute mechanism only solves *which* credential/issuer an RSE
maps to, not whether two issuers can vouch for each other's tokens.
That trust question sits outside this ADR's scope and would need its
own decision if pursued. See Design-003's open questions for how this
surfaced in practice.

This is a credential/config lifecycle concern, distinct from and sitting below the Authorization Service decision (see adr-authorization-service.md).

## Decision Drivers

* Support components acting as multi-AAI clients (e.g. DLM) without one-off config per component.
* Support secret rotation and revocation without redeploying components.
* Let RSE/AAI bindings be discoverable rather than assumed or hardcoded.
* Keep the operational and development footprint small — extend the existing config-loading pattern rather than building new infrastructure, and avoid introducing a secrets-manager dependency this decision does not require.

## Considered Options

1. Static single-AAI JSON config per component (current state) — no RSE-level binding at all.
2. Multi-entry AAI credential file, same structure as today's `idp-secrets.json` (including `client_id`, `client_secret`, `SCIM` credentials inline), keyed by binding name; a new RSE attribute holds the binding key and is given cross-component semantic meaning (RSE → AAI binding).
3. A new dynamic registry service with its own lookup API, and/or an external secrets manager (e.g. Vault) — considered and rejected as unnecessary scope for the problem at hand (see Rejected Alternative below).

## Decision Outcome

Chosen option: **Multi-entry `idp-secrets.json`, same structure as today, keyed by binding name — plus a new RSE attribute giving that key cross-component meaning — no secrets manager**

This is deliberately **not** a new registry service, and deliberately **not** dependent on an external secrets manager — it is the existing `idp-secrets.json` structure, unchanged, just extended from one issuer entry to a dict of entries keyed by binding name:
```
{
  "egi-dev": {
    "issuer": "https://aai-dev.egi.eu/auth/realms/egi",
    "client_id": "...",
    "client_secret": "...",
    "redirect_uris": [...],
    "audience": "rucio",
    "scope": "openid profile eduperson_entitlement offline_access read:/ write:/",
    "SCIM": { "client_id": "...", "client_secret": "..." }
  },
  "atlas-iam": { "issuer": "...", "...": "..." }
}
```

**Who ingests it**: each component (Rucio, DLM) loads this file itself at startup, exactly as it loads its current single-issuer file today — no new runtime dependency, no service to stand up, no Vault integration. Reload behavior (SIGHUP, interval, or restart) is an implementation detail, not a new architectural piece.

**The RSE-to-IAM binding is established solely through a new RSE attribute**: an attribute such as `issuer_binding = egi-dev` is resolved by key lookup into this file. This attribute does not exist in Rucio today as a standard, cross-component concept — this ADR is what gives it that meaning, on top of Rucio's existing generic RSE-attribute mechanism. Many RSEs sharing the same issuer point to the same entry, so rotating a `client_id`/`client_secret` is one edit to one entry, not a find-and-replace across every RSE.

For Rucio specifically, this relates through RSE attributes (`rse_attribute`), flat key→string pairs — well suited to holding the reference (`issuer_binding = egi-dev`), not the entry itself. Sufficient for one RSE with one binding. Not sufficient for an RSE needing more than one binding — flat attributes can't express a list. That case needs one of: multiple named attribute keys (`issuer_binding_src`/`issuer_binding_dst`, doesn't generalize), a JSON-valued attribute if supported, or the reference moved into RSE protocol definitions instead. Undecided — see Open Points.

## Rejected Alternative: Dynamic Registry Service and/or External Secrets Manager

Both a live registry service and an external secrets manager (Vault) were considered and rejected for now. They solve real problems (live lookup, secrets never at rest) but add a new deployable component and/or a hard external dependency, without a demonstrated need at the current AAI/component count. Revisit if the number of bindings, secret-rotation frequency, or audit requirements grow enough that keeping `client_secret` inline in a file becomes the actual bottleneck or an unacceptable risk.

## Consequences

### Positive
* No new service, lookup API, or secrets-manager dependency — same ingestion mechanism (load-a-JSON-file-at-startup) components already use today, just keyed by binding name instead of hardcoded to one issuer.
* Adding or rotating an AAI relationship is a single file-entry edit, not a redeploy and not a find-and-replace across every RSE referencing it.
* Multi-AAI components (DLM) are supported without bespoke handling.
* The RSE-to-IAM binding is established purely through a generic RSE attribute given a new, agreed cross-component meaning — no change to Rucio's attribute mechanism itself, keeping the model simple and consistent with how RSE configuration already works.

### Negative
* `client_secret` and SCIM credentials are at rest in the file, same as the current single-issuer config — this decision does not improve secret-at-rest posture, it only removes the single-issuer limitation. File permissions and repo-exclusion remain the only safeguards, not secrets-manager-grade isolation.
* File-based config still needs a reload mechanism (SIGHUP, interval, or restart) for changes to take effect without redeploying the component entirely — worth confirming this already exists rather than assuming it.
* Flat RSE attributes do not natively express an RSE with multiple AAI bindings — see Open Points.
* The `issuer_binding` attribute is a new convention this ADR introduces, not an existing Rucio feature — it needs to be documented and adopted consistently by every component reading RSE attributes, or the binding silently fails to resolve.

## Open Points

* **Multi-binding RSE representation is undecided.** Choose between multiple named attribute keys (doesn't generalize), a JSON-valued attribute (if supported), or modeling the binding in RSE protocol definitions instead of attributes. Needed before implementation for any RSE that isn't single-AAI.
* Confirm whether Rucio's attribute store in the target deployment(s) accepts JSON values, which would settle the above without a protocol-definition change.
* Confirm the accepted risk level of `client_secret` at rest in this file is acceptable long-term, or whether it triggers the Rejected Alternative (secrets manager) sooner than assumed.
* **Verify with the Rucio team** whether an experimental or DEP-specific Rucio branch/extension already introduces an RSE→AAI binding attribute, since current public Rucio documentation does not show one — if it exists, this ADR should adopt/align with it rather than defining a competing convention.

## Confirmation

Compliance is confirmed by:
* A defined `issuer_binding` (or equivalent) RSE attribute resolves, by key lookup, into the keyed credential file — this binding is a new cross-component convention, not a pre-existing Rucio feature.
* DLM (or any multi-AAI component) can be configured against N issuers by adding file entries, without code changes.
* The multi-binding RSE representation is explicitly decided (not defaulted to single-binding by omission) before this ADR is marked accepted.
