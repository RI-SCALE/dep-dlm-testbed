"""
test_authz_user.py — a real user token (EGI Check-In, LS AAI, ...) gets its
tier from entitlements the IdP serves only via userinfo (rucio_opa_v1_policy
fetches them when the token lacks them).

Run manually: log in once with `rucio whoami` (OIDC, interactive), then
export the cached token as USER_TOKEN (valid ~1 h). Skipped when unset.
"""

import os
import time

import pytest

from conftest import (
    ADMIN_BODY,
    ADMIN_PATH,
    assert_allowed,
    assert_opa_denied,
    rucio_rest,
    token_claims,
)

TOKEN = os.environ.get("USER_TOKEN", "")
WHO = "user"

pytestmark = pytest.mark.skipif(not TOKEN, reason="USER_TOKEN not set")


def test_token_carries_no_entitlements():
    """Documents why the userinfo lookup exists; fails if the IdP changes this."""
    claims = token_claims(TOKEN)
    assert not (claims.get("entitlements") or claims.get("eduperson_entitlement"))


def test_user_tier_from_userinfo():
    name = f"probe-user-{int(time.time() * 1000)}"
    resp = rucio_rest(f"/dids/ddmlab/{name}", TOKEN, "POST", {"type": "DATASET"})
    assert_allowed(resp, WHO, TOKEN, expected=(201,))


def test_admin_action_denied():
    assert_opa_denied(rucio_rest(ADMIN_PATH, TOKEN, "POST", ADMIN_BODY), WHO)
