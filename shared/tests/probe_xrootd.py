"""
probe_xrootd.py — pytest-native reachability + SciTokens-auth probe for
XRD3/XRD4 on the validation-storage VM. Shells out to `xrdfs` (no
first-class XRootD Python client available) but reuses conftest.py's
own token-minting helpers, and reuses prepare_xrd_dest itself as the
definitive "can we actually write here" check.

Run via: pytest /tests/probe_xrootd.py -v
(needs VALIDATION_STORAGE_HOST set)

NOTE on retries: this environment has been observed with very low
kernel entropy (~256, vs. thousands on a healthy host — check via
`cat /proc/sys/kernel/random/entropy_avail`), which manifests as
transient "[FATAL] TLS error: resource temporarily unavailable" on
back-to-back xrdfs TLS handshakes within the same process/container.
_xrdfs() retries specifically on that message; any other xrdfs error
is treated as real and not retried.
"""

import base64
import json
import os
import subprocess
import time

import pytest

from conftest import (
    OIDC_EXPECTED_SCOPE,
    OIDC_GRANT_TYPE,
    OIDC_CLIENT_ID,
    OIDC_CLIENT_SECRET,
    OIDC_TOKEN_URL,
    OIDC_USERNAME,
    OIDC_PASSWORD,
    _rse_resource,
    fetch_token_client_credentials,
    fetch_token_password,
    prepare_xrd_dest,
)

VALIDATION_STORAGE_HOST = os.environ.get("VALIDATION_STORAGE_HOST")
pytestmark = pytest.mark.skipif(
    not VALIDATION_STORAGE_HOST, reason="VALIDATION_STORAGE_HOST not set"
)

# name -> port, matching modules/validation-storage's outputs
XRD_TARGETS = {"xrd3": 1094, "xrd4": 1095}
PROBE_PATH = "/data"

_TRANSIENT = "resource temporarily unavailable"


def _xrdfs(
    args: list, retries: int = 3, backoff: float = 3.0
) -> subprocess.CompletedProcess:
    """Run xrdfs, retrying only on the transient TLS-handshake failure
    documented above — any other error is returned immediately so a
    real failure isn't masked by blind retrying."""
    out = None
    for attempt in range(1, retries + 1):
        out = subprocess.run(
            ["xrdfs", *args], capture_output=True, text=True, timeout=15
        )
        if out.returncode == 0:
            return out
        if _TRANSIENT not in out.stderr.lower():
            return out
        if attempt < retries:
            print(
                f"  [{attempt}/{retries}] transient TLS error, retrying in {backoff}s..."
            )
            time.sleep(backoff)
    return out


def _mint(name: str) -> str:
    if OIDC_GRANT_TYPE == "client_credentials":
        return fetch_token_client_credentials(
            OIDC_TOKEN_URL,
            OIDC_CLIENT_ID,
            OIDC_CLIENT_SECRET,
            scope=OIDC_EXPECTED_SCOPE,
            resource=_rse_resource(name),
        )
    return fetch_token_password(
        OIDC_TOKEN_URL,
        OIDC_CLIENT_ID,
        OIDC_CLIENT_SECRET,
        OIDC_USERNAME,
        OIDC_PASSWORD,
        scope=OIDC_EXPECTED_SCOPE,
    )


@pytest.mark.parametrize("name,port", XRD_TARGETS.items())
def test_xrootd_reachable(name, port):
    host = f"{VALIDATION_STORAGE_HOST}:{port}"
    out = _xrdfs([host, "query", "config", "bind_max"])
    assert out.returncode == 0, out.stderr.strip()


@pytest.mark.parametrize("name,port", XRD_TARGETS.items())
def test_xrootd_authenticated_list(name, port):
    host = f"{VALIDATION_STORAGE_HOST}:{port}"
    token = _mint(name)
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    c = json.loads(base64.urlsafe_b64decode(payload))
    print(f"  token aud={c.get('aud')!r} sub={c.get('sub')!r}")

    out = _xrdfs([host, "ls", f"-OSauthz={token}", PROBE_PATH])
    assert out.returncode == 0, out.stderr.strip()
    entries = [line for line in out.stdout.splitlines() if line.strip()]
    print(f"  {len(entries)} entrie(s) under {PROBE_PATH}")


@pytest.mark.parametrize("name,port", XRD_TARGETS.items())
def test_xrootd_prepare_dest(name, port):
    """Reuses conftest's own prepare_xrd_dest — the exact function the
    real e2e tests call — as the definitive write-capability check,
    not just an authenticated list. Single slash between authority and
    path, matching the shape compute_pfn() actually produces (NOT
    Terraform's pfn_root outputs, which use a double slash) — see
    module docstring; conftest's own host-parsing needs to handle both
    (see the split("//")[1] fix landed alongside this file)."""
    host = f"{VALIDATION_STORAGE_HOST}:{port}"
    token = _mint(name)
    pfn = f"root://{host}{PROBE_PATH}/probe-{name}-liveness"
    prepare_xrd_dest(pfn, token=token)
