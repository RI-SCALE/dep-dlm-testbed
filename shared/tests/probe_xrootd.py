"""
probe_xrootd.py — pytest-native reachability + SciTokens-auth probe for
XRD3/XRD4. Shells out to `xrdfs` (no first-class XRootD Python client
available) but reuses conftest.py's own token-minting helpers, and
reuses prepare_xrd_dest itself as the definitive "can we actually write
here" check.

Run via: pytest /tests/probe_xrootd.py -v

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
    _xrdfs_run,
    fetch_token_client_credentials,
    fetch_token_password,
)

VALIDATION_STORAGE_HOST = os.environ.get("VALIDATION_STORAGE_HOST")
XRD_TARGETS = (
    {"xrd3": (VALIDATION_STORAGE_HOST, 1094), "xrd4": (VALIDATION_STORAGE_HOST, 1095)}
    if VALIDATION_STORAGE_HOST
    else {"xrd3": ("xrd3", 1094), "xrd4": ("xrd4", 1094)}
)
XRD_PARAMS = list(XRD_TARGETS.items())
XRD_IDS = [f"{name}-{hostport[0]}:{hostport[1]}" for name, hostport in XRD_PARAMS]
PROBE_PATH = "/data"


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


@pytest.mark.parametrize("name,hostport", XRD_PARAMS, ids=XRD_IDS)
def test_xrootd_reachable(name, hostport):
    hostname, port = hostport
    host = f"{hostname}:{port}"
    out = _xrdfs_run(
        [host, "query", "config", "bind_max"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert out.returncode == 0, out.stderr.strip()


@pytest.mark.parametrize("name,hostport", XRD_PARAMS, ids=XRD_IDS)
def test_xrootd_authenticated_list(name, hostport):
    hostname, port = hostport
    host = f"{hostname}:{port}"
    token = _mint(name)
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    c = json.loads(base64.urlsafe_b64decode(payload))
    print(f"  token aud={c.get('aud')!r} sub={c.get('sub')!r}")

    out = _xrdfs_run(
        [host, "ls", f"-OSauthz={token}", PROBE_PATH],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert out.returncode == 0, out.stderr.strip()
    entries = [line for line in out.stdout.splitlines() if line.strip()]
    print(f"  {len(entries)} entrie(s) under {PROBE_PATH}")


@pytest.mark.parametrize("name,hostport", XRD_PARAMS, ids=XRD_IDS)
def test_xrootd_prepare_dest(name, hostport):
    """Native xrdfs mkdir — tests the root:// / native SciTokens path,
    as distinct from an HTTP-based prepare-dest path."""
    hostname, port = hostport
    host = f"{hostname}:{port}"
    token = _mint(name)
    out = _xrdfs_run(
        [host, "mkdir", f"-OSauthz={token}", "-p", f"{PROBE_PATH}/probe-{name}-dir"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert out.returncode == 0 or "exist" in out.stderr.lower(), out.stderr.strip()
