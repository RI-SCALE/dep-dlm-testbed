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
"""

import os
import time

import pytest

from conftest import (
    ADMIN_BODY,
    ADMIN_PATH,
    OIDC_CLIENT_ID,
    OIDC_CLIENT_SECRET,
    OIDC_TOKEN_URL,
    assert_allowed,
    assert_opa_denied,
    fetch_token_password,
    rucio_rest,
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

# ── Personas ─────────────────────────────────────────────────────────────

# Must match AUTHZ_TEST_USERS in scripts/init-testbed.sh.
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
    # randomaccount's subject is also seeded onto root/ddmlab (init-testbed.sh):
    # it must still be denied, since admin_accounts only applies without a token.
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

    def test_deletes_another_personas_rule(self, token_for):
        """No ownership on rules either: any user-tier member may manage them.

        del_rule reaches the policy with a rule_id only, so this also checks
        the rule actions are wired through to OPA end to end.
        """
        owner, other = token_for("dependuser"), token_for("modeldeveloper")
        name = f"probe-rule-{int(time.time() * 1000)}"
        assert_allowed(
            rucio_rest(f"/dids/dependuser/{name}", owner, "POST", {"type": "DATASET"}),
            "dependuser",
            owner,
            expected=(201,),
        )
        resp = rucio_rest(
            "/rules/",
            owner,
            "POST",
            {
                "dids": [{"scope": "dependuser", "name": name}],
                "account": "dependuser",
                "copies": 1,
                "rse_expression": "XRD3",
            },
        )
        assert_allowed(resp, "dependuser", owner, expected=(201,))
        rule_id = resp.json()[0]
        assert_allowed(
            # Rucio's DELETE /rules/{id} parses a JSON body (purge_replicas etc.).
            rucio_rest(f"/rules/{rule_id}", other, "DELETE", {}),
            "modeldeveloper",
            other,
        )
