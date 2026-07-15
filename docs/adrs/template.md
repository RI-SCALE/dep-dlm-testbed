---
status: proposed | accepted | rejected | deprecated | superseded
date: YYYY-MM-DD
decision-makers:
consulted:
informed:
---

# ADR-NNN: <short decision title, phrased as an action>

## Context and Problem Statement

<What is the issue we're seeing that motivates this decision? 2-5
paragraphs. Describe the problem and, if useful, the question in one
sentence. This section justifies *why a decision is needed at all* — it
should not contain the solution's internal call paths or wiring.>

## Decision Drivers

* <driver 1, e.g. a requirement or constraint>
* <driver 2>
* <...>

## Considered Options

1. <option 1>
2. <option 2>
3. <option 3>

## Decision Outcome

Chosen option: **<option>**, because <justification, 1-3 sentences
tied directly to the decision drivers>.

<Optional: 1-2 short paragraphs of decision-level detail — the shape
of the fix, not its implementation. If a paragraph starts explaining
function names, call orders, or file-by-file wiring, it belongs in a
linked design doc or implementation-notes file instead, not here.>

### Positive Consequences

* <...>

### Negative Consequences

* <...>

## Confirmation

<How do we know the decision was correctly implemented / achieved its
goal? Tests, CI jobs, acceptance criteria.>

## Pros and Cons of the Options

### <option 1>

* Good — <...>
* Bad — <...>

### <option 2>

* Good — <...>
* Bad — <...>

## Evidence / Links

* <links to reproductions, specs, related design docs, tickets>

---

**Note on scope:** an ADR justifies *why* a decision was made. If a
section is explaining *how* the chosen option is wired through the
code (specific functions, DB tables, call sequences, debugging
findings from implementation), move it to a companion design doc or
`implementation-notes.md` and link it from Evidence instead.
