# High-Level flows

## OIDC TPC Transfer Flow

The testbed exclusively supports token-based authentication. The sequence
below shows how Rucio, FTS3 and the storage endpoints coordinate tokens for a
single third-party copy (TPC) transfer, including the Rucio conveyor daemons
that drive the pipeline.

Exercised by [test_rucio_transfers.py](../shared/tests/test_rucio_transfers.py):
`add_replication_rule` → judge-evaluator → conveyor-submitter → conveyor-poller
→ conveyor-finisher → rule state OK.

FTS can run in two token modes. The testbed currently supports both **managed and unmanaged token flows**.

### Managed mode

Rucio delegates short-lived access tokens; FTS owns the lifecycle, performing a
**token-exchange** (the `TOKEN_PREP` step) to obtain refresh tokens, then
refreshing on demand. The submitted storage tokens **must carry `offline_access`**
for the exchange to succeed.

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
    CS->>RS: Fetch queued transfer requests
    CS->>KC: Request FTS / source / dest tokens (f, s, d)
    KC-->>CS: Tokens f, s, d (with offline_access)
    CS->>FTS: Submit transfer job + tokens (f, s, d)
    FTS-->>CS: Job ID
    NOTE over FTS: Transfer enters TOKEN_PREP state
    FTS->>KC: token-exchange(s, d) → refresh tokens
    KC-->>FTS: Refresh tokens stored
    NOTE over FTS,KC: FTS refreshes s and d on demand<br/>for the job lifetime
    FTS->>SE: HTTP COPY (TPC) + fresh tokens s, d
    SE->>SE: Validate token offline (JWKS signature + iss/aud/exp)
    SE-->>FTS: Transfer complete
    CP->>FTS: Poll job state
    FTS-->>CP: FINISHED
    CF->>RS: Mark transfer done → lock state OK
    NOTE over RS: Rule transitions to OK state
```

### Unmanaged mode

Rucio delegates **long-lived per-file tokens** sized to cover scheduling +
transfer duration. FTS does **no** exchange and **no** refresh — no `TOKEN_PREP`.
Requires `unmanaged_tokens` on submission and `AllowNonManagedTokens` on FTS.

```mermaid
sequenceDiagram
    autonumber
    participant KC as Keycloak (IdP)
    participant CS as Conveyor-Submitter
    participant FTS as FTS3 (OIDC)
    participant SE as Storage (Bearer Auth)
    CS->>KC: Request long-lived source / dest tokens (s, d)
    KC-->>CS: Tokens s, d
    CS->>FTS: Submit job + tokens (s, d), unmanaged flag
    NOTE over FTS: No TOKEN_PREP, no refresh —<br/>tokens used as-is
    FTS->>SE: HTTP COPY (TPC) + tokens s, d
    SE-->>FTS: Transfer complete
```

> Token orchestration follows the design in
> [Rucio Token Workflow Evolution](https://rucio.cern.ch/documentation/files/Rucio_Tokens_v0.1.pdf)
> and [FTS3 Token Support](https://doi.org/10.1051/epjconf/202533701329) (CHEP 2024).
> Rucio acquires separate tokens for FTS authentication and for source/destination
> storage access, then bundles them into the FTS submission. In managed mode FTS
> refreshes the storage-scoped tokens during the transfer; in unmanaged mode the
> token lifetime alone must cover the whole transfer.

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
