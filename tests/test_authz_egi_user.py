"""
test_authz_egi_user.py — a real EGI Check-In user token gets its tier from
entitlements that EGI only serves via userinfo (rucio_opa_v1_policy fetches
them when the token lacks them).

Run manually: log in once with `rucio whoami` (OIDC, interactive), then
export the cached token as EGI_USER_TOKEN (valid ~1 h). Skipped when unset.
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

TOKEN = os.environ.get("EGI_USER_TOKEN", "")

pytestmark = pytest.mark.skipif(not TOKEN, reason="EGI_USER_TOKEN not set")


def test_token_carries_no_entitlements():
    """Documents why the userinfo lookup exists; fails if EGI changes this."""
    claims = token_claims(TOKEN)
    assert not (claims.get("entitlements") or claims.get("eduperson_entitlement"))


def test_user_tier_from_userinfo():
    name = f"probe-egi-{int(time.time() * 1000)}"
    resp = rucio_rest(f"/dids/ddmlab/{name}", TOKEN, "POST", {"type": "DATASET"})
    assert_allowed(resp, "egi-user", TOKEN, expected=(201,))


def test_admin_action_denied():
    assert_opa_denied(rucio_rest(ADMIN_PATH, TOKEN, "POST", ADMIN_BODY), "egi-user")
