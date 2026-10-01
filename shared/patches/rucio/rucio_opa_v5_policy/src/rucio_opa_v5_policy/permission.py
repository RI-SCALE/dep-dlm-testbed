# Licensed under the Apache License, Version 2.0
"""
Unified permission module — dispatches has_permission()
"""

import logging
import os
from enum import Enum
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from typing import Optional

    from rucio.common.types import InternalAccount
    from rucio.core.permission import PermissionResult
    from sqlalchemy.orm import Session

log = logging.getLogger(__name__)

# Set RUCIO_OPA_DEBUG_INPUT=1 in the rucio-server environment to log every
# outbound request/input document at WARNING level, in either mode.
_DEBUG_INPUT = os.environ.get("RUCIO_OPA_DEBUG_INPUT", "").strip() in ("1", "true", "True")

# Actions whose kwargs identify a rule by id and nothing else. The owning
# account lives on the `rules` row, not in kwargs, so it has to be fetched.
# Shared by both modes.
_RULE_ID_ACTIONS: frozenset[str] = frozenset({"del_rule", "update_rule"})


def has_permission(
    issuer: "InternalAccount",
    action: str,
    kwargs: dict[str, Any],
    *,
    session: "Optional[Session]" = None,
) -> "PermissionResult":
    return _has_permission_direct(issuer, action, kwargs, session=session)


# ════════════════════════════════════════════════════════════════
# Shared helpers — identical under both modes
# ════════════════════════════════════════════════════════════════


def _externalise(value: Any) -> Any:
    if hasattr(value, "external"):
        return value.external
    if isinstance(value, Enum):
        # Rucio passes DIDType/RSEType members inside dids[] and parameter
        # dicts. json.dumps cannot serialise them, and an unserialisable
        # input document fails the whole decision closed.
        return value.value
    if isinstance(value, dict):
        return {k: _externalise(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_externalise(v) for v in value]
    return value


def _rule_facts(
    action: str,
    kwargs: dict[str, Any],
    session: "Optional[Session]" = None,
) -> dict[str, str]:
    """
    The rule's owning account and target scope, for rule-id-keyed actions.

    Returns {} when the facts cannot be established — a missing rule, an
    unusable id, or no session. Both modes' downstream comparison is then
    undefined and denies, which is the intended failure direction.
    """
    if action not in _RULE_ID_ACTIONS or session is None:
        return {}

    rule_id = kwargs.get("rule_id")
    if not rule_id:
        return {}

    try:
        from rucio.common.exception import RuleNotFound
        from rucio.core.rule import get_rule
    except ImportError:
        if _DEBUG_INPUT:
            log.warning("authz: rucio.core.rule not importable")
        return {}

    try:
        row = get_rule(rule_id, session=session)
    except RuleNotFound:
        # An ordinary outcome, not a fault: nothing to own, so nothing to
        # compare against.
        if _DEBUG_INPUT:
            log.warning("authz: rule %s not found", rule_id)
        return {}
    except Exception:
        # A fault. Still denies, but never silently — otherwise a transient
        # DB error is indistinguishable from "you don't own this rule".
        log.exception("authz: could not resolve rule %s", rule_id)
        return {}

    facts = {
        "rule_owner": row["account"].external,
        "rule_scope": row["scope"].external,
    }

    if _DEBUG_INPUT:
        log.warning("authz: rule=%s facts=%s", rule_id, facts)

    return facts


# ════════════════════════════════════════════════════════════════
# query OPA directly (former phase 6 path)
# ════════════════════════════════════════════════════════════════

from rucio_opa_v5_policy.opa_client import query_opa  # noqa: E402

# Claims forwarded to OPA, as <input.token key>: <claim name>.
_LIST_CLAIMS: dict[str, str] = {"entitlements": "entitlements"}
_SCALAR_CLAIMS: tuple[str, ...] = ("acr", "aud", "iss", "sub")

_PASSTHROUGH_KEYS: frozenset[str] = frozenset(
    {
        "account",
        "locked",
        "rse_expression",
        "source_rse_expression",
        "rule_id",
        "options",
        "rse",
        "parameters",
        "parameter",
        "rse_id",
        "scheme",
        "hostname",
        "data",
        "scope",
        "name",
        "dids",
        "attachments",
        "files",
    }
)

# Keys under which a nested protocol/parameter dict might carry `scheme` —
# Rucio's add_protocol API passes the scheme/hostname/port/prefix bundled
# into one dict, not as flat kwargs. Checked, in order, for a top-level
# `scheme` substitute so `input.kwargs.scheme` in the Rego keeps working.
_NESTED_SCHEME_CONTAINERS = ("parameter", "parameters", "data")

# kwargs keys holding a single scope, and keys holding a list of dicts that
# each carry one. `rule_scope` is not a gateway kwarg — it is resolved by
# _rule_facts() and merged in before ownership is computed.
_SCOPE_KEYS: tuple[str, ...] = ("scope", "rule_scope")
_SCOPE_CONTAINERS: tuple[str, ...] = ("dids", "attachments", "files")


def _has_permission_direct(
    issuer: "InternalAccount",
    action: str,
    kwargs: dict[str, Any],
    *,
    session: "Optional[Session]" = None,
) -> "PermissionResult":
    from rucio.core.permission import PermissionResult

    try:
        input_doc = _build_input(issuer, action, kwargs, session)
    except Exception:
        log.exception("OPA: input payload generation failed for action=%s", action)
        return PermissionResult(False, "Internal authorization failure: payload construction error")

    if _DEBUG_INPUT:
        log.warning("OPA input for action=%s: %s", action, input_doc)

    try:
        opa_response = query_opa(input_doc)
        if isinstance(opa_response, bool):
            allowed = opa_response
            reason = "" if allowed else "Access denied by OPA policy validation"
        else:
            allowed = getattr(opa_response, "allowed", False)
            reason = getattr(opa_response, "reason", "Access denied by OPA policy validation")
        return PermissionResult(allowed, reason)
    except Exception as network_err:
        log.critical(
            "OPA connection infrastructure failure for action=%s: %s",
            action,
            str(network_err),
            exc_info=True,
        )
        return PermissionResult(False, "Authorization engine unreachable (system degraded)")


def _build_input(
    issuer: "InternalAccount",
    action: str,
    kwargs: dict[str, Any],
    session: "Optional[Session]" = None,
) -> dict[str, Any]:
    rule_facts = _rule_facts(action, kwargs, session)

    serialisable = _serialisable_kwargs(kwargs)
    serialisable.update(rule_facts)

    # _scopes_in() reads the raw kwargs, which carry no rule_scope — merge
    # the resolved facts in first so a rule's target scope is resolved by
    # the same single is_scope_owner() pass as everything else.
    serialisable["owned_scopes"] = _owned_scopes(issuer, {**kwargs, **rule_facts}, session)

    return {
        "issuer": issuer.external,
        "action": action,
        "token": _token_claims(),
        "kwargs": serialisable,
    }


def _request_claims() -> dict[str, Any]:
    """
    The decoded JWT payload for the current request.

    Populated by the patched REST layer (see patches/rucio/). Returns {}
    outside a request context, which unit tests rely on.
    """
    try:
        from flask import has_request_context, request
    except ImportError:
        if _DEBUG_INPUT:
            log.warning("authz: flask not importable")
        return {}
    if not has_request_context():
        if _DEBUG_INPUT:
            log.warning("authz: no flask request context")
        return {}
    return request.environ.get("token_claims") or {}


def _as_list(value: Any) -> list[str]:
    """Normalise a claim that may be a list or a space-separated string."""
    if value is None:
        return []
    if isinstance(value, str):
        return value.split()
    return list(value)


def _token_claims() -> dict[str, Any]:
    claims = _request_claims()
    token: dict[str, Any] = {
        key: _as_list(claims.get(claim)) for key, claim in _LIST_CLAIMS.items()
    }
    for key in _SCALAR_CLAIMS:
        if key in claims:
            token[key] = claims[key]
    if _DEBUG_INPUT:
        log.warning("authz: claim_keys=%s forwarded=%s", sorted(claims), token)
    return token


def _scopes_in(issuer: "InternalAccount", kwargs: dict[str, Any]) -> list[Any]:
    """Every distinct scope named by this request, as InternalScope."""
    from rucio.common.types import InternalScope

    found = []
    candidates = []
    for key in _SCOPE_KEYS:
        if key in kwargs:
            candidates.append(kwargs[key])
    for container in _SCOPE_CONTAINERS:
        for entry in kwargs.get(container) or []:
            if isinstance(entry, dict) and "scope" in entry:
                candidates.append(entry["scope"])

    for value in candidates:
        if value is None:
            continue
        scope = value if hasattr(value, "internal") else InternalScope(value, vo=issuer.vo)
        if scope not in found:
            found.append(scope)
    return found


def _owned_scopes(
    issuer: "InternalAccount",
    kwargs: dict[str, Any],
    session: "Optional[Session]" = None,
) -> list[str]:
    """The subset of this request's scopes that the issuer owns."""
    named = any(k in kwargs for k in _SCOPE_KEYS) or any(k in kwargs for k in _SCOPE_CONTAINERS)
    scopes = _scopes_in(issuer, kwargs) if named else []
    if not scopes or session is None:
        return []

    try:
        from rucio.core.scope import is_scope_owner
    except ImportError:
        if _DEBUG_INPUT:
            log.warning("authz: rucio.core.scope not importable")
        return []

    owned = [
        scope.external
        for scope in scopes
        if is_scope_owner(scope=scope, account=issuer, session=session)
    ]
    if _DEBUG_INPUT:
        log.warning("authz: checked=%s owned=%s", [s.external for s in scopes], owned)
    return owned


def _serialisable_kwargs(kwargs: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key in _PASSTHROUGH_KEYS:
        if key in kwargs:
            result[key] = _externalise(kwargs[key])

    if "scheme" not in result:
        for container_key in _NESTED_SCHEME_CONTAINERS:
            nested = kwargs.get(container_key)
            if isinstance(nested, dict) and "scheme" in nested:
                result["scheme"] = nested["scheme"]
                break
    return result
