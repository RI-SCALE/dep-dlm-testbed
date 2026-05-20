"""
conftest.py — shared fixtures and helpers for dep-dlm-testbed OIDC transfer tests.

Covers XRootD SciTokens (xrd3/xrd4) and Teapot WebDAV (teapot1/teapot2).
Runtime-agnostic: respects $RUNTIME (compose | k8s, default compose).
"""

import logging
import os
import subprocess
import time
from typing import Optional
import zlib

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

log = logging.getLogger("conftest")

# ── Runtime ───────────────────────────────────────────────────────────────

RUNTIME = os.environ.get("RUNTIME", "compose")
K8S_NAMESPACE = os.environ.get("K8S_NAMESPACE", "dep-dlm-testbed")

# Maps service name → (k8s resource kind, container name or None)
K8S_TARGETS: dict[str, tuple[str, Optional[str]]] = {
    "rucio": ("deploy", "rucio"),
    "fts": ("deploy", None),
    "ftsdb": ("statefulset", None),
    "xrd3": ("deploy", None),
    "xrd4": ("deploy", None),
    "teapot1": ("deploy", None),
    "teapot2": ("deploy", None),
    "keycloak": ("deploy", None),
    "ruciodb": ("statefulset", None),
    "rucio-client": ("deploy", None),
}

# ── Service constants ─────────────────────────────────────────────────────

KEYCLOAK_TOKEN_URL = "https://keycloak:8443/realms/rucio/protocol/openid-connect/token"
TEAPOT1_URL = "https://teapot1:8081"
TEAPOT2_URL = "https://teapot2:8081"

# Rucio client config (userpass, single instance)
CFG_RUCIO = "/opt/rucio/etc/rucio.cfg"


# ── Container exec ────────────────────────────────────────────────────────


def svc_exec(svc: str, cmd: list, user: str = None) -> bytes:
    """Run a command inside a service container (compose or k8s)."""
    if RUNTIME == "compose":
        full = ["docker", "exec"]
        if user:
            full += ["--user", user]
        full += [f"compose-{svc}-1"] + cmd
    elif RUNTIME == "k8s":
        kind, container = K8S_TARGETS.get(svc, ("deploy", None))
        target = f"{kind}/{svc}"
        full = ["kubectl", "-n", K8S_NAMESPACE, "exec", target]
        if container:
            full += ["-c", container]
        full += ["--"] + cmd
    else:
        raise RuntimeError(f"Unknown RUNTIME: {RUNTIME!r}")

    result = subprocess.run(full, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"svc_exec failed (exit {result.returncode}): {' '.join(full)}\n"
            f"stdout: {result.stdout.decode(errors='replace')}\n"
            f"stderr: {result.stderr.decode(errors='replace')}"
        )
    return result.stdout


# ── Rucio client (Python API) ─────────────────────────────────────────────


def make_client():
    """Build a Rucio Python client from the mounted config."""
    from rucio.client import Client
    from rucio.common.config import get_config

    conf = get_config()
    conf.read(CFG_RUCIO)
    return Client(
        rucio_host=conf.get("client", "rucio_host"),
        auth_host=conf.get("client", "auth_host"),
        account=conf.get("client", "account"),
        auth_type=conf.get("client", "auth_type"),
        creds={
            "username": conf.get("client", "username"),
            "password": conf.get("client", "password"),
        },
        vo=conf.get("client", "vo", fallback="def"),
    )


# ── PFN computation ───────────────────────────────────────────────────────


def compute_pfn(client, rse: str, scope: str, name: str) -> str:
    """Compute the write PFN for a DID on a given RSE."""
    from rucio.rse import rsemanager as rsemgr

    rse_info = rsemgr.get_rse_info(rse=rse, vo=client.vo)
    return list(
        rsemgr.lfns2pfns(
            rse_info,
            [{"scope": scope, "name": name}],
            operation="write",
        ).values()
    )[0]


# ── Rucio rule helpers ────────────────────────────────────────────────────


def register_replica(
    client, rse: str, scope: str, name: str, pfn: str, size: int, adler32: str
) -> None:
    from rucio.common.exception import Duplicate, RucioException

    log.info(
        "  Registering %s:%s @ %s (bytes=%d adler32=%s)",
        scope,
        name,
        rse,
        size,
        adler32,
    )
    try:
        client.add_replicas(
            rse=rse,
            files=[
                {
                    "scope": scope,
                    "name": name,
                    "bytes": size,
                    "adler32": adler32,
                    "pfn": pfn,
                }
            ],
        )
    except Duplicate:
        log.warning("  Replica %s:%s already exists at %s", scope, name, rse)
    except RucioException as e:
        log.error("  Registration failed: %s", e)
        raise


def add_rule(client, scope: str, name: str, dst_rse: str) -> str:
    rule_id = client.add_replication_rule(
        dids=[{"scope": scope, "name": name}], copies=1, rse_expression=dst_rse
    )[0]
    log.info("  ✓ Rule created: %s:%s → %s (%s)", scope, name, dst_rse, rule_id)
    return rule_id


def run_daemons(rucio_svc: str = "rucio") -> None:
    """Manually advance the conveyor pipeline (--run-once)."""
    for daemon in (
        ["rucio-judge-evaluator", "--run-once"],
        ["rucio-conveyor-submitter", "--run-once"],
        ["rucio-conveyor-poller", "--run-once", "--older-than", "0"],
        ["rucio-conveyor-finisher", "--run-once"],
    ):
        log.info("  → %s %s", rucio_svc, " ".join(daemon))
        out = svc_exec(rucio_svc, daemon)
        for line in out.decode(errors="replace").splitlines():
            if any(
                k in line.lower()
                for k in ("warning", "error", "failed", "submit", "checksum")
            ):
                log.info("    | %s", line)


def validate_rule(
    client,
    rule_id: str,
    label: str,
    rucio_svc: str = "rucio",
    timeout: int = 300,
) -> None:
    """Poll until locks_ok >= 1 and locks_replicating == 0, cycling daemons each iteration."""
    from rucio.common.exception import RuleNotFound

    log.info("=== Validating rule %s (%s) ===", rule_id, label)
    deadline = time.time() + timeout
    ok = repl = stk = 0

    while time.time() < deadline:
        try:
            rule = client.get_replication_rule(rule_id)
        except RuleNotFound:
            time.sleep(2)
            continue

        ok = rule["locks_ok_cnt"]
        repl = rule["locks_replicating_cnt"]
        stk = rule["locks_stuck_cnt"]
        log.info(
            "  state=%-12s  OK=%-3d REPL=%-3d STUCK=%-3d",
            rule.get("state", "?"),
            ok,
            repl,
            stk,
        )

        if stk > 0:
            raise RuntimeError(f"Rule {rule_id} ({label}) has {stk} stuck lock(s)")

        if ok >= 1 and repl == 0:
            log.info("  ✓ %s passed (rule_id=%s)", label, rule_id)
            return

        run_daemons(rucio_svc)
        time.sleep(5)

    raise TimeoutError(
        f"Rule {rule_id} ({label}) did not converge within {timeout}s — "
        f"last: OK={ok} REPL={repl} STUCK={stk}"
    )


# ── XRootD filesystem seeding (via container exec) ────────────────────────


def seed_xrd(svc: str, pfn: str) -> tuple[int, str]:
    """
    Seed a test file into an XRootD container at the given PFN path.
    Returns (size_bytes, adler32_hex).
    """
    local_path = pfn.split("//", 1)[-1].split("/", 1)[-1]
    local_path = "/" + local_path

    script = (
        "set -e; "
        f'mkdir -p "$(dirname {local_path})"; '
        f'printf "rucio-test\\n" > {local_path}; '
        f"chown xrootd:xrootd {local_path} 2>/dev/null || true"
    )
    svc_exec(svc, ["sh", "-c", script], user="root")
    raw = svc_exec(svc, ["cat", local_path])
    adler = "%08x" % (zlib.adler32(raw) & 0xFFFFFFFF)
    return len(raw), adler


def prepare_xrd_dest(svc: str, pfn: str) -> None:
    """Pre-create the destination directory on an XRootD container."""
    local_path = "/" + pfn.split("//", 1)[-1].split("/", 1)[-1]
    script = (
        f'mkdir -p "$(dirname {local_path})" && '
        f'chown xrootd:xrootd "$(dirname {local_path})" 2>/dev/null || true'
    )
    svc_exec(svc, ["sh", "-c", script], user="root")


def seed_and_register_files(
    client,
    rse: str,
    scope: str,
    names: list[str],
    seed_svc: str,
) -> list[dict]:
    """Seed files into an XRootD RSE and return Rucio replica dicts."""
    registered = []
    for name in names:
        pfn = compute_pfn(client, rse, scope, name)
        size, adler32 = seed_xrd(seed_svc, pfn)
        registered.append(
            {
                "scope": scope,
                "name": name,
                "bytes": size,
                "adler32": adler32,
                "pfn": pfn,
            }
        )
        log.info("  seeded %s:%s → %s", scope, name, pfn)
    return registered


def prepare_xrd_dest_files(
    client, rse: str, svc: str, scope: str, names: list[str]
) -> None:
    """Pre-create destination directories on an XRootD RSE for a list of DIDs."""
    for name in names:
        pfn = compute_pfn(client, rse, scope, name)
        prepare_xrd_dest(svc, pfn)


# ── Keycloak token helpers ────────────────────────────────────────────────


def fetch_token_password(
    url: str,
    client_id: str,
    client_secret: str,
    username: str,
    password: str,
    scope: str = "openid",
) -> str:
    resp = requests.post(
        url,
        data={
            "grant_type": "password",
            "username": username,
            "password": password,
            "scope": scope,
        },
        auth=(client_id, client_secret),
        verify=False,
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


# ── WebDAV helpers ────────────────────────────────────────────────────────


def webdav_put(
    url: str, token: str, content: bytes, timeout: int = 30
) -> requests.Response:
    return requests.put(
        url,
        headers={"Authorization": f"Bearer {token}"},
        data=content,
        verify=False,
        timeout=timeout,
    )


def webdav_get(url: str, token: str, timeout: int = 30) -> requests.Response:
    return requests.get(
        url,
        headers={"Authorization": f"Bearer {token}"},
        verify=False,
        timeout=timeout,
    )


def webdav_delete(url: str, token: str, timeout: int = 30) -> requests.Response:
    return requests.delete(
        url,
        headers={"Authorization": f"Bearer {token}"},
        verify=False,
        timeout=timeout,
    )


def webdav_propfind(
    url: str, token: str, depth: str = "1", timeout: int = 240
) -> requests.Response:
    return requests.request(
        "PROPFIND",
        url,
        headers={"Authorization": f"Bearer {token}", "Depth": depth},
        verify=False,
        timeout=timeout,
    )


def webdav_warm_up(
    base_url: str,
    path: str,
    label: str,
    token: str,
    retries: int = 6,
    interval: int = 10,
) -> None:
    """
    Trigger Teapot's per-user Storm-WebDAV JVM cold start via PROPFIND.
    Blocks until HTTP 207 or raises AssertionError.
    The JVM cold start typically takes 20-40s.
    """
    log.info("=== Warming up %s Storm-WebDAV instance ===", label)
    resp = None
    for attempt in range(1, retries + 1):
        resp = webdav_propfind(f"{base_url}{path}", token)
        if resp.status_code == 207:
            log.info("  ✓ %s Storm-WebDAV ready (HTTP 207)", label)
            return
        log.info(
            "  [%d] %s returned HTTP %s — retrying in %ds",
            attempt,
            label,
            resp.status_code,
            interval,
        )
        time.sleep(interval)
    raise AssertionError(
        f"{label} warm-up failed after {retries} attempts "
        f"(last HTTP {resp.status_code if resp else 'N/A'})"
    )


# ── Session-scoped fixtures ───────────────────────────────────────────────


@pytest.fixture(scope="session")
def rucio_client():
    """Rucio Python client (userpass, single OIDC instance)."""
    return make_client()


@pytest.fixture(scope="session")
def oidc_token():
    """
    Keycloak resource-owner password token for 'randomaccount'.
    Scopes include storage read/write — used for Teapot seeding and
    as the bearer token Rucio will exchange for FTS TPC submissions.
    """
    return fetch_token_password(
        KEYCLOAK_TOKEN_URL,
        client_id="rucio",
        client_secret="rucio-secret",
        username="randomaccount",
        password="secret",
        scope="openid storage.read:/ storage.modify:/",
    )


@pytest.fixture(scope="session")
def teapots_ready(oidc_token):
    """
    Warm up both Teapot Storm-WebDAV JVMs before any transfer test runs.
    This fixture is a session-level precondition — request it in any test
    that talks to teapot1 or teapot2.
    """
    webdav_warm_up(TEAPOT1_URL, "/data/", "teapot1", oidc_token)
    webdav_warm_up(TEAPOT2_URL, "/data/", "teapot2", oidc_token)
    return True
