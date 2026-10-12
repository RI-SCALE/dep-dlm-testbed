"""
test_authz_personas.py — verifies authz.rego's role-based decisions for the
DEP persona accounts against a running stack (ADR-008).

Tiers come from the ODRL tier policy, matched against each token's
entitlements and acr:

  admin  every action               adminuser, depoperator (MFA required)
  user   rules, DIDs and replicas,  dependuser, modeldeveloper
         on any scope
  none   nothing

There is no ownership: a user-tier persona may add DIDs to any scope, not
only its own. ADMIN_PATH (set_local_account_limit) is an admin-only action
that takes no data argument, so a deny there is purely a tier decision.

Every denial is checked for the OPA reason Rucio appends to AccessDenied.
Without it, Rucio is not running the OPA policy package (for example
because the package failed to import and Rucio fell back to its generic
policy), and the other results here would mean nothing. CannotAuthenticate
means the token never reached has_permission() at all (usually a
scope/audience mismatch against [oidc] expected_scope/expected_audience).

rucio_rest/deny_reason are defined locally rather than in conftest.py: no
other test module needs bare-token REST access yet. Promote them to
conftest.py if a second file needs them.
"""

import base64
import json
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
        "test_authz_personas.py exercises distinct persona identities via "
        "password-grant tokens minted against a local Keycloak realm (see "
        "AUTHZ_TEST_USERS in init-testbed.sh). client_credentials profiles "
        "(egi-dev, ls-aai-dev) authenticate as a single service client with "
        "no per-user distinction, so this test only runs under "
        "SCOPE_PROFILE=local."
    ),
)

# ── Local REST helpers ──────────────────────────────────────────────────

RUCIO_REST_URL = os.environ.get("RUCIO_URL", "http://rucio-server").rstrip("/")

# Reason the OPA policy package attaches to every denial; Rucio appends it
# to the AccessDenied message. Must match permission.py.
OPA_DENY_REASON = "Access denied by OPA policy validation"


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


def token_claims(token):
    """The claims authz.rego decides on, for failure messages."""
    payload = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    return {k: claims.get(k) for k in ("sub", "entitlements", "acr")}


def assert_opa_denied(resp, who):
    """The request was denied, by the OPA policy package."""
    exc_cls, exc_msg = deny_reason(resp)
    assert resp.status_code in (401, 403), (
        f"{who}: expected a denial, got HTTP {resp.status_code}"
    )
    assert exc_cls == "AccessDenied", (
        f"{who}: {exc_cls}: {exc_msg} — AccessDenied means a policy denied; "
        "CannotAuthenticate means the token never reached it"
    )
    assert OPA_DENY_REASON in (exc_msg or ""), (
        f"{who}: denied without the OPA reason ({exc_msg!r}) — Rucio is not using "
        "the OPA policy package; check [policy] package in rucio.cfg and that "
        "rucio_opa_v1_policy imports inside rucio-server"
    )


def assert_allowed(resp, who, token, expected=(200, 201)):
    assert resp.status_code in expected, (
        f"{who}: HTTP {resp.status_code} {deny_reason(resp)}; token claims "
        f"{token_claims(token)} — admins need an admin entitlement with the MFA "
        "acr, users a user-tier entitlement (see odrl/data.json)"
    )


# ── Personas ─────────────────────────────────────────────────────────────

# Must match AUTHZ_TEST_USERS in shared/scripts/init-testbed.sh.
PERSONAS = {
    "adminuser": "admin123",
    "depoperator": "secret",
    "dependuser": "secret",
    "modeldeveloper": "secret",
    "randomaccount": "secret",
}

ADMIN_PERSONAS = ["adminuser", "depoperator"]
USER_PERSONAS = ["dependuser", "modeldeveloper"]

# Superset of [oidc] expected_scope, plus aud:rucio for expected_audience.
# A token missing either is rejected by validate_jwt with 401 BEFORE
# has_permission() runs — see conftest.py's rucio_token docstring.
AUTHZ_SCOPE = "openid offline_access storage.read:/ storage.modify:/ aud:rucio"

# Admin-only and argument-free: a deny here is purely a tier decision.
ADMIN_PATH = "/accounts/ddmlab/limits/local/XRD3"
ADMIN_BODY = {"bytes": -1}


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


def add_dataset(token, scope, label):
    name = f"probe-{label}-{int(time.time() * 1000)}"
    return rucio_rest(f"/dids/{scope}/{name}", token, "POST", {"type": "DATASET"})


# ── Admin tier: every action ────────────────────────────────────────────


class TestAdminTier:
    @pytest.mark.parametrize("username", ADMIN_PERSONAS)
    def test_admin_performs_admin_action(self, token_for, username):
        token = token_for(username)
        assert_allowed(
            rucio_rest(ADMIN_PATH, token, "POST", ADMIN_BODY), username, token
        )

    @pytest.mark.parametrize("username", ADMIN_PERSONAS)
    def test_admin_adds_did_in_any_scope(self, token_for, username):
        token = token_for(username)
        assert_allowed(
            add_dataset(token, "ddmlab", username), username, token, expected=(201,)
        )


# ── User tier: data actions on any scope, nothing else ──────────────────


class TestUserTier:
    @pytest.mark.parametrize("username", USER_PERSONAS + ["randomaccount"])
    def test_admin_action_denied(self, token_for, username):
        assert_opa_denied(
            rucio_rest(ADMIN_PATH, token_for(username), "POST", ADMIN_BODY), username
        )

    @pytest.mark.parametrize("username", USER_PERSONAS)
    def test_adds_did_in_own_scope(self, token_for, username):
        token = token_for(username)
        assert_allowed(
            add_dataset(token, username, username), username, token, expected=(201,)
        )

    @pytest.mark.parametrize(
        "username, scope",
        [
            ("dependuser", "modeldeveloper"),
            ("modeldeveloper", "dependuser"),
            ("dependuser", "ddmlab"),
        ],
    )
    def test_adds_did_in_foreign_scope(self, token_for, username, scope):
        """No ownership: shared data is registered once and used by everyone."""
        token = token_for(username)
        assert_allowed(
            add_dataset(token, scope, username), username, token, expected=(201,)
        )
