#!/usr/bin/env python3
"""probe_fts_teapot.py — minimal FTS-only repro for teapot1->teapot2 TPC,
bypassing Rucio/conveyor entirely. Run from inside the fts pod itself.

Env vars (see conftest.py for the same pattern):
  OIDC_ISSUER, OIDC_TOKEN_URL, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET,
  OIDC_EXPECTED_SCOPE, OIDC_RESOURCE_SUFFIX
  VALIDATION_STORAGE_HOST — required, e.g. valstorage.dep-dlm-staging.example.com
"""

import json
import os
import sys
import time

import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VALSTORAGE_HOST = os.environ.get("VALIDATION_STORAGE_HOST")
if not VALSTORAGE_HOST:
    sys.exit(
        "ERROR: VALIDATION_STORAGE_HOST must be set (e.g. valstorage.dep-dlm-staging.example.com)"
    )

FTS = os.environ.get("FTS_URL") or "https://localhost:8446"
TEAPOT1_URL = f"https://{VALSTORAGE_HOST}:8081"
TEAPOT2_URL = f"https://{VALSTORAGE_HOST}:8082"

OIDC_ISSUER = os.environ.get("OIDC_ISSUER") or "https://keycloak:8443/realms/rucio"
OIDC_TOKEN_URL = (
    os.environ.get("OIDC_TOKEN_URL")
    or f"{OIDC_ISSUER.rstrip('/')}/protocol/openid-connect/token"
)
OIDC_CLIENT_ID = os.environ.get("OIDC_CLIENT_ID") or "rucio"
OIDC_CLIENT_SECRET = os.environ.get("OIDC_CLIENT_SECRET") or "rucio-secret"
OIDC_EXPECTED_SCOPE = (
    os.environ.get("OIDC_EXPECTED_SCOPE") or "openid storage.read:/ storage.modify:/"
)
OIDC_RESOURCE_SUFFIX = os.environ.get("OIDC_RESOURCE_SUFFIX") or ".example.org"

SRC_PATH = "/data/ddmlab/probe/fts-direct-test"
DST_PATH = "/data/ddmlab/probe/fts-direct-test"


def mint_token(resources):
    resp = requests.post(
        OIDC_TOKEN_URL,
        data={
            "grant_type": "client_credentials",
            "scope": OIDC_EXPECTED_SCOPE,
            "resource": resources,
        },
        auth=(OIDC_CLIENT_ID, OIDC_CLIENT_SECRET),
        verify=False,
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def main():
    token = mint_token(
        [
            f"https://teapot1{OIDC_RESOURCE_SUFFIX}/",
            f"https://teapot2{OIDC_RESOURCE_SUFFIX}/",
        ]
    )
    print("✓ token minted")

    # Prove the main FTS process's own network path works (baseline)
    r = requests.put(
        f"{TEAPOT1_URL}{SRC_PATH}",
        data=b"probe",
        headers={"Authorization": f"Bearer {token}"},
        verify=False,
        timeout=30,
    )
    print(f"seed PUT (direct from fts container) -> HTTP {r.status_code}")
    assert r.status_code in (200, 201, 204), r.text

    # Submit the real TPC job
    job_body = {
        "files": [
            {
                "sources": [f"davs://{VALSTORAGE_HOST}:8081{SRC_PATH}"],
                "destinations": [f"davs://{VALSTORAGE_HOST}:8082{DST_PATH}"],
                "source_tokens": [token],
                "destination_tokens": [token],
            }
        ],
        "params": {"overwrite": True, "unmanaged_tokens": True, "checksum": None},
    }
    resp = requests.post(
        f"{FTS}/jobs",
        json=job_body,
        headers={"Authorization": f"Bearer {token}"},
        verify=False,
        timeout=10,
    )
    resp.raise_for_status()
    job_id = resp.json()["job_id"]
    print(f"✓ job submitted: {job_id}")

    for i in range(30):
        r = requests.get(
            f"{FTS}/jobs/{job_id}",
            headers={"Authorization": f"Bearer {token}"},
            verify=False,
            timeout=10,
        )
        state = r.json().get("job_state")
        print(f"  [{i}] state={state}")
        if state in {"FINISHED", "FAILED", "CANCELED", "FINISHEDDIRTY"}:
            print(json.dumps(r.json(), indent=2, default=str))
            # Fetch per-file detail — the job-level response has no
            # reason string (dst_file_report=false), so this is the
            # only place the actual error (e.g. UnknownHostException)
            # shows up.
            files_r = requests.get(
                f"{FTS}/jobs/{job_id}/files",
                headers={"Authorization": f"Bearer {token}"},
                verify=False,
                timeout=10,
            )
            print(json.dumps(files_r.json(), indent=2, default=str))
            break
        time.sleep(5)


if __name__ == "__main__":
    main()
