# Design-004: Direct OPA authorization for dep-dlm-testbed (phase6 parity)

- **Status:** Proposed
- **Owner:** DEP DLM testbed
- **Related ADR(s):** opa-policy-package's [adr-001-authz-service.md](https://github.com/mgajek-cern/opa-policy-package/blob/main/docs/adrs/adr-001-authz-service.md), [adr-003-opa-deploy-topology.md](https://github.com/mgajek-cern/opa-policy-package/blob/main/docs/adrs/adr-003-opa-deploy-topology.md) — those explain why direct-vs-service exists and why this testbed starts with direct; this doc is the how for reaching parity with opa-policy-package's phase6.

## Problem

dep-dlm-testbed has no authorization layer today: `shared/config/rucio/` carries no `AUTHZ_MODE`, `OPA_URL`, or `RUCIO_OPA_DEBUG_INPUT` wiring, `shared/patches/rucio/` has no `permission.py`/`oidc.py` authz hooks, and neither compose variant (`docker-compose.managed.yml` / `docker-compose.unmanaged.yml`) starts an OPA container. `shared/config/keycloak/realm.json` has no `entitlements` client scope, no `pep:rucio` scope, and no per-user `entitlements`/`acr` attributes — the claims `authz.rego` reads don't exist in this realm yet.

opa-policy-package's phase6 already solved this exact problem for its own testbed, including both `AUTHZ_MODE=direct` and `AUTHZ_MODE=service`. This testbed only needs the `direct` half: no `authz-service`, no `AUTHZ_SERVICE_URL`/`AUTHZ_OIDC_AUDIENCE` wiring, no `rucio_authz_client` import in `permission.py`, no `authz-service` Keycloak client. Bringing over the service-mode branch would add an unused code path and an extra Keycloak client this testbed doesn't need — every consumer of `has_permission()` here goes through OPA directly.

## Goals

- `has_permission()` in this repo's Rucio server delegates to OPA using the same Rego (`vo.authz.v5`) and the same request-shaping logic as opa-policy-package's `permission.py` (direct branch only).
- Keycloak issues tokens with `entitlements` and `acr` claims, matching what `authz.rego`'s `_is_privileged`/`_has_privilege_level` expect.
- OPA is started, seeded with policy and data, and reachable from `rucio-server` and `rucio-daemons` in both compose variants and (eventually) the Helm/GitOps path.
- The ingest script is testbed-scoped: no phase concept, no multi-phase `PHASES` dict — this repo has one Rucio deployment, not six.

## Non-goals

- `AUTHZ_MODE=service` / authz-service integration. Explicitly deferred — see the backlog item this design closes, which already scoped this out.
- FTS as a direct PEP consumer. Per opa-policy-package's own ADR, FTS is out of scope as a direct authz-service consumer; nothing here changes FTS's existing token-exchange-based access to storage endpoints.
- Storage-endpoint-side authorization (xrootd/Teapot scitoken validation) — unrelated surface, untouched.
- GitOps/Helm parity in this same change. Compose first; Helm/Argo/Flux values get their own follow-up once the compose path is proven (see Sequencing).
- Any Rego content changes. The policy is copied verbatim from opa-policy-package; this design is about wiring, not policy logic.

## Design

**Rego.** Copy `policies/rego/phase6/authz.rego` (`package vo.authz.v5`) verbatim into this repo, e.g. `shared/config/opa/authz.rego`. Same treatment as `shared/config/rucio/*.cfg` — a config asset the testbed owns a copy of, not a package dependency.

**Ingest script.** Adapt the shown `ingest_policies.py` (already testbed-shaped: no `PhaseSpec`/phase selection, single `PHASE` constant) into `shared/scripts/ingest_policies.py`. Two changes from the version shown: drop the `authz_v6` policy_id (that name is a phase6-era leftover in opa-policy-package itself — use `authz_v5` or `rucio_authz` to match the package the Rego declares) and point `--opa-dir` default at the copied file's real location in this repo rather than a `docker/` subpath that doesn't exist here.

**Compose.** Add an `opa` service (`openpolicyagent/opa:1.8.0`, same as opa-policy-package) and an `opa-init` one-shot service (`python:3.11-slim`, waits on `/health`, runs the ingest script, `restart: "no"`) to both `docker-compose.managed.yml` and `docker-compose.unmanaged.yml`. `rucio-server` and `rucio-daemons` gain `OPA_URL=http://opa:8181`, `OPA_POLICY_PATH=vo/authz/v5/allow`, and a `depends_on: opa-init: condition: service_completed_successfully`.

**Keycloak realm.** Merge into `shared/config/keycloak/realm.json`: the `entitlements` client scope (two protocol mappers: `entitlements` list attribute, `acr` attribute) and the `pep:rucio` scope, both attached to the `rucio` client's `defaultClientScopes`. Add `entitlements`/`acr` attributes to existing realm users (`randomaccount`, `adminuser`, or whatever this realm's equivalents are named) so they carry the URNs `authz.rego`'s fallback entitlement map expects. The `authz-service` client and its `aud:authz-service` scope are **not** ported — direct mode needs neither.

**Rucio patches.** Port only the direct-mode code path from the shown `permission.py`: `_has_permission_direct`, `_build_input`, `_token_claims`, `_owned_scopes`, `_rule_facts`, `_serialisable_kwargs`, and `opa_client.py`'s `query_opa`. Drop `AUTHZ_MODE` branching entirely — this repo's `has_permission()` always calls OPA directly, so the `if AUTHZ_MODE == "service"` dispatch and every `rucio_authz_client`/`ApiClient` import in the service-mode half of the file are omitted, not just disabled. `shared/patches/rucio/oidc.py` needs whatever claim-forwarding hook populates `request.environ["token_claims"]` — check whether this repo's existing `oidc.py` patch already does this or whether it needs porting too.

## Touch points

| File / component | Change |
|---|---|
| `shared/config/opa/authz.rego` | New — copied from opa-policy-package's phase6 Rego |
| `shared/scripts/ingest_policies.py` | New — testbed-scoped ingest script |
| `shared/config/keycloak/realm.json` | Add `entitlements`/`pep:rucio` client scopes, user attributes |
| `shared/patches/rucio/permission.py` | New — direct-mode `has_permission()` only |
| `shared/patches/rucio/opa_client.py` (or equivalent) | New — `query_opa()` |
| `shared/patches/rucio/oidc.py` | Check/extend — claim forwarding into `request.environ` |
| `deploy/compose/docker-compose.managed.yml` | Add `opa`, `opa-init`; env vars on `rucio-server`/`rucio-daemons` |
| `deploy/compose/docker-compose.unmanaged.yml` | Same |
| `deploy/compose/docker-compose.managed.ci.yml`, `.unmanaged.ci.yml` | Same, if these don't inherit from the base files |
| `shared/tests/` | New authz-focused tests (see Testing) |

## Fallback / safety behavior

`query_opa()` fails closed on any connection error, timeout, or non-2xx response (returns `False`) — identical to opa-policy-package's behavior, per the module's own docstring. An unreachable or unseeded OPA denies every action rather than permitting; this is a decision already validated upstream and is carried over unchanged. `_rule_facts()` returning `{}` (missing rule, no session, import failure) also denies downstream, since the ownership comparison becomes unsatisfiable — same as upstream.

## Testing

- Unit-level: none needed beyond what opa-policy-package already covers for the Rego and `_build_input`/`_owned_scopes` logic, since that code is ported unchanged.
- Integration: extend `shared/tests/` with an authz-focused test module (mirroring `test_rucio_deletion.py`'s pattern) that exercises at minimum: privileged action as admin-entitled user, denied privileged action as user-entitled user, scope-owned DID creation, foreign-scope denial. Reuse opa-policy-package's `test_phase6_opa.py`/`test_phase6_rucio.py` test bodies as a starting point rather than writing from scratch.
- CI: add the equivalent of opa-init's health/ingest wait to whatever bootstrap CI already waits on (`run-bootstrap-db.sh` or the GitHub Actions job that calls it), so a CI run doesn't race OPA's readiness.

## Sequencing

1. Copy Rego + write the testbed-scoped ingest script; verify `curl localhost:8181/v1/data/vo/authz/v5/allow` responds correctly against hand-crafted input before touching Rucio.
2. Add `opa`/`opa-init` to compose (both variants), no Rucio wiring yet — confirm the containers start and ingest succeeds in isolation.
3. Realm changes: add scopes/attributes, confirm via a minted token that `entitlements`/`acr` claims appear.
4. Port `permission.py`/`opa_client.py`/`oidc.py` patches; wire `OPA_URL`/`OPA_POLICY_PATH` env vars into `rucio-server`/`rucio-daemons`.
5. Integration tests pass locally against compose.
6. Only then: Helm chart / GitOps values parity, as a separate follow-up design or PR.

## Open questions

- Does this repo's existing `shared/patches/rucio/oidc.py` already forward token claims into `request.environ`, or does that need to be added as part of this work? (Needs inspection before Design is finalized — affects Touch points.)
- Policy ID naming: opa-policy-package's own `ingest_policies.py` uses `authz_v6` as the `policy_id` for a Rego file declaring `package vo.authz.v5` — a pre-existing inconsistency there, not something to copy blindly. Confirm what OPA policy ID convention this repo should use.
- Does `dep-dlm-testbed` need `RUCIO_OPA_DEBUG_INPUT` exposed as a compose-level toggle, or is direct env-var override on the container sufficient?
- Are the entitlement URNs (`urn:example:aai.example.org:...`) meant to stay as placeholder/example values here too, or does this testbed have a real AAI namespace it should use instead?
