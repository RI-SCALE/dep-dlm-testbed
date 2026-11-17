# Design-009: DEP DLM transfer usage reporter for ARGO Accounting

- **Status:** Proposed
- **Owner:** DEP DLM
- **Related ADR(s):** [ADR-010](../adrs/adr-010-report-transfer-usage-to-argo.md) (report daily transfer usage to ARGO), superseding [ADR-005](../adrs/adr-005-usage-reporting-for-credits.md)

## Problem

Nothing reports DEP DLM transfer usage to ARGO Accounting. ARGO (GRNET, WP4) expects one JSON record per UTC day and use case (`group_id`), pushed to its REST API; storage is out of scope (agreed 16/11). Rucio has the data, but no output fits as is (`rucio/rucio` master, `lib/rucio/`):

- **`GET /requests/history/list`** returns `account`, `bytes`, `transferred_at`, but has no time filter, takes one source/destination RSE (or site) pair per call, pages by unordered `offset`/`limit`, and needs an `admin` account (`web/rest/flaskapi/v1/requests.py`, `core/permission/generic.py`).
- **Aggregates drop the owner:** `transfer_stats`, `GET /requests/metrics` and Hermes' Influx output have no account.
- **Hermes events** carry the owner but need a broker and a stateful consumer, which daily reporting doesn't justify.

## Goals

- Bytes transferred per UTC day, per DEP and `group_id`, in ARGO.
- One stateless daily job in the DEP DLM deployment; no Rucio core change.
- Safe re-runs: a day sent twice yields one correct value.
- Portable: another DEP DLM operator can run it with a Rucio account and an ARGO client.

## Non-goals

- Storage usage (reported by TUBITAK and TU Wien).
- Credits and blocking (ARGO holds balances; DEPs enforce).
- Near-real-time reporting, Hermes or a broker.
- Per-user accounting (`user_id`).

## Design

A small Python job runs daily as a Kubernetes CronJob in the DEP DLM deployment. It reads finished transfers through Rucio's REST API, maps owners to use cases, sums bytes per day and upserts one ARGO metric per installation and `group_id`.

### Daily run

1. Window: previous UTC day plus 2 days lookback for late-archived transfers.
2. For each source/destination RSE pair, page `GET /requests/history/list?request_states=D`; keep rows with `transferred_at` in the window.
3. Map `account` to `(dep, group_id)` from config; unmapped accounts are excluded and logged.
4. Sum `bytes` per `(day, dep, group_id)`.
5. Upsert in ARGO: find the day's metric via `POST /accounting-system/metrics/search` (period, definition, `group_id`), or by listing the installation's metrics; PATCH `value` if found, else POST.

### Transfer source

| Option | When |
| --- | --- |
| **REST history API** | Now. Portable, versioned, no DB access. Cost grows with history size. |
| Upstream time filter on the history API | Propose now; switch when released. |
| Read-only SQL on `requests_history` | Stopgap only if REST becomes too slow first. Couples to schema and needs DBA access. |

### Request shape (ARGO)

One POST per metric (no bulk endpoint), as in the [Metric API](https://argoeu.github.io/argo-accounting/docs/api/metric) and the [Python library](https://argoeu.github.io/argo-accounting/docs/guides/accounting-library):

```json
POST /accounting-system/installations/{installation_id}/metrics
Authorization: Bearer <jwt>

{
  "metric_definition_id": "<from ARGO>",
  "time_period_start": "2026-11-16T00:00:00Z",
  "time_period_end": "2026-11-16T23:59:59Z",
  "value": 734003200,
  "group_id": "suc1"
}
```

One installation per DEP (CERN appears 4 times). Updates use `PATCH /installations/{id}/metrics/{metric_id}`. The ARGO adapter wraps `argo-acc-library` (`installations[id].metrics.add(...)`).

### Identity and permissions

| Call | Credential | Permission |
| --- | --- | --- |
| Reporter → ARGO | JWT via OAuth 2.0 client credentials (client from GRNET); valid 1 hour, fetched each run | Role granted through **entitlements in the token**: Metric create, read, update on own entities, scoped to the DEP installations |
| Reporter → Rucio | Token from DEP IAM (or userpass) for a dedicated Rucio account | `admin` attribute, required by `list_requests_history` |

ARGO validates the token and maps entitlements to roles. Access per collection is Always, Entity (own records) or Never; Never wins. Secrets come from Vault via ExternalSecrets.

### Architecture and persistence

Hexagonal-lite: a pure core with three ports, no framework. Full clean architecture is overkill for one use case.

| Part | Contents |
| --- | --- |
| Core | `aggregate(transfers, mapping, window) -> list[UsageRecord]` |
| Ports | `TransferSource`, `GroupMapping`, `AccountingSink` |
| Adapters | `RucioRestSource`, `YamlMapping`, `ArgoSink`, `StdoutSink` (dry-run) |

No persistence: Rucio is the source of truth and ARGO holds what was sent, so a re-run recomputes and upserts.

### Config

```yaml
argo:
  endpoint: <ARGO instance>
  metric_definition_id: <from ARGO>
  credentials: vault:dep-dlm/argo-reporter
rucio:
  host: <Rucio server>
  credentials: vault:dep-dlm/rucio-reporter
deps:
  dep-a: { installation_id: <from ARGO> }
groups:                       # Rucio account -> DEP and use case
  suc1-prod: { dep: dep-a, group_id: suc1 }
lookback_days: 2
dry_run: true
```

## Touch points

| File / component | Change |
| --- | --- |
| `dep-dlm-usage-reporter` (new) | Core, ports, adapters, CLI; container image |
| DEP DLM GitOps | CronJob, daily 02:30 UTC; config as ConfigMap |
| Vault / ExternalSecrets | ARGO client credentials; Rucio reporter credentials |
| Rucio | Dedicated reporter account with `admin` attribute; one account per use case convention |
| ARGO (GRNET) | Provider CERN, 4 installations, metric definition, service client with entitlements |
| Rucio upstream | Proposal: time filter on `/requests/history/list` |
| Docs | Runbook and account mapping, as hand-over for future providers |

## Fallback / safety behavior

- **Invalid config:** fail at start, send nothing.
- **Dry-run by default:** production sets `dry_run: false` explicitly.
- **Unmapped account:** excluded and logged; job exits with a warning code. Bytes are never guessed into a group.
- **ARGO or Rucio unavailable:** retry with backoff, then fail. The next run's lookback re-sends missing days.
- **Partial run or late transfers:** each record is an upsert, so re-runs and lookback correct values without duplicates.
- **Expired token:** fetched fresh each run; refreshed if a run exceeds one hour.
- **Time:** UTC only; a day is `[00:00:00, 24:00:00)`, sent with end `23:59:59Z`.

## Testing

- **Unit:** day boundaries, UTC, lookback, non-`DONE` states excluded, unmapped accounts.
- **Integration:** `RucioRestSource` against a Rucio dev stack (docker-compose) seeded across midnight; `ArgoSink` POST, find and PATCH against ARGO devel.
- **Cross-check:** per day, mapped plus unmapped bytes equal the history total; a mismatch fails staging runs.
- **CI:** lint, type check, unit and integration per merge request; image build and scan.
- **Staging:** 1–2 weeks against ARGO devel before production.

## Sequencing

1. Agree with ARGO: metric definition and unit, installation IDs, entitlements, idempotency, zero-value days.
2. Agree the Rucio account to `group_id` convention per DEP.
3. Get the ARGO client (GRNET) and the Rucio reporter account; store both in Vault.
4. Build core, REST source and dry-run sink; validate against real data.
5. Add `ArgoSink`; run in staging against ARGO devel.
6. Deploy the production CronJob; backfill from the agreed start date.
7. Propose the upstream time filter; switch the source adapter when released.

## Open questions

- [ ] **ARGO entitlements:** which entitlement grants metric create and update for the DEP installations?
- [ ] **Idempotency:** does ARGO reject or merge overlapping periods, or is find-then-PATCH expected? Can search filter on installation\_id, metric\_definition\_id and group\_id with equality? Can a metric carry a client-set external ID (e.g. day plus group\_id) to make re-sends idempotent?
- [ ] **Which transfers count:** `DONE` only; multi-hop intermediate hops; direction needed?
- [ ] **Unit and zero days:** bytes or a larger unit; send `0` on days without transfers?
- [ ] **Four DEPs:** separate Rucio instances or VOs, or one instance with an account-to-DEP mapping?
- [ ] **Scale:** history size and retention at CERN, to judge when REST gets too slow.
- [ ] **Mapping owner:** who maintains the account to `group_id` mapping?
- [ ] **Release scope:** in the second DEP release, or after it as ADR-005 originally planned?

Sources: [ARGO Metric API](https://argoeu.github.io/argo-accounting/docs/api/metric) · [ARGO Accounting Library](https://argoeu.github.io/argo-accounting/docs/guides/accounting-library) · [ARGO Accounting README](https://github.com/ARGOeu/argo-accounting) · [rucio/rucio master](https://github.com/rucio/rucio)
