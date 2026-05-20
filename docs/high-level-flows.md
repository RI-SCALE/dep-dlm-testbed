# High-Level flows

## OIDC Token Flow

The testbed exclusively supports token-based authentication. The sequence
below shows how Rucio, FTS3 and the storage endpoints coordinate token
acquisition and refresh for a single third-party copy (TPC) transfer.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant KC as Keycloak (IdP)
    participant RS as Rucio (OIDC)
    participant FTS as FTS3 (OIDC)
    participant SE as Storage (Bearer Auth)

    User->>KC: Login (Get JWT)
    User->>RS: Add Rule + JWT

    NOTE over RS: Conveyor identifies need for transfer
    RS->>KC: Request FTS-audience token (f)
    KC-->>RS: Token f
    RS->>KC: Request source RSE token (s)
    KC-->>RS: Token s
    RS->>KC: Request destination RSE token (d)
    KC-->>RS: Token d

    RS->>FTS: Submit transfer + tokens (f, s, d)

    NOTE over FTS,KC: FTS refreshes s and d<br/>for the job lifetime
    FTS->>KC: Refresh token s
    KC-->>FTS: Renewed s
    FTS->>KC: Refresh token d
    KC-->>FTS: Renewed d

    FTS->>SE: TPC Request + tokens s, d
    SE->>KC: Validate token (Introspection/JWKS)
    SE-->>FTS: Transfer Started
```

> Token orchestration follows the design described in
> [Rucio Token Workflow Evolution](https://rucio.cern.ch/documentation/files/Rucio_Tokens_v0.1.pdf).
> Rucio acquires separate tokens for FTS authentication and for source/destination
> storage access, then bundles all three into the FTS submission. FTS is responsible
> for refreshing the storage-scoped tokens during the transfer lifetime.

## OIDC Deletion Flow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant RS as Rucio
    participant JC as Judge-Cleaner
    participant RP as Reaper
    participant SE as Storage (Bearer Auth)
    participant KC as Keycloak (IdP)

    User->>RS: update_replication_rule(lifetime=-1, purge_replicas=True)
    NOTE over RS: Rule expires_at set to past

    JC->>RS: Poll for rules where expires_at < now()
    JC->>RS: Release replica locks
    NOTE over JC,RS: purge_replicas=True → set OBSOLETE tombstone<br/>(1970-01-01) on replica

    RP->>RS: Poll for replicas with OBSOLETE tombstone
    RP->>KC: Request storage deletion token
    KC-->>RP: Token
    RP->>SE: DELETE replica via davs://
    SE-->>RP: Confirmed
    RP->>RS: Mark replica removed from catalogue
```

For reference checkout [the official Deletion Overview Rucio document](https://rucio.github.io/documentation/started/concepts/deletion_overview/).
