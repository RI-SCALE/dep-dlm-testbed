"""
test_authz_personas.py — verifies authz.rego's entitlement-tier decisions
for the DEP persona accounts (design-008 / design-doc-004).

Modeled directly on opa-policy-package's test_phase6_rucio.py: uses
PRIVILEGED_PATH (set_local_account_limit) rather than add_rse, since that
action is gated purely on _is_privileged with no RSE-naming allowlist
entanglement, and checks deny_reason()'s ExceptionClass rather than status
code alone — AccessDenied means the policy denied; CannotAuthenticate means
the token never reached has_permission() at all (usually a scope/audience
mismatch against [oidc] expected_scope/expected_audience).

rucio_rest/deny_reason are defined locally rather than in conftest.py: no
other test module needs bare-token REST access yet (everything else goes
through the fixed rucio_client / webdav_* / make_client() identity). Promote
these to conftest.py if a second file needs them.
"""

import os
import time

import pytest
import requests

from conftest import (
    OIDC_CLIENT_ID,
    OIDC_CLIENT_SECRET,
    OIDC_TOKEN_URL,
    fetch_token_password,
)

pytestmark = pytest.mark.skipif(
    os.environ.get("OIDC_GRANT_TYPE", "password") != "password",
    reason=(
        "test_authz_personas.py exercises five distinct persona identities "
        "via password-grant tokens minted against a local Keycloak realm "
        "(see AUTHZ_TEST_USERS in init-testbed.sh). client_credentials "
        "profiles (egi-dev, ls-aai-dev) authenticate as a single service "
        "client with no per-user distinction, so persona-level entitlement "
        "checks have no equivalent there — this test only runs under "
        "SCOPE_PROFILE=local."
    ),
)

# ── Local REST helpers ──────────────────────────────────────────────────

RUCIO_REST_URL = os.environ.get("RUCIO_URL", "http://rucio-server").rstrip("/")


def rucio_rest(path, token, method="GET", body=None, timeout=30):
    """Authenticated Rucio REST call with a raw bearer token."""
    headers = {"X-Rucio-Auth-Token": token}
    if body is not None:
        headers["Content-Type"] = "application/json"
    return requests.request(
        method,
        f"{RUCIO_REST_URL}{path}",
        headers=headers,
        json=body,
        verify=False,
        timeout=timeout,
    )


def deny_reason(resp):
    """(ExceptionClass, ExceptionMessage) from a Rucio error response."""
    return resp.headers.get("ExceptionClass"), resp.headers.get("ExceptionMessage")


# ── Personas ─────────────────────────────────────────────────────────────

# Must match AUTHZ_TEST_USERS in shared/scripts/init-testbed.sh.
PERSONAS = {
    "adminuser": "admin123",
    "depoperator": "secret",
    "dependuser": "secret",
    "modeldeveloper": "secret",
    "randomaccount": "secret",
}

# Superset of [oidc] expected_scope, plus aud:rucio for expected_audience.
# A token missing either is rejected by validate_jwt with 401 BEFORE
# has_permission() runs — see conftest.py's rucio_token docstring.
AUTHZ_SCOPE = "openid offline_access storage.read:/ storage.modify:/ aud:rucio"

# Gated purely on _is_privileged, not in _all_known_actions, no RSE-naming
# allowlist entanglement — a deny here is unambiguously an entitlement
# decision (see opa-policy-package's test_phase6_rucio.py).
PRIVILEGED_PATH = "/accounts/ddmlab/limits/local/XRD3"
PRIVILEGED_BODY = {"bytes": -1}


@pytest.fixture
def token_for():
    def _mint(username: str) -> str:
        return fetch_token_password(
            OIDC_TOKEN_URL,
            OIDC_CLIENT_ID,
            OIDC_CLIENT_SECRET,
            username,
            PERSONAS[username],
            scope=AUTHZ_SCOPE,
        )

    return _mint


class TestPersonaPrivilege:
    @pytest.mark.parametrize("username", ["adminuser", "depoperator"])
    def test_privileged_persona_allowed(self, token_for, username):
        resp = rucio_rest(PRIVILEGED_PATH, token_for(username), "POST", PRIVILEGED_BODY)
        assert resp.status_code in (200, 201), (
            f"{username}: HTTP {resp.status_code} {deny_reason(resp)} — if this is "
            "CannotAuthenticate the token was rejected before the policy ran; "
            "check [oidc] expected_scope/expected_audience against AUTHZ_SCOPE"
        )

    @pytest.mark.parametrize(
        "username", ["dependuser", "modeldeveloper", "randomaccount"]
    )
    def test_non_privileged_persona_denied(self, token_for, username):
        resp = rucio_rest(PRIVILEGED_PATH, token_for(username), "POST", PRIVILEGED_BODY)
        assert resp.status_code in (401, 403), f"{username}: HTTP {resp.status_code}"
        exc_cls, exc_msg = deny_reason(resp)
        assert exc_cls == "AccessDenied", (
            f"{username}: {exc_cls}: {exc_msg} — AccessDenied means the policy "
            "denied; CannotAuthenticate means the token never reached it"
        )


class TestPersonaScopeOwnership:
    @pytest.mark.parametrize("username", ["dependuser", "modeldeveloper"])
    def test_persona_can_add_did_in_own_scope(self, token_for, username):
        name = f"probe-{username}-{int(time.time() * 1000)}"
        resp = rucio_rest(
            f"/dids/{username}/{name}", token_for(username), "POST", {"type": "DATASET"}
        )
        assert resp.status_code == 201, (
            f"{username}: HTTP {resp.status_code} {deny_reason(resp)}"
        )

    def test_dependuser_denied_add_did_in_foreign_scope(self, token_for):
        name = f"should-fail-{int(time.time() * 1000)}"
        resp = rucio_rest(
            f"/dids/modeldeveloper/{name}",
            token_for("dependuser"),
            "POST",
            {"type": "DATASET"},
        )
        assert resp.status_code in (401, 403), f"HTTP {resp.status_code}"
        assert deny_reason(resp)[0] == "AccessDenied", deny_reason(resp)
