---
status: proposed
date: 2026-10-12
decision-makers:
consulted:
informed:
---

# ADR-008: Authorize Rucio actions by entitlement role, not by data ownership

## Context and Problem Statement

The Rucio OPA policy decides access in three layers. A **tier** (admin or
user) comes from the token's entitlements, through either the vendored ODRL
evaluator or an internal entitlement-to-tier map, selected by `tier_source`.
**Ownership** comes from the Rucio catalog: the policy package looks up who
owns each scope and rule in the request (`is_scope_owner`, `get_rule`) and
passes `owned_scopes`, `rule_owner` and `rule_scope` to the Rego, which only
lets users act on data their own account owns.
**Guards** check request arguments: RSE names against a naming convention
and an allowlist, and protocol schemes against an allowlist.

In DEP, data belongs to groups, not to individual accounts. Ownership per
account forces each user to work in a scope of their own, so the same files
end up registered under several scopes and replicated more than once.
Sharing data within a group needs extra machinery (group accounts, account
attributes or naming conventions), and every request costs catalog lookups.
Two tier sources mean two places where roles are defined, and the guards
need a hand-kept allowlist for every RSE that does not follow the naming
convention, although only admins can create RSEs or protocols in the first
place.

**Question:** what is the simplest authorization model that matches how DEP
groups use data and avoids duplicate copies?

## Decision Drivers

* Groups own data; no per-user or per-account granularity is required
* One copy of shared data, with no re-registration under personal scopes
* One place that defines who may do what: the AAI's entitlements (group and
  role) and the ODRL tier policy
* Decisions from the token's claims alone: no catalog lookups, no checks on
  request arguments, no hand-kept lists of RSE names
* DEP operators can do everything; DEP end users and model developers can
  manage data, not infrastructure

## Considered Options

1. Keep account ownership and guards (status quo)
2. Ownership by group, through scopes named after entitlement groups
3. Role-based tiers only: ODRL decides the tier from the token's claims

## Decision Outcome

Chosen option: **3. Role-based tiers only**, because it matches how DEP
shares data (by group, not by account), removes the duplicate-copy incentive,
needs neither catalog lookups nor maintained allowlists, and leaves the AAI
and the ODRL policy as the only source of roles.

The vendored ODRL evaluator is the sole tier source; it matches the token's
entitlements and `acr` against the ODRL tier policy. **Admin** (for example
`dep-operator`, with MFA as the ODRL policy requires) may perform every
action. **User** (for example `dep-end-user`, `model-developer`) may manage
rules, DIDs and replicas on any scope, whoever created them; everything else
— RSEs, protocols, accounts, scopes, rule approval and moves — stays
admin-only. A token with neither tier may do nothing. Accounts without a
token, such as root, are admins only when listed in `admin_accounts`.
Request arguments are not checked; Rucio itself rejects RSEs and protocols
that do not exist.

This supersedes the ownership parts, the
`owned_scopes`/`rule_owner`/`rule_scope` input, the
scope-ownership checks, the `tier_source` switch with its
internal entitlement map, and the RSE-naming and scheme guards with their
`known_rse_types`, `allowlisted_rse_names` and `allowed_schemes` data.

### Positive Consequences

* Members of a group share all data; registering it once is enough
* The policy package sends only the request to OPA: no database access, no
  scope or rule lookups
* Roles are defined once, in the AAI and the ODRL policy; changing who is an
  admin or user needs no code change
* New RSEs need no policy change, whatever their name
* The Rego shrinks to a tier lookup and an action list, fully covered by
  `opa test`

### Negative Consequences

* Any user-tier member can modify or delete any DID, replica or rule,
  including data another group created — acceptable only while DEP has no
  need to separate groups' data
* Rule accounts are not checked: a user can create a rule charged to another
  account's quota, or lock a rule
* RSE naming and protocol schemes are no longer enforced; admins are trusted
  to follow the conventions
* `dep-operator` without MFA gets no tier at all, since the ODRL policy only
  grants it `rucio:admin` with MFA
* Service accounts using userpass (for example `ddmlab` in the testbed) must
  be listed in `admin_accounts`, or they are denied
* Reintroducing separation between groups later needs a new decision

## Confirmation

* `opa test` covers every tier: user-tier personas can perform every user
  action on scopes they do not own and on RSEs of any name, and are denied
  every admin action; `dep-operator` with MFA can perform everything and
  without MFA nothing; tokens without a tier and unlisted accounts are
  denied; ODRL prohibitions revoke a tier
* The policy package's tests fail if it imports any Rucio catalog module
* `ingest_policies.py` loads only `vo/policy` (`admin_accounts`) and
  `dep/odrl`, and removes the obsolete `vo/entitlement_policy`
* Testbed transfer and persona tests pass with `admin_accounts` set to
  `["root", "ddmlab"]`

## Pros and Cons of the Options

### 1. Keep account ownership and guards (status quo)

* Good — fine-grained: users can only change data their account owns
* Good — RSE names and schemes are enforced
* Bad — group sharing needs extra machinery; encourages duplicate copies
* Bad — catalog lookups on every request; two tier sources and an RSE
  allowlist to maintain

### 2. Ownership by group, through scopes named after entitlement groups

* Good — groups share data; no catalog lookup for group scopes
* Bad — every scope must follow a naming convention; tier groups must never
  get a scope
* Bad — keeps ownership logic that DEP does not need

### 3. Role-based tiers only

* Good — simplest model; one source of roles; decisions from claims alone
* Good — matches group-owned data and avoids duplicate copies
* Bad — no separation between groups' data within the VO
* Bad — no protection of rules against other user-tier members, and no
  enforcement of RSE or protocol conventions

## Evidence / Links

* `shared/config/opa/authz.rego`, `authz_test.rego`
* `shared/config/opa/odrl/data.json`: tier policy
* `shared/config/opa/vendor/opa-ri-scale/VENDORED.md`: ODRL evaluator
* `shared/scripts/ingest_policies.py`: loads policy and data into OPA
* `shared/patches/rucio/rucio_opa_v5_policy/`: policy package
