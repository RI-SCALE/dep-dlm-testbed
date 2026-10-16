# Licensed under the Apache License, Version 2.0
"""
Unified permission module — dispatches has_permission() to OPA.

Authorization is role-based (ADR-008): the Rego decides from the action and
the token's claims alone. Nothing here reads the Rucio catalog — no scope or
rule ownership, no database lookups. Request kwargs are forwarded only so
OPA's decision log records what each decision was about.
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

from rucio_opa_v1_policy.opa_client import query_opa

log = logging.getLogger(__name__)

# Set RUCIO_OPA_DEBUG_INPUT=1 in the rucio-server environment to log every
# outbound input document at WARNING level.
_DEBUG_INPUT = os.environ.get("RUCIO_OPA_DEBUG_INPUT", "").strip() in ("1", "true", "True")

# Claims forwarded to OPA, as <input.token key>: <claim name>. acr carries
# the MFA level the ODRL tier policy may require; sub/iss/aud identify the
# person in OPA's decision log.
_LIST_CLAIMS: dict[str, str] = {"entitlements": "entitlements"}
_SCALAR_CLAIMS: tuple[str, ...] = ("acr", "aud", "iss", "sub")

# kwargs forwarded to OPA for the decision log only; authz.rego does not
# read them.
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


def has_permission(
    issuer: "InternalAccount",
    action: str,
    kwargs: dict[str, Any],
    *,
    session: "Optional[Session]" = None,
) -> "PermissionResult":
    """Ask OPA whether *issuer* may perform *action*. Fails closed."""
    from rucio.core.permission import PermissionResult

    try:
        input_doc = _build_input(issuer, action, kwargs)
    except Exception:
        log.exception("OPA: input payload generation failed for action=%s", action)
        return PermissionResult(False, "Internal authorization failure: payload construction error")

    if _DEBUG_INPUT:
        log.warning("OPA input for action=%s: %s", action, input_doc)

    try:
        allowed = query_opa(input_doc)
    except Exception as err:
        log.critical("OPA connection failure for action=%s: %s", action, err, exc_info=True)
        return PermissionResult(False, "Authorization engine unreachable (system degraded)")
    return PermissionResult(allowed, "" if allowed else "Access denied by OPA policy validation")


def _build_input(issuer: "InternalAccount", action: str, kwargs: dict[str, Any]) -> dict[str, Any]:
    return {
        "issuer": issuer.external,
        "action": action,
        "token": _token_claims(),
        "kwargs": _serialisable_kwargs(kwargs),
    }


def _request_claims() -> dict[str, Any]:
    """
    The decoded JWT payload for the current request.

    Populated by the patched REST layer (see patches/rucio/). Returns {}
    outside a request context — userpass and daemon calls carry no token.
    """
    try:
        from flask import has_request_context, request
    except ImportError:
        return {}
    if not has_request_context():
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
    return token


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


def _serialisable_kwargs(kwargs: dict[str, Any]) -> dict[str, Any]:
    return {key: _externalise(kwargs[key]) for key in _PASSTHROUGH_KEYS if key in kwargs}
