---
status: proposed
date: 2026-10-07 (revised from 2026-09-04)
decision-makers: DEP DLM testbed
consulted: RI-SCALE
informed:
---

# ADR-005: Usage Reporting for Credits — Rucio as Source, Credits Owned by RI-SCALE

## Context and Problem Statement

RI-SCALE owns the credits and blocks once they are exhausted. DEP's task is
to **report usage**: storage volume and transfer usage. The question is where
the numbers come from and how they reach RI-SCALE, reusing existing Rucio
machinery rather than building new accounting.
Forward-looking: credit management is out of scope for the second DEP release.

Rucio usage is a **logical** view: computed by the Abacus daemons from replica
locks (rules), so replicas without a rule count against no account, and it is
not physically verified. Physical divergence comes in two forms:

- **Lost replicas** (catalog has a file, storage doesn't): found by
  `rucio-auditor` from storage dumps; re-replicated if another copy exists
  (usage unchanged), otherwise removed (usage drops on the next Abacus run).
- **Dark data** (storage has a file the catalog doesn't): never in logical
  usage, so irrelevant to credits; a capacity/cost issue for providers.

Rucio does not scan storage itself: reconciliation needs site-provided dumps
(or an operator-run scanner). Sites can also publish WLCG **SRR**: used/total
bytes per storage share, no file lists, no ownership, but a cheap physical
total. Rucio's Hermes daemon publishes events (e.g. transfer, deletion) to a
message broker.

See also: [concept](../concepts/cms-storage-accounting.md).

## Decision Drivers

* Reuse existing Rucio machinery (Abacus, Hermes, auditor); no new accounting
* Rucio is not a per-request lookup; RI-SCALE blocking must not depend on
  Rucio availability
* Reports stay correct when messages are lost or delayed
* Granularity matching RI-SCALE's needs (account, project or site; open)
* Cheap visibility into logical vs. physical divergence

## Considered Options

1. **Rucio queried on demand** — consumer pulls per-account usage per request
   (previous decision)
2. **Per-storage direct** — integrate each storage endpoint
3. **APEL/EGI accounting feed** — subscribe to existing site feeds
4. **Rucio-sourced push reporting + SRR drift check** — a small reporter
   pushes periodic absolute snapshots (storage) and aggregated Hermes events
   (transfers) to RI-SCALE; per-RSE comparison of Rucio usage with SRR
   `usedsize` triggers dump-based reconciliation
5. **Event-only reporting** — Hermes events as the sole source

## Decision Outcome

Chosen option: **4**.

- **Storage usage:** the reporter reads Abacus-computed usage (account × RSE)
  and pushes timestamped **absolute** snapshots at an agreed cadence. A missed
  report self-heals with the next one.
- **Transfer usage:** Hermes events are aggregated by the reporter and
  reported as **cumulative totals per period**. Events are a low-latency
  input, not the source of truth: totals are periodically reconciled against
  Rucio's own records so lost or duplicated messages are corrected.
- **Blocking:** RI-SCALE's responsibility. If ever wanted on the Rucio side,
  Rucio account limits (quotas) are the native mechanism.
- **Integrity:** SRR drift check and dump-based reconciliation (via
  `rucio-auditor`) unchanged. SRR is native on StoRM/XRootD/dCache/EOS; S3 and
  HPC need a small script.
- **No Rucio changes.**

### Consequences

* Good, because it reuses Abacus, Hermes and the auditor; nothing reinvented
* Good, because RI-SCALE does not query Rucio; it receives reports
* Good, because absolute snapshots and reconciled totals tolerate lost messages
* Good, because drift is detected cheaply via SRR
* Bad, because granularity and cadence are still open, and fixed by RI-SCALE
* Bad, because the reporter is a new (small) component to operate
* Bad, because enforcement lag (usage computation, report cadence, RI-SCALE
  blocking) is unmeasured; blocking is not instantaneous
* Bad, because S3/HPC sites need an SRR script, and reconciliation needs dumps

### Confirmation

* Reporter pushes snapshots in the agreed format; RI-SCALE acknowledges them
* Loss test: drop messages; reported totals converge after reconciliation
* Drift check: Rucio RSE usage vs SRR `usedsize` within threshold per RSE
* Lag measurement: usage change in Rucio to visible in RI-SCALE
* Mapping test: RI-SCALE project ↔ Rucio account across multi-VO setups

## Pros and Cons of the Options

### Rucio queried on demand
* Good, because single source, ownership-aware
* Bad, because Rucio becomes a lookup and a billing-path dependency

### Per-storage direct
* Good, because bytes come straight from storage
* Bad, because N protocols, and storage has no ownership information

### APEL/EGI accounting feed
* Good, because reuses existing site accounting
* Bad, because site-centric; cadence may be too coarse (unverified)

### Rucio-sourced push reporting + SRR drift check
* Good, because reuses Rucio machinery; ownership kept; physical cross-check
* Bad, because a reporter must be built and run; SRR shows *that* totals
  differ, not *which* files

### Event-only reporting
* Good, because low latency
* Bad, because lost, duplicated or late messages silently corrupt totals;
  storage volume is a stock, not a flow, and cannot be rebuilt from events

## More Information

**Dumps.** Path-only dumps suffice for the auditor; ask sites for sizes if
dumps should also back byte totals in disputes.

**Open questions:**
- Granularity (account, project, site) and report cadence required by RI-SCALE
- Push vs. pull delivery to RI-SCALE
- How transfer totals are reconciled against Rucio records
- Which DEP sites can publish SRR and dumps, and at what cadence
- Drift threshold and check cadence
- Measured enforcement lag
