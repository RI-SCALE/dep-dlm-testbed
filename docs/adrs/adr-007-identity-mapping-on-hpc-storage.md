---
status: proposed
date: 2026-10-12
decision-makers:
consulted:
informed:
---

# ADR-007: Map tokens to per-user UIDs and entitlement-based groups on HPC storage

## Context and Problem Statement

DEP stores Rucio-managed data on HPC storage (e.g. Lustre) behind token-aware
endpoints (XRootD, StoRM WebDAV, dCache, EOS). Lustre knows only numeric
UIDs/GIDs, never tokens. Every validated token must therefore be translated
into a local user and group before a file is written or read, and whatever is
lost in that translation is lost for authorization and audit on the storage.

Today Rucio submits transfers to FTS with its own service token, so the
storage sees Rucio, not the user. All data lands under one service identity,
and user-level access control and attribution exist only inside Rucio. This
conflicts with a **hard constraint**: user context must be preserved end to
end, and access must be fine-grained at user level.

Rucio development is planned to add token exchange (RFC 8693), so transfers
carry a token with `sub` = user and `act` = Rucio. The AAI already issues an
`entitlements` claim with group and role membership, e.g.
`urn:example:aai.example.org:group:dep-operator:role=member`. At the same
time, project members must share data without duplicate copies on the
destination.

**Question:** how should storage endpoints map token identity to local users
and groups so that user context is preserved and shared project data stays a
single copy?

## Decision Drivers

* User context preserved end to end (hard constraint)
* Fine-grained authorization per user, group and role
* Shared project data without duplicate copies on the destination
* Traceability: every action attributable to a person and an actor
  (ISO 27001)
* Site autonomy: HPC sites keep control of their UID/GID space
* Low operational effort: no hand-maintained mapping data
* No changes to Lustre; Rucio changes limited to the planned token exchange

## Considered Options

1. Single service account per DEP site
2. Per-subject mapfile at the endpoint
3. Username claim only, groups from the site directory
4. Username claim + entitlements, via Rucio token exchange
5. Rucio account → UID mapping

## Decision Outcome

Chosen option: **4. Username claim + entitlements, via Rucio token
exchange**, because it is the only option that meets the hard constraint
while keeping group membership central in the AAI, sharing one copy per
project, recording the actor, and leaving each site in control of its own
ID space.

The username claim decides the file owner (attribution); the entitlement's
group part decides the file group and permitted paths, and its role the access
level (authorization); `act` is recorded in endpoint logs (chain of custody).
Option 1 is used as an **interim** for Rucio transfers until token exchange is
available; direct user access with personal tokens follows Option 4 from the
start. Mapping, directory layout and runtime flow are described in the
concept doc.

### Positive Consequences

* User, group, role and actor are all preserved on storage and in logs
* Membership is managed centrally in the AAI; removing an entitlement
  revokes access with the next token
* One physical copy per project serves all members
* Sites map names to their own UIDs/GIDs; no shared ID space required
* Credits and usage stay per Rucio account (ADR-005); file ownership adds
  per-user attribution on disk

### Negative Consequences

* Depends on Rucio token exchange (development) and on FTS passing exchanged
  tokens
* Entitlement mapping is not native on every endpoint; some storage types may
  need configuration work or a small mapping layer
* Per-user ownership on disk requires endpoints that write as the mapped
  user; otherwise attribution lives only in endpoint logs and Rucio
* Every DEP user needs an account, and every project a group, at each HPC
  site they use
* Data written during the interim is owned by the service account and needs
  a one-off migration to project groups

## Confirmation

* A transfer submitted by a user creates a file owned by that user's local
  UID and the project's GID on each DEP HPC site
* A user without the matching entitlement is denied read and write on the
  project path, at the endpoint and on Lustre
* Removing an entitlement in the AAI denies access once the current token
  expires
* Endpoint logs contain `sub`, `act`, entitlement and mapped UID/GID for
  every request
* Rucio's reaper deletes user-owned replicas in project directories
* A periodic check finds no duplicate or reused UIDs/GIDs and no orphaned
  files
* Transfers queued longer than the token lifetime complete successfully

## Pros and Cons of the Options

### 1. Single service account per DEP site

Endpoint maps the DEP issuer to one local user.

* Good — configuration only; works with today's Rucio
* Good — one UID to allocate and verify per site
* Bad — user context lost on storage; violates the hard constraint
* Bad — isolation and attribution rely on Rucio alone

### 2. Per-subject mapfile at the endpoint

Endpoint maps each `sub` to a personal site account via a mapfile.

* Good — per-user ownership on disk
* Bad — `sub` is opaque; needs a sync job per site and a process for new and
  deleted users
* Bad — no group model; shared project data needs separately managed ACLs

### 3. Username claim only, groups from the site directory

Endpoint maps a username claim to a local user; group membership comes from
each site's directory.

* Good — no mapfile; site resolves name to UID
* Bad — project membership managed per site, drifting from DEP membership
* Bad — no role information for access levels

### 4. Username claim + entitlements, via Rucio token exchange

Username claim to local UID, entitlement group to local GID and path, role to
access level, `act` logged.

* Good — meets the hard constraint: user, group, role and actor preserved
* Good — central membership in the AAI; fast revocation
* Good — one copy per project; site ID autonomy kept
* Bad — needs Rucio development and FTS/endpoint support for exchanged tokens
* Bad — entitlement mapping and write-as-user support vary per storage type
* Bad — account and group provisioning at every HPC site

### 5. Rucio account → UID mapping

Rucio stores a UID per account and passes it to storage.

* Good — single place to manage the mapping
* Bad — no mechanism in Rucio or FTS to pass UIDs; requires Rucio core
  changes
* Bad — couples Rucio to every site's ID space; no group or role model

## Evidence / Links

* [Identity mapping on HPC storage](../concepts/identity-mapping-on-hpc-storage.md): concept with mapping, directory layout and runtime views
* [ADR-005: Usage reporting for credits](adr-005-usage-reporting-for-credits.md)
* [RFC 8693: OAuth 2.0 Token Exchange](https://www.rfc-editor.org/rfc/rfc8693)
* AARC-G002: expressing group membership and role information (entitlement syntax)
* WLCG Common JWT Profiles (storage scopes)
* Open questions: Rucio token exchange design and timeline; FTS and endpoint
  support per storage type; stable username claim; role → access-level
  policy; account provisioning at HPC sites; cross-project data placement;
  endpoint log retention
