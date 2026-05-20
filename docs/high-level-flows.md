# High-Level flows

## OIDC TPC Transfer Flow

The testbed exclusively supports token-based authentication. The sequence
below shows how Rucio, FTS3 and the storage endpoints coordinate token
acquisition and refresh for a single third-party copy (TPC) transfer,
including the Rucio conveyor daemons that drive the pipeline.

Exercised by [test_rucio_transfers.py](../shared/tests/test_rucio_transfers.py):
`add_replication_rule` → judge-evaluator → conveyor-submitter → conveyor-poller
→ conveyor-finisher → rule state OK.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant KC as Keycloak (IdP)
    participant RS as Rucio
    participant JE as Judge-Evaluator
    participant CS as Conveyor-Submitter
    participant CP as Conveyor-Poller
    participant CF as Conveyor-Finisher
    participant FTS as FTS3 (OIDC)
    participant SE as Storage (Bearer Auth)

    User->>RS: add_replication_rule(did, rse_expression)
    NOTE over RS: Rule created in REPLICATING state

    JE->>RS: Evaluate rule → create transfer request
    RS-->>JE: Request queued

    CS->>RS: Fetch queued transfer requests
    CS->>KC: Request FTS-audience token (f)
    KC-->>CS: Token f
    CS->>KC: Request source RSE token (s)
    KC-->>CS: Token s
    CS->>KC: Request destination RSE token (d)
    KC-->>CS: Token d
    CS->>FTS: Submit transfer job + tokens (f, s, d)
    FTS-->>CS: Job ID

    NOTE over FTS,KC: FTS refreshes s and d<br/>for the job lifetime
    FTS->>KC: Refresh token s
    KC-->>FTS: Renewed s
    FTS->>KC: Refresh token d
    KC-->>FTS: Renewed d
    FTS->>SE: HTTP COPY (TPC) + tokens s, d
    SE->>KC: Validate token (Introspection/JWKS)
    SE-->>FTS: Transfer complete

    CP->>FTS: Poll job state
    FTS-->>CP: FINISHED

    CF->>RS: Mark transfer done → lock state OK
    NOTE over RS: Rule transitions to OK state
```

> Token orchestration follows the design described in
> [Rucio Token Workflow Evolution](https://rucio.cern.ch/documentation/files/Rucio_Tokens_v0.1.pdf).
> Rucio acquires separate tokens for FTS authentication and for source/destination
> storage access, then bundles all three into the FTS submission. FTS is responsible
> for refreshing the storage-scoped tokens during the transfer lifetime.

## OIDC Deletion Flow

Rule-based deletion path, as exercised by
[test_rucio_deletion.py](../shared/tests/test_rucio_deletion.py):
`update_replication_rule(lifetime=-1)` expires the rule; Judge-Cleaner sets
the tombstone; Reaper physically deletes from storage.

**NOTE:** DID-based deletion (Undertaker) is a separate flow triggered by
DID expiration, not rule expiration. The Undertaker is not involved in the
flow below.

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

> For reference see the
> [official Rucio Deletion Overview](https://rucio.github.io/documentation/started/concepts/deletion_overview/).
