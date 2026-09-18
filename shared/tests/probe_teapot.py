"""
probe_teapot.py — pytest-native reachability + OIDC-auth probe for
TEAPOT1/TEAPOT2 on the validation-storage VM. Isolates exactly which
piece (issuer trust, audience, mapping) a 401/403 traces back to,
independent of Rucio/RSE state — useful before running the full
test_rucio_transfers.py suite.

Run via: pytest /tests/probe_teapot.py -v
(needs TEAPOT1_URL/TEAPOT2_URL set, same as
test_rucio_transfers.py's own env requirements)
"""

import base64
import json

import pytest

from conftest import (
    OIDC_EXPECTED_SCOPE,
    OIDC_GRANT_TYPE,
    TEAPOT1_URL,
    TEAPOT2_URL,
    _rse_resource,
    fetch_token_client_credentials,
    fetch_token_password,
    OIDC_CLIENT_ID,
    OIDC_CLIENT_SECRET,
    OIDC_TOKEN_URL,
    OIDC_USERNAME,
    OIDC_PASSWORD,
    requests,
    webdav_propfind,
)

import os
import subprocess

TARGETS = {"teapot1": TEAPOT1_URL, "teapot2": TEAPOT2_URL}


def _mint(scope: str, resource=None) -> str:
    if OIDC_GRANT_TYPE == "client_credentials":
        return fetch_token_client_credentials(
            OIDC_TOKEN_URL,
            OIDC_CLIENT_ID,
            OIDC_CLIENT_SECRET,
            scope=scope,
            resource=resource,
        )
    return fetch_token_password(
        OIDC_TOKEN_URL,
        OIDC_CLIENT_ID,
        OIDC_CLIENT_SECRET,
        OIDC_USERNAME,
        OIDC_PASSWORD,
        scope=scope,
    )


def _claims(tok: str) -> dict:
    payload = tok.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def _scope_variants(name: str):
    """(label, scope, resource) — isolates which piece a rejection
    traces back to. EGI-style (client_credentials + resource=) vs
    Keycloak-style (password grant + aud:teapot* scope suffix)."""
    if OIDC_GRANT_TYPE == "client_credentials":
        return [
            ("no resource", OIDC_EXPECTED_SCOPE, None),
            ("resource=" + name, OIDC_EXPECTED_SCOPE, _rse_resource(name)),
        ]
    return [
        ("no aud", OIDC_EXPECTED_SCOPE, None),
        ("aud:" + name, f"{OIDC_EXPECTED_SCOPE} aud:{name}", None),
    ]


@pytest.mark.parametrize("name,url", TARGETS.items())
def test_teapot_warm_up(name, url, teapot_token, teapots_ready):
    """Reuses conftest's own teapots_ready fixture — if this passes,
    both JVMs are confirmed cold-start-complete before anything below
    runs, so a subsequent failure means auth/config, not timing."""
    assert teapots_ready


@pytest.mark.parametrize("name,url", TARGETS.items())
def test_teapot_authenticated_propfind_variants(name, url, teapots_ready):
    failures = []
    for label, scope, resource in _scope_variants(name):
        tok = _mint(scope, resource=resource)
        c = _claims(tok)
        r = webdav_propfind(f"{url}/data/", tok, depth="0")
        print(f"  [{label}] aud={c.get('aud')!r} -> HTTP {r.status_code}")
        if r.status_code != 207:
            failures.append(f"{label}: HTTP {r.status_code}")
    assert not failures, f"{name}: " + "; ".join(failures)


@pytest.mark.parametrize("name,url", TARGETS.items())
def test_teapot_anonymous_propfind(name, url, teapots_ready):
    """Informational, not a pass/fail assertion — 207 means anonymous
    reads are allowed, 401/403 means they're correctly blocked; whether
    that's "right" depends on data.properties' anonymousReadEnabled
    setting, not something this test should assume."""
    r = requests.request(
        "PROPFIND", f"{url}/data/", headers={"Depth": "0"}, verify=False, timeout=30
    )
    print(f"  {name}: anonymous PROPFIND -> HTTP {r.status_code}")


@pytest.mark.parametrize("name,url", TARGETS.items())
def test_teapot_authenticated_write(name, url, teapots_ready):
    """PUT + DELETE — read-only PROPFIND passing does not imply write
    scope is granted; StoRM-WebDAV's wlcgScopeAuthzEnabled mode checks
    storage.modify:/-shaped scopes independently of read access."""
    failures = []
    for label, scope, resource in _scope_variants(name):
        tok = _mint(scope, resource=resource)
        c = _claims(tok)
        path = f"{url}/data/probe-write-{name}"
        put_r = requests.put(
            path,
            data=b"probe",
            headers={"Authorization": f"Bearer {tok}"},
            verify=False,
            timeout=30,
        )
        print(f"  [{label}] aud={c.get('aud')!r} PUT -> HTTP {put_r.status_code}")
        if put_r.status_code not in (200, 201, 204):
            failures.append(f"{label}: PUT HTTP {put_r.status_code}")
            continue
        del_r = requests.delete(
            path, headers={"Authorization": f"Bearer {tok}"}, verify=False, timeout=30
        )
        if del_r.status_code not in (200, 204):
            failures.append(f"{label}: DELETE HTTP {del_r.status_code}")
    assert not failures, f"{name}: " + "; ".join(failures)


# ── gfal2-level scheme comparison (davs:// vs https://) ──────────────────
# requests can't distinguish these — davs:// isn't a real URL scheme for it,
# so any requests-based PUT/DELETE against it is identical to https://.
# reaper's actual delete path goes through gfal2's protocol plugins, which
# do differ by scheme — this shells out to the real gfal2 CLI to compare.


def _gfal_rm(pfn: str, token: str) -> tuple[int, str]:
    env = {"BEARER_TOKEN": token}
    result = subprocess.run(
        ["gfal-rm", pfn],
        capture_output=True,
        text=True,
        env={**os.environ, **env},
        timeout=30,
    )
    return result.returncode, (result.stderr or result.stdout).strip()


@pytest.mark.parametrize("name,url", TARGETS.items())
def test_teapot_gfal2_delete_scheme_comparison(name, url, teapots_ready, teapot_token):
    """Compares gfal-rm against davs:// vs https:// for the same file —
    the actual mechanism reaper uses, unlike the requests-based probes
    above which can't distinguish the two schemes at all."""
    from urllib.parse import urlparse

    host_port = urlparse(url).netloc  # e.g. teapot2:8081
    path = f"/data/probe-gfal-delete-{name}"

    for scheme in ("https", "davs"):
        pfn = f"{scheme}://{host_port}{path}"
        # seed via plain https PUT (works reliably — see existing write test)
        put_r = requests.put(
            f"https://{host_port}{path}",
            data=b"probe",
            headers={"Authorization": f"Bearer {teapot_token}"},
            verify=False,
            timeout=30,
        )
        assert put_r.status_code in (200, 201, 204), (
            f"seed PUT failed for {scheme} probe: HTTP {put_r.status_code}"
        )

        rc, out = _gfal_rm(pfn, teapot_token)
        print(f"  [{name}] gfal-rm {pfn} -> rc={rc} {out}")
        assert rc == 0, f"{name}: gfal-rm failed on {scheme}://: {out}"
