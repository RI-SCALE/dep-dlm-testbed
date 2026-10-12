---
status: proposed
date: 2026-10-12
decision-makers:
consulted:
informed:
---

# ADR-008: Authorize Rucio actions by entitlement role instead of data ownership

## Context and Problem Statement

Rucio authorization currently combines three things: a tier (admin or user)
derived from the token's entitlements, ownership of scopes and rules looked
up in the Rucio catalog, and checks on request arguments such as RSE names
and protocol schemes.

In DEP, data belongs to groups, not to individual accounts. Per-account
ownership pushes each user into a scope of their own, so the same files get
registered and replicated more than once, and sharing data within a group
needs extra machinery. Every decision also costs catalog lookups, roles are
defined in two places, and the argument checks need a hand-kept list of RSE
names for actions only admins can perform anyway.

**Question:** what is the simplest authorization model that matches how DEP
groups share data and avoids duplicate copies?

## Decision Drivers

* Groups own data; no per-account granularity is required
* One copy of shared data
* One source of roles: the AAI's entitlements (group and role) and the ODRL
  tier policy
* Decisions from the token's claims alone, without catalog lookups or
  maintained lists
* DEP operators can do everything; end users and model developers manage
  data, not infrastructure

## Considered Options

1. Keep account ownership and argument checks (status quo)
2. Group ownership through scopes named after entitlement groups
3. Role-based tiers only, decided by the ODRL policy

## Decision Outcome

Chosen option: **3. Role-based tiers only**, because it matches how DEP
shares data, removes the incentive for duplicate copies, and makes the AAI
and the ODRL policy the single source of roles, with no catalog lookups or
maintained lists.

The ODRL policy assigns each token a tier from its entitlements and
authentication level. Admins (e.g. `dep-operator`, with MFA) may perform
every action. Users (e.g. `dep-end-user`, `model-developer`) may manage
rules, DIDs and replicas on any scope; everything else stays admin-only. A
token without a tier may do nothing, and accounts without a token are admins
only when explicitly listed.

### Positive Consequences

* Group members share all data; registering it once is enough
* Authorization needs no catalog access
* Changing who is an admin or user needs no code change
* New RSEs need no policy change

### Negative Consequences

* Any user can modify or delete any DID, replica or rule, including another
  group's — acceptable only while DEP needs no separation between groups
* Rule accounts are not checked, so a user can charge another account's
  quota
* RSE naming and protocol conventions are no longer enforced; admins are
  trusted to follow them
* `dep-operator` without MFA has no access at all
* Token-less service accounts (e.g. `ddmlab`) must be listed as admins

## Confirmation

* Policy tests show that users can perform every data action regardless of
  ownership and are denied every admin action, that operators need MFA, and
  that tokens or accounts without a tier are denied
* The policy package's tests fail if it reads the Rucio catalog
* Testbed transfer and persona tests pass

## Pros and Cons of the Options

### 1. Keep account ownership and argument checks (status quo)

* Good — fine-grained: users only change data their account owns
* Good — RSE and protocol conventions are enforced
* Bad — group sharing needs extra machinery and encourages duplicate copies
* Bad — catalog lookups per request; two role sources and an RSE list to
  maintain

### 2. Group ownership through scopes named after entitlement groups

* Good — groups share data without catalog lookups
* Bad — every scope must follow a naming convention
* Bad — keeps ownership logic DEP does not need

### 3. Role-based tiers only, decided by the ODRL policy

* Good — simplest model, one source of roles, decisions from claims alone
* Good — matches group-owned data and avoids duplicate copies
* Bad — no separation between groups' data
* Bad — no protection of rules or conventions against users and admins

## Evidence / Links

* `shared/config/opa/authz.rego`, `authz_test.rego`
* `shared/config/opa/odrl/data.json`: tier policy
* `shared/config/opa/vendor/opa-ri-scale/VENDORED.md`: ODRL evaluator
* `shared/scripts/ingest_policies.py`
* `shared/patches/rucio/rucio_opa_v5_policy/`
