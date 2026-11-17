---
status: proposed
date: 2026-11-17
decision-makers: DEP DLM
consulted: WP4 / ARGO Accounting (GRNET), RI-SCALE
informed:
---

# ADR-010: Report daily transfer usage from Rucio to ARGO Accounting

Supersedes [ADR-005](adr-005-usage-reporting-for-credits.md).

## Context and Problem Statement

RI-SCALE tracks resource consumption as credits in ARGO Accounting, a central
service run by GRNET for WP4. Each DEP is an accounting project, and each
science use case within it is a group. ARGO holds the balances, and the DEPs
enforce any blocking.

ADR-005 assumed DEP DLM would report both storage and transfers to RI-SCALE,
with transfers taken from Hermes events. Agreement with ARGO (16/11/2026)
narrowed this: storage is reported by the destination providers, so DEP DLM
reports **data transferred only**, once per UTC day and per use case, pushed
to ARGO.

Only Rucio knows which account owns a transfer. The question is how to get
attributed daily transfer totals from Rucio into ARGO with the least
infrastructure, in a way another DEP DLM operator can take over.

## Decision Drivers

* Ownership: every byte must be attributed to a DEP and use case
* Daily granularity is the agreed contract; near-real time is not needed
* Lean deployment: no new brokers or stateful services
* Portable: no dependency on Rucio's internal schema or privileged DB access
* Safe re-runs: late data and retries must not double-count
* No Rucio core changes

## Considered Options

1. **Daily reporter pulling Rucio's request history via REST, pushing to ARGO**
2. Hermes event aggregation (ADR-005)
3. Daily reporter querying the Rucio database directly
4. ARGO collecting from Rucio itself

## Decision Outcome

Chosen option: **1**, because it is the only option that keeps ownership,
needs no broker or database access, and stays portable across DEP DLM
operators, at a cost that is acceptable for daily reporting at DEP's scale.

DEP DLM owns a small, stateless reporter shipped with the DEP DLM deployment.
Once a day it computes bytes transferred per DEP and use case and upserts one
record per day into ARGO. A short lookback window corrects late or missed
days. If the history API becomes too slow before Rucio offers a time filter,
option 3 is the stopgap.

### Positive Consequences

* No Hermes, broker or local persistence to operate
* Ownership comes straight from Rucio records
* Re-runs and lookback self-heal missed or late data
* Hand-over to another operator needs only a Rucio account and an ARGO client

### Negative Consequences

* The history API has no time filter, so each run scans more as history grows
* A Rucio account with admin rights is needed
* Attribution depends on transfers running under the use case's own Rucio
  account, which must be agreed and enforced
* Storage drift checks from ADR-005 are no longer covered here

## Confirmation

* Daily records appear in ARGO per installation and `group_id`
* Re-running a day leaves one correct value
* Per day, attributed plus unattributed bytes match Rucio's total
* Staging run against ARGO devel for 1–2 weeks before production

## Pros and Cons of the Options

### Daily REST pull to ARGO

* Good — ownership kept; no new infrastructure; portable; versioned API
* Bad — full history scan per run; needs an admin account

### Hermes event aggregation

* Good — low latency
* Bad — broker and stateful consumer; lost or duplicate events need
  reconciliation anyway; latency not needed for daily reporting

### Direct Rucio database query

* Good — one efficient query per day
* Bad — couples to Rucio's schema; needs DBA access per operator

### ARGO collects from Rucio

* Good — nothing to run on the DEP side
* Bad — ARGO only accepts pushed records; mapping and attribution logic would
  sit outside DEP DLM

## Evidence / Links

* Design: Design-NNN, DEP DLM transfer usage reporter for ARGO Accounting
* [ADR-005](adr-005-usage-reporting-for-credits.md) (superseded)
* Email thread with ARGO (Lena, 16/11/2026): scope, granularity, record format
* [ARGO Accounting Metric API](https://argoeu.github.io/argo-accounting/docs/api/metric)
* [ARGO Accounting Library](https://argoeu.github.io/argo-accounting/docs/guides/accounting-library)
