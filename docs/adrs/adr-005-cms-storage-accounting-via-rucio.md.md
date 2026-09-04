---
status: proposed
date: 2026-09-04
decision-makers: DEP DLM testbed
consulted:
informed:
---

# CMS Storage Accounting via Rucio (Central) vs Per-Storage

## Context and Problem Statement

The Credit Management System (CRMS) requires storage-usage accounting to feed CTPM (cost translation), CDPM (credit distribution), and CAR (allocation registry). Two architectural options exist for the source of that accounting: query Rucio centrally (Rucio aggregates and reconciles across storages), or query each e-infra storage endpoint directly.

How should CRMS obtain authoritative, reconciled storage-usage accounting data?

See also: [concept](../concepts/cms-storage-accounting.md).

## Decision Drivers

* Single, consistent accounting truth across heterogeneous storage backends
* Identity model that matches CRMS's user/project granularity
* Minimize integration surface (one API vs. N storage protocols)
* Reconciliation between logical (catalog) and physical (storage) views
* Auditability and dispute resolution for billing
* Avoid making CRMS depend on Rucio's availability for billing-critical operations

## Considered Options

1. **Rucio-central with Auditor reconciliation** — CRMS queries Rucio's REST API; Auditor reconciles against storage dumps periodically
2. **Per-storage direct** — CRMS integrates with each storage endpoint individually
3. **Hybrid** — Rucio is primary source; CRMS falls back to per-storage queries for drift investigation
4. **APEL/EGI accounting feed** — CRMS subscribes to existing site-published accounting streams

## Decision Outcome

Chosen option: **"Rucio-central with Auditor reconciliation"**, because it:

- Provides a single accounting truth across N heterogeneous storage backends
- Matches CRMS's identity granularity (Rucio knows account → DID → RSE; storage knows only paths and bytes)
- Reuses existing infrastructure (`rse_usage`, `account_usage`, `rucio-auditor`) without new daemons
- Exposes one stable, versioned REST API instead of N storage-specific integrations
- Preserves the e-infra storage layer as an unchanged, opaque resource provider

**NOTE:**
- Rucio's accounting source is the Abacus-maintained `rse_usage` / `account_usage` tables. Reconciliation against physical storage is a separate, distributed workflow (dumper → auditor → quarantined_replicas) that runs at storage-dump cadence and surfaces drift as metadata on the accounting feed.
- `rse_usage` is keyed by `(rse_id, source)`, so multiple usage views per RSE coexist (catalog-derived + storage-reported). `account_usage` is catalog-derived only.

### Implementation

**No schema changes.** Rucio's `rse_usage` and `account_usage` tables already maintain the data CRMS needs. The Abacus daemons (`rucio-abacus-account`, `rucio-abacus-rse`) keep them current.

**Reconciliation.** `rucio-auditor` consumes dumps produced by `rucio-dumper` (HDFS, SRM dumps, S3 list) and reconciles them against the catalog. Cadence may need tuning per CRMS's freshness requirements.

**API surface.** Either reuse existing `/accounts/{name}/usage` and `/rses/{rse}/usage` endpoints, or introduce a CRMS-shaped aggregation endpoint that returns:
- Per-account / per-RSE usage (bytes, file count)
- Last reconciliation timestamp
- Reconciliation status (drift detected? amount?)

**CRMS-side integration.** RUEIT component implements a Rucio API client. CTPM consumes the feed.

**Multi-VO scoping.** CRMS project ↔ Rucio account/scope mapping must be explicit, configured per deployment.

For sequences, see [runtime views in the CMS storage accounting concept](../concepts/cms-storage-accounting.md).

### Consequences

* Good, because CRMS sees one consistent answer regardless of storage backend heterogeneity
* Good, because no new daemons required — reuses Abacus (accounting) + Dumper/Auditor (reconciliation)
* Good, because integration surface is one stable REST API, not N storage protocols
* Good, because Rucio's identity model (account/scope/DID) maps cleanly to CRMS's project model
* Good, because reconciliation between logical and physical views is already a Rucio concern
* Bad, because CRMS billing now depends on Rucio API availability — must be factored into Rucio's SLO
* Bad, because reconciliation lag means billing reflects state at last Auditor run, not real-time
* Bad, because drift between logical and physical requires a policy decision (bill on Rucio's view or storage's?) — deferred to operational rule
* Neutral, because Rucio's accounting tables already exist; this ADR formalizes their use as the CRMS source

### Confirmation

* Integration test: CRMS RUEIT queries Rucio API, receives expected usage shape with reconciliation timestamps
* Reconciliation test: synthetic drift (delete file on storage, leave in catalog) is detected by Auditor and surfaced to CRMS within configured SLA
* Mapping test: CRMS project ↔ Rucio account translation produces correct aggregations across multi-VO setups
* Performance test: API response time under realistic CRMS query load remains within Rucio's API SLO (see [quality-requirements.md](../10-quality-requirements/quality-requirements.md))

## Pros and Cons of the Options

### Rucio-central with Auditor reconciliation

* Good, because single source of truth
* Good, because identity-model match
* Good, because reuses existing components
* Good, because one stable API
* Bad, because creates Rucio availability dependency for billing
* Bad, because freshness limited by Auditor cadence

### Per-storage direct

* Good, because authoritative bytes (storage knows what's actually there)
* Good, because removes Rucio from billing critical path
* Bad, because CRMS must integrate with N heterogeneous storage protocols
* Bad, because storage doesn't know user/project ownership at CRMS granularity
* Bad, because no cross-storage reconciliation — each site reports its own view
* Bad, because dark data (on storage, not in Rucio) appears in billing without context

### Hybrid

* Good, because Rucio is primary; per-storage fallback for investigation
* Good, because preserves option to drill down on disputes
* Bad, because two integration paths to maintain
* Bad, because policy ambiguity — when do you fall back? Who decides?
* Neutral, because can be added later on top of Option 1 without re-architecting

### APEL/EGI accounting feed

* Good, because reuses existing site-published accounting
* Good, because no Rucio-specific integration needed
* Bad, because APEL records are storage-centric, not user/project-centric — same identity-model gap as Option 2
* Bad, because cadence is daily/weekly, too coarse for credit billing
* Bad, because no reconciliation against Rucio's logical view — drift invisible

## More Information

**Why not "central" at the storage layer?** A federation broker that aggregates storage accounting across sites would face the same identity-model gap as Option 2. Rucio is the only system with the user/project knowledge CRMS needs.

**Auditor cadence tradeoff.** Faster reconciliation means fresher billing data but more storage-side load (dumps are expensive). Start with daily; tune based on CRMS-stated freshness requirements.

**Drift policy is operational, not architectural.** Whether drift is billed on Rucio's view or storage's view is a policy decision per CRMS deployment. The architecture exposes both numbers; the rule is set elsewhere.

**Open questions deferred to follow-up:**
- Real-time event push via `rucio-hermes` for time-sensitive credit operations
- CRMS handling of tape accounting (which has inherent lag)
- Failure mode when Rucio API is unavailable mid-billing-cycle
