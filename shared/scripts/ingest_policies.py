#!/usr/bin/env python3
"""
ingest_policies.py — load the Rego policy and data bundle into a running
OPA server for dep-dlm-testbed.

Direct-integration only (AUTHZ_MODE=direct in opa-policy-package terms) —
see docs/design/design-doc-004-direct-opa-integration.md. No phase
concept: this testbed runs one Rucio deployment, not several policy
generations side by side.

Usage:
    python ingest_policies.py [--opa-url URL] [--rego-path PATH]

Re-run at any time to update a live OPA without restarting Rucio.
"""

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

# Repo root is the script's great-grandparent:
# <root>/shared/scripts/ingest_policies.py
REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_RSE_TYPES = [
    "DATADISK",
    "SCRATCHDISK",
    "LOCALGROUPDISK",
    "TAPE",
    "USERDISK",
]

# URN entitlement strings -> privilege level. Ported from
# opa-policy-package's phase6 ENTITLEMENT_POLICY (direct-mode subset —
# no DEP-persona URNs, since those belong to opa-policy-package's own
# entitlement model, not this testbed's).
ENTITLEMENT_POLICY = {
    "urn:example:aai.example.org:group:rucio-admins:role=member": "admin",
    "urn:example:aai.example.org:group:atlas-production:role=member": "admin",
    "urn:example:aai.example.org:group:rucio-users:role=member": "user",
    "urn:example:aai.example.org:group:atlas-users:role=member": "user",
}


@dataclass(frozen=True)
class PolicySpec:
    """What this testbed's OPA ingests.

    policy_id:  OPA policy ID the Rego is stored under. Matches the
                Rego's own `package vo.authz.v5` declaration — not the
                `authz_v6` mismatch opa-policy-package's phase6 carries
                for historical reasons (see design-doc-004's open
                questions).
    data:       data path (relative to /v1/data/) -> JSON payload.
    """

    policy_id: str
    data: dict[str, dict] = field(default_factory=dict)


POLICY = PolicySpec(
    policy_id="authz_v5",
    data={
        "vo/policy": {
            "known_rse_types": DEFAULT_RSE_TYPES,
            # XRD3/XRD4/TEAPOT1/TEAPOT2 don't follow the NAME_TYPE
            # convention; allowlisted rather than relaxing it globally.
            "allowlisted_rse_names": ["XRD3", "XRD4", "TEAPOT1", "TEAPOT2"],
        },
        "vo/entitlement_policy": ENTITLEMENT_POLICY,
    },
)


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


def ingest_policy(base_url: str, spec: PolicySpec, rego_path: Path) -> None:
    if not rego_path.is_file():
        print(f"ERROR: Rego file not found: {rego_path}", file=sys.stderr)
        sys.exit(1)
    status = put(
        f"{base_url}/v1/policies/{spec.policy_id}",
        rego_path.read_text().encode(),
        "text/plain",
    )
    print(f"Policy '{spec.policy_id}' ingested from {rego_path} — HTTP {status}")


def ingest_data(base_url: str, spec: PolicySpec) -> None:
    for path, payload in spec.data.items():
        status = put(
            f"{base_url}/v1/data/{path}",
            json.dumps(payload).encode(),
            "application/json",
        )
        print(f"Data '{path}' ingested ({len(payload)} key(s)) — HTTP {status}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument(
        "--opa-url",
        default="http://localhost:8181",
        help="OPA server base URL (default: %(default)s)",
    )
    parser.add_argument(
        "--rego-path",
        type=Path,
        default=REPO_ROOT / "shared" / "config" / "opa" / "authz.rego",
        help="override the Rego file (default: %(default)s)",
    )
    args = parser.parse_args()

    base_url = args.opa_url.rstrip("/")

    health_check(base_url)
    ingest_policy(base_url, POLICY, args.rego_path)
    ingest_data(base_url, POLICY)

    print("Done.")


if __name__ == "__main__":
    main()
