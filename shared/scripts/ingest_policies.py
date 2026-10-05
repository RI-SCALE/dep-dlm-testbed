#!/usr/bin/env python3
"""
ingest_policies.py — load the Rego policy and data bundle into a running
OPA server for dep-dlm-testbed.

Direct-integration only — see docs/design/design-doc-004-direct-opa-integration.md.
The vendored opa-ri-scale ODRL evaluator (package dep.*) is loaded by OPA at
start-up; this script checks it's present, then loads:
  1. authz.rego (package vo.authz.v5)
  2. data: vo/policy, vo/entitlement_policy and the ODRL policies at dep/odrl

Usage:
    python ingest_policies.py [--opa-url URL] [--opa-dir DIR]

Re-run at any time to update a live OPA without restarting Rucio.
"""

import argparse
import json
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

AUTHZ_POLICY_ID = "authz_v5"
ODRL_FILE = Path("odrl") / "data.json"

DEFAULT_RSE_TYPES = ["DATADISK", "SCRATCHDISK", "LOCALGROUPDISK", "TAPE", "USERDISK"]

# Only consulted when TIER_SOURCE is "claims"; with "odrl" the tiers come
# from dep/odrl and authz.rego ignores this map.
ENTITLEMENT_POLICY = {
    "urn:example:aai.example.org:group:rucio-admins:role=member": "admin",
    "urn:example:aai.example.org:group:atlas-production:role=member": "admin",
    "urn:example:aai.example.org:group:rucio-users:role=member": "user",
    "urn:example:aai.example.org:group:atlas-users:role=member": "user",
    # DEP personas
    "urn:example:aai.example.org:group:dep-operator:role=member": "admin",
    "urn:example:aai.example.org:group:dep-end-user:role=member": "user",
    "urn:example:aai.example.org:group:model-developer:role=member": "user",
}

# XRD3/XRD4/TEAPOT1/TEAPOT2 and COPERNICUS_S3 don't follow NAME_TYPE;
# allowlisted rather than relaxing the convention globally.
ALLOWLISTED_RSE_NAMES = ["XRD3", "XRD4", "TEAPOT1", "TEAPOT2", "COPERNICUS_S3"]

# Where authz.rego takes admin/user tiers from: "odrl" (vendored evaluator
# reading dep/odrl) or "claims" (ENTITLEMENT_POLICY below). Kept only as a
# fallback while the ODRL path settles; remove together with the claims
# branch in authz.rego and ENTITLEMENT_POLICY.
TIER_SOURCE = "odrl"


def _default_opa_dir() -> Path:
    """shared/config/opa relative to this script's checked-out location.
    In containers the caller passes --opa-dir explicitly."""
    return Path(__file__).resolve().parents[1] / "config" / "opa"


def put(url: str, body: bytes, content_type: str) -> int:
    req = Request(url, data=body, headers={"Content-Type": content_type}, method="PUT")
    try:
        with urlopen(req, timeout=10) as resp:
            return resp.status
    except URLError as exc:
        print(f"ERROR: PUT {url} failed — {exc}", file=sys.stderr)
        sys.exit(1)


def health_check(base_url: str) -> None:
    try:
        with urlopen(f"{base_url}/health", timeout=5) as resp:
            if resp.status != 200:
                print(
                    f"ERROR: OPA health check returned HTTP {resp.status}",
                    file=sys.stderr,
                )
                sys.exit(1)
    except URLError as exc:
        print(f"ERROR: OPA not reachable at {base_url} — {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"OPA reachable at {base_url}")


def require_evaluator(base_url: str) -> None:
    """The vendored dep evaluator is loaded by OPA at start-up (compose
    volume / Helm opa-evaluator ConfigMap), not here: its modules call each
    other's functions cyclically, which the policy API can't compile one at
    a time. data.dep.allow has a default, so it's defined iff it's loaded."""
    try:
        with urlopen(f"{base_url}/v1/data/dep/allow", timeout=5) as resp:
            loaded = "result" in json.load(resp)
    except URLError as exc:
        print(f"ERROR: querying data.dep.allow failed — {exc}", file=sys.stderr)
        sys.exit(1)
    if not loaded:
        print("ERROR: ODRL evaluator (package dep) not loaded in OPA", file=sys.stderr)
        sys.exit(1)
    print("ODRL evaluator present (data.dep.allow defined)")


def ingest_module(base_url: str, policy_id: str, path: Path) -> None:
    if not path.is_file():
        print(f"ERROR: Rego file not found: {path}", file=sys.stderr)
        sys.exit(1)
    status = put(f"{base_url}/v1/policies/{policy_id}", path.read_bytes(), "text/plain")
    print(f"Policy '{policy_id}' ingested — HTTP {status}")


def ingest_data(base_url: str, data: dict[str, object]) -> None:
    for path, payload in data.items():
        status = put(
            f"{base_url}/v1/data/{path}",
            json.dumps(payload).encode(),
            "application/json",
        )
        size = len(payload) if hasattr(payload, "__len__") else 1
        print(f"Data '{path}' ingested ({size} key(s)) — HTTP {status}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument(
        "--opa-url",
        default="http://localhost:8181",
        help="OPA server base URL (default: %(default)s)",
    )
    parser.add_argument(
        "--opa-dir",
        type=Path,
        default=_default_opa_dir(),
        help="directory holding authz.rego, vendor/ and odrl/ (default: %(default)s)",
    )
    args = parser.parse_args()

    base_url = args.opa_url.rstrip("/")
    opa_dir = args.opa_dir

    odrl_path = opa_dir / ODRL_FILE
    if not odrl_path.is_file():
        print(f"ERROR: ODRL policies not found: {odrl_path}", file=sys.stderr)
        sys.exit(1)

    vo_policy: dict[str, object] = {
        "known_rse_types": DEFAULT_RSE_TYPES,
        "allowlisted_rse_names": ALLOWLISTED_RSE_NAMES,
    }
    if TIER_SOURCE == "odrl":
        vo_policy["tier_source"] = "odrl"

    health_check(base_url)
    require_evaluator(base_url)
    ingest_module(base_url, AUTHZ_POLICY_ID, opa_dir / "authz.rego")
    ingest_data(
        base_url,
        {
            "vo/policy": vo_policy,
            "vo/entitlement_policy": ENTITLEMENT_POLICY,
            "dep/odrl": json.loads(odrl_path.read_text()),
        },
    )
    print(f"Done (tier_source={TIER_SOURCE}).")


if __name__ == "__main__":
    main()
