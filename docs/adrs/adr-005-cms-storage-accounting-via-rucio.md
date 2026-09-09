---
status: proposed
date: 2026-09-04
decision-makers: DEP DLM testbed
consulted:
informed:
---

# ADR-005: CRMS Storage Accounting — Rucio Logical Usage vs Per-Storage Accounting

## Context and Problem Statement

The Credit Management System (CRMS) requires storage-usage accounting
to feed CTPM, CDPM, and CAR. Two options exist: query Rucio centrally,
or query each e-infra storage endpoint directly.

Rucio exposes usage data via existing, client-wrapped REST
endpoints — integration cost is low. That usage is a **logical**
view (what the catalog believes is allocated), not physically
verified. Divergence is handled by two independent mechanisms with
different relevance to billing:

- **Bad-replica correction** (catalog thinks a file exists, storage
  doesn't) — this is the mechanism that actually corrects usage
  numbers over time, and it's **already externally readable** via
  `list_bad_replicas_status`.
- **Quarantined replicas / DARK files** (storage has a file the
  catalog never knew about) — these were never counted in the usage
  number, so they're irrelevant to billing accuracy. No endpoint
  needed for this.

No new Rucio-side work is required to answer "will usage numbers
self-correct." They already will, via bad-replica correction, at an
unmeasured lag.

See also: [concept](../concepts/cms-storage-accounting.md).

## Decision Drivers

* Consistent logical accounting view across heterogeneous storage
* Identity model matching CRMS's user/project granularity
* Minimize integration surface (one API vs. N storage protocols)
* Visibility into divergence between logical and physical views
* Auditability and dispute resolution for billing
* Avoid making CRMS depend on Rucio's availability for billing

## Considered Options

1. **Rucio-central, logical usage, existing correction signal** — CRMS
   queries Rucio's usage API; bad-replica status (already readable)
   gives visibility into corrections in flight
2. **Per-storage direct** — CRMS integrates with each storage endpoint
   individually
3. **Hybrid** — Rucio primary, per-storage fallback for disputes
4. **APEL/EGI accounting feed** — subscribe to existing site feeds

## Decision Outcome

Chosen option: **"Rucio-central, logical usage, existing correction
signal"**. No new Rucio endpoint is needed — the usage endpoints and
the bad-replica status endpoint already exist and cover what CRMS
needs.

**NOTE:** Usage numbers are catalog-derived, not physically verified.
They self-correct over time when the catalog is found to be wrong
(bad-replica → cleanup daemon → catalog update → next usage-count
run), but the actual lag through that chain has not been measured.
Quarantined replicas (DARK files) were investigated as a possible
drift signal but don't affect billing — they were never in the usage
number to begin with. No design doc / new endpoint is needed for
this decision.

### Consequences

* Good, because CRMS gets one consistent logical view
* Good, because zero new Rucio work — everything needed already exists
* Good, because Rucio's identity model maps to CRMS's project model
* Bad, because CRMS billing depends on Rucio API availability
* Bad, because usage-correction lag (bad-replica → catalog update →
  next count) is real but unmeasured
* Neutral, because this ADR formalizes reuse of existing endpoints,
  no build required

### Confirmation

* Integration test: CRMS queries usage + bad-replica-status endpoints,
  receives expected shapes
* Lag measurement: observe actual time from a bad-replica detection to
  the corrected usage number appearing, to inform whether per-storage
  lookups are ever needed
* Mapping test: CRMS project ↔ Rucio account translation is correct
  across multi-VO setups

## Pros and Cons of the Options

### Rucio-central, logical usage, existing correction signal

* Good, because single source, zero new work
* Good, because identity-model match
* Bad, because correction lag is unmeasured
* Bad, because Rucio availability dependency for billing

### Per-storage direct

* Good, because bytes come directly from storage
* Good, because removes Rucio from billing critical path
* Bad, because N storage protocols to integrate
* Bad, because storage doesn't know account/project ownership
* Bad, because no cross-storage reconciliation

### Hybrid

* Good, because per-storage fallback available for disputes
* Bad, because two paths to maintain, fallback trigger is ambiguous
* Neutral, because can be added later without re-architecting

### APEL/EGI accounting feed

* Good, because reuses existing site-published accounting
* Bad, because storage/site-centric, not account/project-centric
* Bad, because cadence may be too coarse — unverified against CRMS SLA

## More Information

**Per-storage lookups: revisit only if lag is unacceptable.** Rather
than defaulting to per-storage integration, measure the actual
bad-replica → corrected-usage lag first. If it's small, Rucio-central
is sufficient as-is. If large, per-storage lookups may be worth
reserving for dispute-resolution escalation, not as a default path.

**Billing policy remains deployment-level.** Whether CRMS bills on the
logical number as-is, or waits for correction, is a CRMS policy
decision. The architecture supplies the logical number and (if wanted)
bad-replica status; it doesn't fold one into the other.

**Open questions:**
- Measure actual bad-replica correction lag (auditor → cleanup daemon
  → catalog update → next usage count)
- Real-time event push for time-sensitive credit operations
- Failure mode when Rucio API is unavailable mid-billing-cycle
- Whether per-storage lookup is worth building as a dispute-escalation
  path, once lag is measured
