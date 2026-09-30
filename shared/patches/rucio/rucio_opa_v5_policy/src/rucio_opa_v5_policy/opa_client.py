# Licensed under the Apache License, Version 2.0
"""
Thin synchronous OPA REST client — identical in structure to Phase 5.

Environment variables:
    OPA_URL          — base URL of the OPA server  (default: http://localhost:8181)
    OPA_POLICY_PATH  — Rego rule path to query      (default: vo/authz/v5/allow)
    OPA_TIMEOUT      — HTTP timeout in seconds       (default: 2)
"""

import json
import logging
import os
from typing import Any
from urllib.error import URLError
from urllib.request import Request, urlopen

log = logging.getLogger(__name__)

_DEFAULT_URL = "http://localhost:8181"
_DEFAULT_POLICY_PATH = "vo/authz/v5/allow"
_DEFAULT_TIMEOUT = 2


def _opa_url() -> str:
    base = os.environ.get("OPA_URL", _DEFAULT_URL).rstrip("/")
    path = os.environ.get("OPA_POLICY_PATH", _DEFAULT_POLICY_PATH)
    return f"{base}/v1/data/{path}"


def _timeout() -> float:
    return float(os.environ.get("OPA_TIMEOUT", _DEFAULT_TIMEOUT))


def query_opa(input_doc: dict[str, Any]) -> bool:
    """
    POST *input_doc* to the configured OPA policy endpoint.

    Returns True when OPA evaluates the rule to ``true``,
    False for ``false`` and on any connection/timeout error (fail-closed).
    """
    url = _opa_url()
    payload = json.dumps({"input": input_doc}).encode()
    req = Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urlopen(req, timeout=_timeout()) as resp:
            body = json.loads(resp.read())
            result: bool = body.get("result", False)
            log.debug("OPA %s → input=%s result=%s", url, input_doc, result)
            return bool(result)
    except (URLError, TimeoutError, OSError) as exc:
        log.error("OPA unreachable at %s — failing closed. Error: %s", url, exc)
        return False
    except Exception as exc:  # noqa: BLE001
        log.error("Unexpected OPA client error: %s", exc)
        return False
