---
status: proposed
date: 2026-08-12
decision-makers: DEP DLM testbed
consulted:
informed:
---

# ADR-004: Classify Testbed Config by Sensitivity Instead of by Provisioning Tool

## Context and Problem Statement

`testbed-configs` is a `ConfigMap` in the umbrella chart but an
ESO-managed `Secret` in GitOps — it became a Secret only because ESO's
`ExternalSecret` CRD emits Secrets, and this object was carried into
Vault/ESO alongside genuinely sensitive material without a per-file
sensitivity review. The two deployment paths now disagree on the kind
of object backing the same logical config, and — as the companion
design doc's classification table shows — the content itself is mixed:
most of it is non-sensitive, but a couple of files do embed real
credentials.

Should object kind (ConfigMap vs Secret) be decided by a file's actual
sensitivity, or by whichever provisioning pipeline happens to be in
place?

## Decision Drivers

* Non-secret config in a Secret loses `kubectl` visibility and produces
  opaque, unreviewable GitOps diffs.
* RBAC scoped to genuinely sensitive Secrets incidentally also covers
  co-located non-sensitive config.
* Non-secret config shouldn't depend on Vault seeding / ESO sync.

## Considered Options

1. Classify by sensitivity: non-secret files become plain GitOps
   ConfigMaps; sensitive files stay on Vault → ESO → Secret.
2. Status quo: everything stays a Secret regardless of content.
3. Extend ESO to target ConfigMaps: one provisioning mechanism, correct
   object kind per entry.

## Decision Outcome

Chosen option: **1, classify by sensitivity**, because it removes the
RBAC/visibility cost at its source and needs no new tooling — GitOps
already manages plain ConfigMaps elsewhere.

Classification is per file, not per object: a file containing a
credential (a client secret, a password) stays Secret even if the
object it currently lives in is mostly non-sensitive. Unreviewed files
default to Secret — misclassifying non-sensitive as Secret costs
visibility; misclassifying sensitive as ConfigMap costs a credential
leak.

### Positive Consequences

* Non-sensitive config becomes inspectable and diffable.
* RBAC on Secrets now maps to files that actually need protection.

### Negative Consequences

* Two provisioning paths instead of one.
* Every new config file needs an explicit sensitivity call going
  forward.

## Confirmation

`helm template` diff per environment shows no change except object
kind for the reclassified files; existing environment CI passing
post-migration confirms no runtime regression.

## Pros and Cons of the Options

### Option 1: classify by sensitivity

* Good — fixes the RBAC/visibility problem at its source, no new
  tooling.
* Bad — two provisioning paths; ongoing classification discipline.

### Option 2: status quo

* Good — zero migration cost.
* Bad — the problem compounds as more config accumulates.

### Option 3: extend ESO to target ConfigMaps

* Good — keeps one provisioning mechanism.
* Bad — routes non-secret config through Vault for no reason; doesn't
  answer why it needs Vault at all.

## Evidence / Links

* [Design-002: Config/Secret Classification for Testbed
  Config](../design/design-doc-002-config-secret-classification.md) —
  per-file classification table, touch points, sequencing.
* GitOps shared values file, `testbed-configs` comment (source of the
  ConfigMap→Secret drift observation).
