---
status: proposed
date: 2026-07-15
decision-makers: dep-dlm-testbed contributors
consulted: none
informed: dep-dlm-testbed contributors
---

# ADR-002: Store Per-Issuer OIDC Grant Capabilities in idpsecrets.json

## Context and Problem Statement

`oidc.py`, `rse.py`, and `fts3.py` each branch on a single global
`[oidc] scope_profile` config value to decide whether to send RFC 8707
`resource=` or plain `audience=` on OIDC token requests, how to remap
scope names, and which scopes to drop — currently a binary `wlcg`/`egi`
switch, duplicated across six call sites plus several inconsistent
string checks in `init-testbed.sh`.

EGI Check-In has already demonstrated this needs to vary not just by
issuer but by **grant type** within a single issuer (`resource=` is
honored on `client_credentials` but not on `token-exchange`), and a
second issuer (LS AAI / Perun) is pending onboarding with unknown
constraints. A structured, issuer-keyed capability model is needed —
see the accompanying design doc for the full model.

Where should that per-issuer capability data live?

## Decision Drivers

* Both Python (`oidc.py`, `rse.py`, `fts3.py`) and bash
  (`init-testbed.sh`) need to resolve the same data for the same
  issuer.
* The resolution key must be a single, unambiguous value already
  present in the system — not a second free-text name that has to be
  kept in sync with a first one (the exact problem `scope_profile` vs
  `SCOPE_PROFILE` has today).
* Avoid adding new config surface / new files to mount, secret-manage,
  and keep in sync with `rucio.cfg`'s `admin_issuer`/`issuer`.
* Must not require any change to existing WLCG or EGI deployments that
  don't need new capabilities.

## Considered Options

1. Add a `capabilities` block to each issuer entry in the existing,
   already issuer-keyed `idpsecrets.json`.
2. Introduce a new standalone file, e.g. `oidc-profiles.json`, keyed by
   issuer or by profile name.
3. Keep capability logic as code (a per-issuer `if`/`dict` map inside
   `oidc.py`), not externalized to config at all.

## Decision Outcome

Chosen option: **Extend `idpsecrets.json` with an optional
`capabilities` block per issuer entry (option 1).**

`idpsecrets.json` is already the canonical issuer-keyed store, already
loaded by `__get_rucio_oidc_clients()` in Python, and already mounted
as a secret in both compose and k8s. Extending it means the issuer URL
is the single join key everywhere — Python and bash both key off the
same dict, and there is nothing left to drift, unlike the current
`SCOPE_PROFILE`/`scope_profile` split. A missing `capabilities` block
defaults to today's WLCG behavior, so no existing entry needs to
change.

### Positive Consequences

* No new file to create, mount, or secret-manage.
* Single resolution key (issuer URL) shared by Python and bash;
  eliminates the `SCOPE_PROFILE` vs `scope_profile` naming drift.
* Onboarding a new IdP is adding one JSON block to an existing file,
  not introducing new infrastructure.
* Backward compatible by construction: absence of the key is the
  default.

### Negative Consequences

* `idpsecrets.json` mixes secret material (`client_secret`) with
  non-secret capability metadata in the same file; capability data
  will be visible to anything with read access to the secret, though
  it carries no confidentiality requirement of its own.
* Slightly widens the responsibility of a file whose name suggests
  "secrets only." Mitigated by treating `capabilities` as a clearly
  separated, documented sub-key rather than flattening it into the
  top level.

## Confirmation

* `get_capabilities(issuer, grant)` unit-tested against fixture
  `idpsecrets.json` content, including the absent-key default case.
* `init-testbed.sh`'s `jq`-based lookups against the same file produce
  identical `grant_mode` resolution to the Python side for the
  `egi-dev` profile.
* `egi-dev` CI job continues to pass unchanged after the refactor,
  confirming no behavior change for the one real profile in use today.

## Pros and Cons of the Options

### 1. Extend idpsecrets.json (chosen)

* Good — single join key (issuer URL), already used everywhere.
* Good — no new file, no new mount/secret to manage.
* Good — backward compatible; absent key = current default.
* Bad — mixes secret and non-secret data in one file.

### 2. Standalone oidc-profiles.json

* Good — clean separation of secret vs. capability metadata.
* Bad — a second issuer-keyed file that must stay in sync with
  `idpsecrets.json`'s issuer keys; reintroduces the drift problem this
  change is meant to eliminate.
* Bad — new file to mount and manage in both compose and k8s.

### 3. Capability logic as code

* Good — no config schema to design or validate.
* Bad — onboarding a new IdP requires a code change and redeploy, not
  a config change; directly contradicts the goal of making LS AAI
  onboarding "add one config block."
* Bad — bash (`init-testbed.sh`) has no access to Python-side data
  structures; the duplication problem this change is meant to solve
  would persist there.

## Evidence / Links

* Design doc (full capability model, touch points, fallback behavior):
  [`design/design-doc-001-oidc-capability-profiles.md`](../design/design-doc-001-oidc-capability-profiles.md)
* EGI `resource=`/`token-exchange` constraint (runbook 2, repro
  script) — the evidence that a per-grant-type, not just per-issuer,
  model is required.
