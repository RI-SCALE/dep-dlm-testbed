---
status: proposed
date: 2026-10-14
decision-makers:
consulted:
informed:
---

# ADR-007: Map tokens to per-user UIDs and entitlement-based groups on HPC storage

## Context and Problem Statement

DEP stores Rucio-managed data on HPC storage (e.g. Lustre) behind token-aware
endpoints (XRootD, StoRM WebDAV via Teapot, dCache, EOS). Lustre knows only
numeric UIDs/GIDs, never tokens. Every validated token must therefore be
translated into a local user before a file is written or read, and whatever
is lost in that translation is lost for authorization and audit on the
storage.

Today Rucio submits transfers to FTS with its own service token, so the
storage sees Rucio, not the user. All data lands under one service identity,
and user-level access control and attribution exist only inside Rucio. This
conflicts with a **hard constraint**: user context must be preserved end to
end, and access must be fine-grained at user level.

Rucio development is planned to add token exchange (RFC 8693), so transfers
carry a token with `sub` = user and `act` = Rucio. The AAI already issues an
`entitlements` claim with group and role membership, e.g.
`urn:example:aai.example.org:group:dep-operator:role=member`. At the same
time, project members must be able to read each other's data. Rucio keeps
one replica of a DID per RSE, and ADR-008 lets shared data be registered
once; storage permissions must not force a copy per user on top of that.

**Question:** how should storage endpoints map token identity to local users
and groups so that user context is preserved and all project members can
read the same replica?

## Decision Drivers

* User context preserved end to end (hard constraint)
* Fine-grained authorization per user, group and role
* One replica per DID readable by all project members, so storage
  permissions never require a copy per user
* Traceability: every action attributable to a person and an actor
  (ISO 27001)
* Site autonomy: HPC sites keep control of their UID/GID space
* Low operational effort: no hand-maintained mapping data
* No changes to Lustre; Rucio changes limited to the planned token exchange

## Considered Options

1. Single or per-group shared account per DEP site
2. Per-subject mapfile at the endpoint
3. Username claim only, groups from the site directory
4. Username claim + entitlements, via Rucio token exchange
5. Rucio account → UID mapping

## Decision Outcome

Chosen option: **4. Username claim + entitlements, via Rucio token
exchange**, because it meets the hard constraint with group membership
kept central in the AAI, lets project members share one replica, records
the actor, and leaves each site in control of its own ID space.

| Token part | Decides | Enforced by |
| --- | --- | --- |
| Username claim | file owner (UID) | endpoint writes as the mapped user |
| Entitlement group | permitted project path | endpoint authz rules; Lustre via project GID |
| Entitlement role | read or read-write | endpoint only |
| `act`, `sub` | chain of custody | endpoint log |

Endpoints cannot set a GID from a token: the writing process gets the user's
groups from the site directory. The project GID on files therefore comes
from **setgid project directories**, and Lustre enforcement relies on project
groups **synced from the AAI** into the site directory.

Files are owner read-write, project read-only; project directories are owned
by the Rucio service account (sticky bit) so the reaper can delete any
replica. Owner-only files are not allowed: transfers run with the requesting
user's token and would fail on files owned by another member.

Option 1 is used as an **interim** for Rucio transfers until token exchange is
available; direct user access with personal tokens follows Option 4 from the
start. Endpoint configuration, directory layout and runtime flow are in the
concept doc.

### Positive Consequences

* User, group, role and actor are preserved on storage and in logs
* Membership is managed centrally in the AAI; the endpoint denies access
  with the next token after an entitlement is removed
* One replica serves all project members, provided they use the same DID;
  deduplication itself comes from Rucio and ADR-008, not from this mapping
* Sites map names to their own UIDs/GIDs; no shared ID space required
* UID mapping and entitlement authorization are configuration on XRootD
  (SciTokens + multiuser) and Teapot (`KEYCLOAK` mapping)
* Credits and usage stay per Rucio account (ADR-005); file ownership adds
  per-user attribution on disk

### Negative Consequences

* Depends on Rucio token exchange (development) and on FTS passing exchanged
  tokens
* Teapot's generated StoRM policy permits by subject only; entitlement- and
  role-based path rules need a template change
* `act` and entitlement logging is not available on XRootD or StoRM today
  (development or log enrichment)
* The role is enforced only at the endpoint; on Lustre every project group
  member has the same rights unless separate read-only groups are added
* On Lustre, revocation takes effect only after the site directory sync
* Storage scopes must be narrow or scope-based authz disabled, otherwise a
  broad scope grants access regardless of entitlement
* Every DEP user needs an account, and every project a group, at each HPC
  site they use
* Data written during the interim is owned by the service account and needs
  a one-off migration to project groups
* Duplicates are still possible when the same content is registered under
  different DIDs, written outside Rucio, or needed across projects without
  an ACL; they are detected, not prevented

## Confirmation

* A transfer submitted by a user creates a file owned by that user's local
  UID and the project's GID, mode `-rw-r-----`, on each DEP HPC site
* Another project member can read that file but cannot modify or delete it
* A user without the matching entitlement is denied at the endpoint, even
  with a valid storage scope, and on Lustre after the directory sync
* Removing an entitlement in the AAI denies endpoint access once the current
  token expires
* Endpoint logs contain `sub`, `act`, entitlement and mapped UID/GID for
  every request
* Two project members reading the same DID resolve to the same physical
  path
* Rucio's reaper deletes user-owned replicas in project directories
* A periodic catalog check finds no files with the same checksum and size
  under different DIDs
* A periodic check finds no duplicate or reused UIDs/GIDs and no orphaned
  files
* Transfers queued longer than the token lifetime complete successfully

## Pros and Cons of the Options

### 1. Single or per-group shared account per DEP site

Endpoint maps the DEP issuer, or each entitlement group (Teapot `VO` mode),
to one shared local user.

* Good — configuration only; works with today's Rucio
* Good — few UIDs to allocate and verify per site
* Bad — user context lost on storage; violates the hard constraint
* Bad — every member can modify and delete every file; isolation and
  attribution rely on logs and Rucio alone

### 2. Per-subject mapfile at the endpoint

Endpoint maps each `sub` to a personal site account via a mapfile
(e.g. Teapot `FILE` mode).

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

Username claim to local UID, entitlement to path and access level at the
endpoint, project GID from setgid directories with AAI-synced groups, `act`
logged.

* Good — meets the hard constraint: user, group, role and actor preserved
* Good — central membership in the AAI; fast revocation at the endpoint
* Good — project members can share one replica; site ID autonomy kept
* Bad — needs Rucio development and FTS support for exchanged tokens
* Bad — Teapot template change and `act` logging needed
* Bad — account and group provisioning and sync at every HPC site

### 5. Rucio account → UID mapping

Rucio stores a UID per account and passes it to storage.

* Good — single place to manage the mapping
* Bad — no mechanism in Rucio or FTS to pass UIDs; requires Rucio core
  changes
* Bad — couples Rucio to every site's ID space; no group or role model

## Evidence / Links

* [Identity mapping on HPC storage](../concepts/identity-mapping-on-hpc-storage.md): concept with mapping, configuration, directory layout and runtime views
* [ADR-005: Usage reporting for credits](adr-005-usage-reporting-for-credits.md)
* [ADR-008: Authorize Rucio actions by entitlement role instead of data ownership](adr-008-authorize-by-role-and-not-owner.md)
* [RFC 8693: OAuth 2.0 Token Exchange](https://www.rfc-editor.org/rfc/rfc8693)
* AARC-G002: expressing group membership and role information (entitlement syntax)
* WLCG Common JWT Profiles (storage scopes)
* Source reviewed: [XrdSciTokens](https://github.com/xrootd/xrootd/tree/master/src/XrdSciTokens),
  [xrootd-multiuser](https://github.com/opensciencegrid/xrootd-multiuser),
  [Teapot](https://github.com/interTwin-eu/teapot),
  [StoRM WebDAV](https://github.com/italiangrid/storm-webdav)
* Open questions: Rucio token exchange design and timeline; FTS support for
  exchanged tokens; whose token Rucio uses when several accounts' rules share
  one replica; Teapot userinfo with exchanged tokens; entitlement URNs as
  XRootD authdb group names; stable username claim; role → access-level
  policy; account provisioning and group sync at HPC sites; cross-project
  data placement; endpoint log retention
