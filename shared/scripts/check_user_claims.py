#!/usr/bin/env python3
"""
check_user_claims.py — mint a password-grant token per realm user and
print the decoded claims, so entitlements/acr wiring can be verified
without hand-rolling curl + base64 each time.

Skips service-account-rucio: that's a client-credentials principal, not
a password-grant user — see docs/design/design-doc-004... for why the
entitlements/acr claims matter (authz.rego's _is_privileged /
_has_privilege_level read them directly).

Usage:
    python check_user_claims.py [--keycloak-url URL] [--user USERNAME]
    python check_user_claims.py                       # all users
    python check_user_claims.py --user dependuser      # one user
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# username -> password, mirroring shared/config/keycloak/realm.json.
# service-account-rucio is deliberately absent (client_credentials, not
# password grant).
USERS: dict[str, str] = {
    "randomaccount": "secret",
    "adminuser": "admin123",
    "depoperator": "secret",
    "dependuser": "secret",
    "modeldeveloper": "secret",
}

CLIENT_ID = "rucio"
CLIENT_SECRET = "rucio-secret"
REALM = "rucio"

# entitlements pulls in the entitlements+acr mappers (see the
# entitlements client scope in realm.json); openid is required by spec.
SCOPE = "openid entitlements"


def _decode_jwt(token: str) -> dict:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)  # restore stripped base64 padding
    return json.loads(base64.urlsafe_b64decode(payload))


def fetch_claims(keycloak_url: str, username: str, password: str) -> dict:
    token_url = f"{keycloak_url}/realms/{REALM}/protocol/openid-connect/token"
    body = "&".join(
        f"{k}={v}"
        for k, v in {
            "grant_type": "password",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "username": username,
            "password": password,
            "scope": SCOPE,
        }.items()
    ).encode()

    req = Request(
        token_url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urlopen(req, timeout=10) as resp:
        token_response = json.load(resp)
    return _decode_jwt(token_response["access_token"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument(
        "--keycloak-url",
        default="http://localhost:8080",
        help="Keycloak base URL (default: %(default)s)",
    )
    parser.add_argument(
        "--user",
        choices=sorted(USERS),
        help="only check this user (default: all)",
    )
    args = parser.parse_args()

    targets = {args.user: USERS[args.user]} if args.user else USERS

    exit_code = 0
    for username, password in targets.items():
        print(f"=== {username} ===")
        try:
            claims = fetch_claims(args.keycloak_url, username, password)
        except HTTPError as exc:
            print(
                f"  ERROR: HTTP {exc.code} — {exc.read().decode(errors='replace')}",
                file=sys.stderr,
            )
            exit_code = 1
            continue
        except URLError as exc:
            print(
                f"  ERROR: could not reach {args.keycloak_url} — {exc}", file=sys.stderr
            )
            sys.exit(1)

        print(f"  entitlements: {claims.get('entitlements', [])}")
        print(f"  acr:          {claims.get('acr')}")
        print(f"  sub:          {claims.get('sub')}")
        print()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
