# Design-006: Token identity mapping on XRootD and Teapot/StoRM WebDAV

- **Status:** Proposed
- **Owner:** <team / individual>
- **Related ADR(s):** [ADR-007](../adrs/adr-007-identity-mapping-on-hpc-storage.md)
  (why), [concept](../concepts/identity-mapping-on-hpc-storage.md) (overview)

## Problem

ADR-007 requires per-user file ownership, entitlement-based access and a
shared project group. Today neither endpoint is configured for it:

- **XRootD**: the deployed `scitokens-module.cfg` sets only `issuer` and
  `base_path`. With the defaults (`XrdSciTokensAccess.cc` ~L1344:
  `username_claim` empty, `map_subject` false, `default_user` empty,
  `groups_claim = wlcg.groups`, `authorization_strategy` = `capability group
  mapping`) access is granted by scope alone and no username is mapped.
- **Teapot**: `mapping =` takes one of `FILE`, `ALISE`, `VO`, `KEYCLOAK`
  (`config.ini`). `VO` (`vo_mapping.py` L28–66) maps a whole group to one
  shared account, which loses attribution. Claims are read from userinfo,
  not the token (`teapot.py` ~L1161), so the service-account token path has
  no user or groups.
- **StoRM WebDAV**: reads groups from `groups`, `wlcg.groups`,
  `entitlements` (`GrantedAuthoritiesMapperSupport.java` L24), not
  `eduperson_entitlement`. Teapot's generated policy
  (`templates/application.yml.template`) permits `jwt-subject` and denies
  `anyone`; no group or role rules.
- **GID**: no endpoint derives a GID from the token. `xrootd-multiuser`
  (`UserSentry.hh` ~L155–209) and Teapot (`sudo -u`, `teapot.py` ~L490) use
  the user's primary and supplementary groups from the site directory.
- **`act`**: not logged by either endpoint.

## Goals

- Username claim → per-user local account; files written as that user
- Entitlement group/role → path and read/write decision at the endpoint
- Files `owner:project -rw-r-----`; members read, cannot modify or delete
  others' files; reaper can delete everything
- A valid scope without the matching entitlement is denied
- `sub`, `act`, entitlement, mapped UID/GID logged per request

## Non-goals

- Rucio token exchange and FTS token forwarding (separate work; this design
  is testable with personal user tokens)
- dCache and EOS (follow once XRootD and StoRM are proven)
- Setting the GID from the token (not supported by any endpoint; solved by
  directory inheritance)
- Role enforcement on Lustre (endpoint only, see open questions)
- Teapot `VO` mode (contradicts ADR-007)

## Design

**Keycloak**: client scope mappers for `preferred_username` and
`entitlements` (AARC-G002 URNs); storage scopes narrowed to the project path
or not issued; userinfo returns both claims.

**XRootD**, server config:

```
ofs.authlib ++ libXrdAccSciTokens.so config=/etc/xrootd/scitokens-module.cfg
ofs.authorize 1
acc.authdb /etc/xrootd/scitokens.authdb
# + xrootd-multiuser plugin, umask 027
```

`scitokens-module.cfg`:

```ini
[Global]
audience = https://<endpoint>:1094

[Issuer DEP]
issuer = https://aai.example.org/
base_path = /data/dep
username_claim = preferred_username
groups_claim = entitlements
authorization_strategy = group mapping
```

`scitokens.authdb` (one line per project and role; URN as group name to be
verified):

```
g urn:example:aai.example.org:group:dep-operator:role=member /data/dep/dep-operator a
g urn:example:aai.example.org:group:project-x:role=member    /data/dep/project-x    rl
```

**Teapot / StoRM**: `config.ini` `mapping = KEYCLOAK`; storage area
`fineGrainedAuthzEnabled=true`, `voMapEnabled=false`, `wlcgScopeAuthzEnabled`
off. Patch `application.yml.template` to render one policy per project from
a new config list (entitlement → path → actions) using StoRM's group
principal, keeping the final `anyone` deny.

**Site**: accounts and project groups synced from the AAI; project
directories `deprucio:<project>`, mode `3770`, default ACL `group::r-x`,
`other::---`.

**Logging**: XRootD and StoRM access logs extended (or post-processed) to
carry `sub`, `act`, entitlement, UID/GID.

## Touch points

| File / component | Change |
|---|---|
| Keycloak realm | `preferred_username`, `entitlements` mappers; narrow scopes |
| `xrootd.cfg` | authdb, multiuser plugin |
| `scitokens-module.cfg` | `username_claim`, `groups_claim`, `authorization_strategy` |
| `scitokens.authdb` | new, per project entitlement |
| Teapot `config.ini` | `mapping = KEYCLOAK`, project policy list |
| Teapot `templates/application.yml.template` | **code**: group/role policies |
| Teapot `storage_area.properties` | fine-grained on, VO map and scope authz off |
| Endpoint logging | **code/config**: `act`, entitlement, UID/GID |
| Site directory, Lustre dirs | groups sync, ownership, mode, default ACLs |

## Fallback / safety behavior

- **Missing or unsafe username claim**: XRootD rejects the token
  (`XrdSciTokensAccess.cc` ~L914–927); Teapot raises and does not start an
  instance (`teapot.py` ~L840). Fails closed.
- **No matching entitlement**: no authdb rule → deny; StoRM falls through
  to the `anyone` deny policy.
- **Misspelled `authorization_strategy` value**: logged and ignored
  (~L1365); check the startup log so `capability` is not silently the only
  strategy.
- **Unknown local user**: multiuser / `sudo -u` fail; request denied.
- **Partial rollout**: the interim Rucio service account keeps working via
  its own issuer section or mapping; migrate its data to project groups
  once.

## Testing

- XRootD CI (extend `tests/XRootD`-style setup): tokens for member,
  read-only member, non-member, broad scope without entitlement, missing
  username claim; assert allow/deny and file owner, group, mode
- Teapot robot tests: same matrix against WebDAV
- Lustre/POSIX check: second member reads, cannot modify or delete; reaper
  account deletes
- Log check: every request line has `sub`, `act`, entitlement, UID/GID

## Sequencing

1. Keycloak claims and narrow scopes
2. Site: groups, directories, ACLs on a test area
3. XRootD config + authdb + multiuser; run test matrix
4. Teapot `KEYCLOAK` mapping; template patch; run test matrix
5. Logging of `act` and entitlement
6. Switch Rucio transfers once token exchange lands; migrate interim data

## Open questions

- Do entitlement URNs (with `:` and `=`) work as authdb group names, or is a
  `name_mapfile` to short group names needed?
- Exact StoRM group principal type name and support for role suffixes
- Does Keycloak userinfo return user and entitlements for exchanged tokens?
- Whose token does Rucio use when several rules share one replica?
- Read-only role on Lustre: separate `-ro` groups or endpoint-only?
- XRootD release in production: are all options above supported there?
