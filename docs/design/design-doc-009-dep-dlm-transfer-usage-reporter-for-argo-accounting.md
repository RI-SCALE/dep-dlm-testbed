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

A small Python job runs daily as a Kubernetes CronJob in the DEP DLM deployment. It reads finished transfers through Rucio's REST API, maps each owner to a use case through two Rucio account attributes, sums bytes per day and upserts one ARGO metric per installation and `group_id`.

### Daily run

1. Window: previous UTC day plus 2 days lookback for late-archived transfers.
2. For each source/destination RSE pair, page `GET /requests/history/list?request_states=D`; keep rows with `transferred_at` in the window.
3. Map each distinct `account` to `(project_id, group_id)` from its account attributes (one `GET /accounts/{account}/attr/` per account and run); accounts without both are excluded and logged.
4. Sum `bytes` per `(day, project_id, group_id)`.
5. Upsert in ARGO: find the day's metric via `POST /accounting-system/metrics/search` (period, definition, `group_id`), or by listing the installation's metrics; PATCH `value` if found, else POST.

### Transfer source

| Option | When |
| --- | --- |
| **REST history API** | Now. Portable, versioned, no DB access. Cost grows with history size. |
| Upstream time filter on the history API | Propose now; switch when released. |
| Read-only SQL on `requests_history` | Stopgap only if REST becomes too slow first. Couples to schema and needs DBA access. |

### Account mapping

Each Rucio account that owns transfers carries two account attributes, set by a Rucio admin:

| Key | Value | Used for |
| --- | --- | --- |
| `project_id` | DEP identifier | ARGO installation (via config) |
| `group_id` | Use case | ARGO metric `group_id` |

```bash
rucio-admin account add-attribute suc1-prod --key project_id --value dep-a
rucio-admin account add-attribute suc1-prod --key group_id   --value suc1
```

What Rucio master supports (`core/account.py`, `gateway/account.py`, `web/rest/flaskapi/v1/accounts.py`):

- Key and value are strings up to 255 characters; one value per key and account (primary key `account, key`).
- Setting and deleting needs `root` or the `admin` attribute (`perm_add_account_attribute`); reading has no permission check beyond authentication.
- REST: `GET /accounts/{account}/attr/`, `POST`/`DELETE /accounts/{account}/attr/{key}`. `GET /accounts/?group_id=suc1` lists accounts by exact attribute value, useful for audits.
- Attributes are not versioned, and only active accounts are readable: a suspended or deleted account's attributes return `AccountNotFound`.

The mapping lives where the accounts are managed, so no separate file has to be kept in sync. The cost is that a changed attribute also changes days re-sent within the lookback or a backfill.

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
| Reporter → Rucio | Token from DEP IAM (or userpass) for a dedicated Rucio account | `admin` attribute, required by `list_requests_history`; reading account attributes needs none |

ARGO validates the token and maps entitlements to roles. Access per collection is Always, Entity (own records) or Never; Never wins. Secrets come from Vault via ExternalSecrets.

### Architecture and persistence

Hexagonal-lite: a pure core with three ports, no framework. Full clean architecture is overkill for one use case.

| Part | Contents |
| --- | --- |
| Core | `aggregate(transfers, mapping, window) -> list[UsageRecord]` |
| Ports | `TransferSource`, `GroupMapping`, `AccountingSink` |
| Adapters | `RucioRestSource`, `RucioAttributeMapping`, `ArgoSink`, `StdoutSink` (dry-run) |

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
projects:                     # account attribute project_id -> ARGO installation
  dep-a: { installation_id: <from ARGO> }
lookback_days: 2
dry_run: true
```

## Touch points

| File / component | Change |
| --- | --- |
| `dep-dlm-usage-reporter` (new) | Core, ports, adapters, CLI; container image |
| DEP DLM GitOps | CronJob, daily 02:30 UTC; config as ConfigMap |
| Vault / ExternalSecrets | ARGO client credentials; Rucio reporter credentials |
| Rucio | Dedicated reporter account with `admin` attribute; `project_id` and `group_id` attributes on every use case account (one account per use case) |
| ARGO (GRNET) | Provider CERN, 4 installations, metric definition, service client with entitlements |
| Rucio upstream | Proposal: time filter on `/requests/history/list` |
| Docs | Runbook and account mapping, as hand-over for future providers |

## Fallback / safety behavior

- **Invalid config:** fail at start, send nothing.
- **Dry-run by default:** production sets `dry_run: false` explicitly.
- **Unmapped account** (attribute missing, or `project_id` not in config): excluded and logged; job exits with a warning code. Bytes are never guessed into a group.
- **Suspended or deleted account:** its attributes are unreadable, so its late transfers count as unmapped; suspend accounts only after the lookback has passed.
- **ARGO or Rucio unavailable:** retry with backoff, then fail. The next run's lookback re-sends missing days.
- **Partial run or late transfers:** each record is an upsert, so re-runs and lookback correct values without duplicates.
- **Expired token:** fetched fresh each run; refreshed if a run exceeds one hour.
- **Time:** UTC only; a day is `[00:00:00, 24:00:00)`, sent with end `23:59:59Z`.

## Testing

- **Unit:** day boundaries, UTC, lookback, non-`DONE` states excluded, accounts with missing or partial attributes.
- **Integration:** `RucioRestSource` and `RucioAttributeMapping` against a Rucio dev stack (docker-compose) seeded across midnight; `ArgoSink` POST, find and PATCH against ARGO devel.
- **Cross-check:** per day, mapped plus unmapped bytes equal the history total; a mismatch fails staging runs.
- **CI:** lint, type check, unit and integration per merge request; image build and scan.
- **Staging:** 1–2 weeks against ARGO devel before production.

## Sequencing

1. Agree with ARGO: metric definition and unit, installation IDs, entitlements, idempotency, zero-value days.
2. Agree the `project_id` and `group_id` values per DEP and set them as attributes on the use case accounts.
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
- [ ] **Mapping owner:** who sets the `project_id` and `group_id` attributes, and are reassignments allowed once a day has been reported?
- [ ] **Attribute names:** plain `project_id`/`group_id`, or prefixed (e.g. `argo_`) to avoid clashes with other attribute users?
- [ ] **Release scope:** in the second DEP release, or after it as ADR-005 originally planned?

Sources: [ARGO Metric API](https://argoeu.github.io/argo-accounting/docs/api/metric) · [ARGO Accounting Library](https://argoeu.github.io/argo-accounting/docs/guides/accounting-library) · [ARGO Accounting README](https://github.com/ARGOeu/argo-accounting) · [rucio/rucio master](https://github.com/rucio/rucio) · [rucio/rucio account attributes](https://github.com/rucio/rucio/blob/master/lib/rucio/core/account.py)
