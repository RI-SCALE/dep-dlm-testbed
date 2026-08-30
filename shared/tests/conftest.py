"""
conftest.py — shared fixtures and helpers for dep-dlm-testbed OIDC transfer tests.

Covers XRootD SciTokens (xrd3/xrd4) and Teapot WebDAV (teapot1/teapot2).
Runtime-agnostic: respects $RUNTIME (compose | k8s, default compose).
"""

import json
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

RUNTIME = os.environ.get("RUNTIME") or "compose"
K8S_NAMESPACE = os.environ.get("K8S_NAMESPACE") or "dep-dlm-sandbox"

# Maps service name → (k8s resource kind, container name or None)
K8S_TARGETS: dict[str, tuple[str, Optional[str]]] = {
    "rucio-server": ("deploy", "rucio-server"),
    "fts": ("deploy", None),
    "ftsdb": ("statefulset", None),
    "xrd3": ("deploy", None),
    "xrd4": ("deploy", None),
    "teapot1": ("deploy", None),
    "teapot2": ("deploy", None),
    "keycloak": ("deploy", None),
    "ruciodb": ("statefulset", None),
    "rucio-client": ("deploy", None),
    "rucio-daemons": ("deploy", None),
}

# ── Service constants ─────────────────────────────────────────────────────

VALSTORAGE_HOST = os.environ.get("VALIDATION_STORAGE_HOST")
TEAPOT1_URL = os.environ.get("TEAPOT1_URL") or (
    f"https://{VALSTORAGE_HOST}:8081" if VALSTORAGE_HOST else "https://teapot1:8081"
)
TEAPOT2_URL = os.environ.get("TEAPOT2_URL") or (
    f"https://{VALSTORAGE_HOST}:8082" if VALSTORAGE_HOST else "https://teapot2:8081"
)

# Rucio client config (userpass, single instance)
CFG_RUCIO = "/opt/rucio/etc/rucio.cfg"

DAEMON_MODE = os.environ.get("DAEMON_MODE") or "direct"

DEFAULT_CONVEYOR = (
    ["rucio-judge-evaluator", "--run-once"],
    ["rucio-conveyor-submitter", "--run-once"],
    ["rucio-conveyor-poller", "--run-once", "--older-than", "0"],
    ["rucio-conveyor-finisher", "--run-once"],
)

DELETION_DAEMONS = (
    ["rucio-judge-cleaner", "--run-once"],
    ["rucio-reaper", "--run-once", "--greedy"],
)

# ── OIDC provider config (env-overridable; defaults = internal Keycloak) ──

OIDC_ISSUER = os.environ.get("OIDC_ISSUER") or "https://keycloak:8443/realms/rucio"
OIDC_TOKEN_URL = (
    os.environ.get("OIDC_TOKEN_URL")
    or f"{OIDC_ISSUER.rstrip('/')}/protocol/openid-connect/token"
)
OIDC_CLIENT_ID = os.environ.get("OIDC_CLIENT_ID") or "rucio"
OIDC_CLIENT_SECRET = os.environ.get("OIDC_CLIENT_SECRET") or "rucio-secret"
OIDC_USERNAME = os.environ.get("OIDC_USERNAME") or "randomaccount"
OIDC_PASSWORD = os.environ.get("OIDC_PASSWORD") or "secret"
OIDC_GRANT_TYPE = (
    os.environ.get("OIDC_GRANT_TYPE") or "password"
)  # password | client_credentials

OIDC_EXPECTED_SCOPE = (
    os.environ.get("OIDC_EXPECTED_SCOPE") or "openid storage.read:/ storage.modify:/"
)
OIDC_TEAPOT_AUD_SCOPE = (
    os.environ.get("OIDC_TEAPOT_AUD_SCOPE") or "aud:teapot1 aud:teapot2"
)

# EGI (RFC 8707) resource indicators require a URI. Local/Keycloak's
# aud:* scope syntax works with bare RSE names, so this helper is only
# consulted when OIDC_GRANT_TYPE == "client_credentials" (the EGI path);
# under the password grant it's never even passed to the token request.
OIDC_RESOURCE_SUFFIX = os.environ.get("OIDC_RESOURCE_SUFFIX") or ".example.org"

XRDFS_TRANSIENT_ERR = "resource temporarily unavailable"

GITOPS_ENV = os.environ.get("GITOPS_ENV") or "sandbox"
# Only set on staging (see Makefile's staging_tf_output-derived env vars) —
# staging's FTS MySQL is Cloud SQL, not an in-cluster `ftsdb` StatefulSet,
# so there's no pod for svc_exec to target and no route from the runner
# to the private IP (same constraint documented in
# deploy/terraform/tests/test_deployed_infra.py's module docstring).
FTS_DATABASE_HOST = os.environ.get("FTS_DATABASE_HOST")
FTS_DB_PASSWORD = os.environ.get("FTS_DB_PASSWORD")


def _rse_resource(name: str) -> str:
    """Map a bare RSE name to the URI form EGI expects as resource=."""
    if OIDC_GRANT_TYPE != "client_credentials":
        return name  # unused by fetch_token_password, kept as-is for clarity
    return f"https://{name}{OIDC_RESOURCE_SUFFIX}/"


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


# ── FTS database access (compose/sandbox exec vs. staging Cloud SQL) ──────


def fts_mysql_exec(sql: str) -> None:
    """Run a statement against FTS's MySQL DB, picking the right transport
    for the environment:

      - compose / k8s sandbox: exec into the `ftsdb` container/pod directly
        (existing behaviour, unchanged).
      - k8s staging: no `ftsdb` resource exists — FTS's DB is Cloud SQL,
        reachable only from inside the cluster's VPC. Run the statement as
        a one-shot `kubectl run` pod, the same transport
        test_deployed_infra.py's _run_db_check_pod uses for the identical
        constraint.
    """
    if RUNTIME == "k8s" and GITOPS_ENV == "staging":
        if not FTS_DATABASE_HOST or not FTS_DB_PASSWORD:
            raise RuntimeError(
                "fts_mysql_exec: GITOPS_ENV=staging requires FTS_DATABASE_HOST "
                "and FTS_DB_PASSWORD to be set (see Makefile's staging_tf_output "
                "wiring for EXEC_RUCIO)"
            )
        pod_name = f"fts-mysql-exec-{int(time.time())}"
        overrides = {
            "apiVersion": "v1",
            "spec": {
                "containers": [
                    {
                        "name": pod_name,
                        "image": "mysql:8.4",
                        "command": [
                            "mysql",
                            "-h",
                            FTS_DATABASE_HOST,
                            "-ufts",
                            f"-p{FTS_DB_PASSWORD}",
                            "fts",
                            "-e",
                            sql,
                        ],
                        "resources": {"requests": {"cpu": "100m", "memory": "128Mi"}},
                    }
                ]
            },
        }
        subprocess.run(
            [
                "kubectl",
                "-n",
                K8S_NAMESPACE,
                "delete",
                "pod",
                pod_name,
                "--ignore-not-found",
                "--wait=true",
                "--timeout=60s",
            ],
            capture_output=True,
        )
        try:
            run = subprocess.run(
                [
                    "kubectl",
                    "run",
                    pod_name,
                    "-n",
                    K8S_NAMESPACE,
                    "--image=mysql:8.4",
                    "--restart=Never",
                    f"--overrides={json.dumps(overrides)}",
                ],
                capture_output=True,
                text=True,
            )
            if run.returncode != 0:
                raise RuntimeError(f"fts_mysql_exec: kubectl run failed: {run.stderr}")

            wait = subprocess.run(
                [
                    "kubectl",
                    "wait",
                    "-n",
                    K8S_NAMESPACE,
                    "--for=jsonpath={.status.phase}=Succeeded",
                    f"pod/{pod_name}",
                    "--timeout=60s",
                ],
                capture_output=True,
                text=True,
            )
            if wait.returncode != 0:
                logs = subprocess.run(
                    ["kubectl", "logs", pod_name, "-n", K8S_NAMESPACE],
                    capture_output=True,
                    text=True,
                ).stdout
                raise RuntimeError(
                    f"fts_mysql_exec: pod didn't succeed: {wait.stderr}\nlogs: {logs}"
                )
        finally:
            subprocess.run(
                [
                    "kubectl",
                    "-n",
                    K8S_NAMESPACE,
                    "delete",
                    "pod",
                    pod_name,
                    "--ignore-not-found",
                    "--wait=false",
                ],
                capture_output=True,
            )
        return

    # compose / k8s sandbox — unchanged path
    svc_exec(
        "ftsdb",
        [
            "mysql",
            "-h",
            "127.0.0.1",
            "--protocol=tcp",
            "-ufts",
            "-pfts",
            "fts",
            "-e",
            sql,
        ],
    )


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


def pytest_addoption(parser):
    parser.addoption(
        "--daemon-mode",
        action="store",
        default=os.environ.get("DAEMON_MODE", "direct"),
        choices=("direct", "daemons"),
        help="direct = invoke --run-once via CLI (deterministic); "
        "daemons = rely on long-running daemons, poll for state",
    )


@pytest.fixture(scope="session")
def daemon_mode(pytestconfig):
    return pytestconfig.getoption("--daemon-mode")


def _log_daemon_output(out: bytes, keywords=None) -> None:
    """Log interesting lines from a daemon's --run-once output."""
    keywords = keywords or ("warning", "error", "failed", "submit", "checksum")
    for line in out.decode(errors="replace").splitlines():
        if any(k in line.lower() for k in keywords):
            log.info("    | %s", line)


def advance_pipeline(
    rucio_svc="rucio-server", daemons=None, mode=None, keywords=None
) -> None:
    """Advance a Rucio pipeline.

    mode='direct'  : invoke each daemon with --run-once via svc_exec
                     (deterministic; current behaviour).
    mode='daemons' : rely on long-running daemons in the rucio-daemons
                     service — no-op here; validate_rule's polling waits
                     for the daemons to converge the rule.
    """
    mode = mode or DAEMON_MODE
    if mode == "daemons":
        return
    for cmd in daemons or DEFAULT_CONVEYOR:
        log.info("  → %s %s", rucio_svc, " ".join(cmd))
        out = svc_exec(rucio_svc, cmd)
        _log_daemon_output(out, keywords)


def run_daemons(rucio_svc: str = "rucio-server") -> None:
    """Back-compat wrapper: advance the conveyor pipeline."""
    advance_pipeline(rucio_svc, DEFAULT_CONVEYOR)


def validate_rule(
    client,
    rule_id: str,
    label: str,
    rucio_svc: str = "rucio-server",
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


# ── XRootD protocol-based seeding / dest-prep ──────────────────────────────


def _xrdfs_run(
    args: list, retries: int = 3, backoff: float = 3.0, **kwargs
) -> subprocess.CompletedProcess:
    """subprocess.run(["xrdfs", *args], ...) with retry-on-transient-TLS-error."""
    out = None
    for attempt in range(1, retries + 1):
        out = subprocess.run(["xrdfs", *args], **kwargs)
        stderr = out.stderr
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        stderr = stderr or ""
        if out.returncode == 0 or XRDFS_TRANSIENT_ERR not in stderr.lower():
            return out
        if attempt < retries:
            log.info(
                "  [%d/%d] transient xrdfs TLS error, retrying in %ss...",
                attempt,
                retries,
                backoff,
            )
            time.sleep(backoff)
    return out


def _xrdcp_run(
    args: list, retries: int = 3, backoff: float = 3.0, **kwargs
) -> subprocess.CompletedProcess:
    """subprocess.run(["xrdcp", *args], ...) with the same transient-TLS
    retry as _xrdfs_run. xrdcp is normally called with check=True, so its
    failure mode is CalledProcessError rather than a returncode — this
    catches that specifically instead of inspecting .returncode."""
    for attempt in range(1, retries + 1):
        try:
            return subprocess.run(["xrdcp", *args], **kwargs)
        except subprocess.CalledProcessError as e:
            stderr = e.stderr
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            stderr = stderr or ""
            if attempt < retries and XRDFS_TRANSIENT_ERR in stderr.lower():
                log.info(
                    "  [%d/%d] transient xrdcp TLS error, retrying in %ss...",
                    attempt,
                    retries,
                    backoff,
                )
                time.sleep(backoff)
                continue
            raise


def seed_xrd(svc: str, pfn: str, token: str = None) -> tuple[int, str]:
    """Seed a test file at the given PFN over HTTP/WebDAV (XRootD's
    libXrdHttp), matching how FTS itself performs the real transfer.
    `svc` is only used for logging."""
    content = b"rucio-test\n"
    url = pfn.replace(
        "davs://", "https://", 1
    )  # XRootD's HTTP listener speaks TLS on the same port
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    resp = requests.put(url, data=content, headers=headers, verify=False, timeout=30)
    resp.raise_for_status()

    # Read back to confirm the write actually landed, rather than trusting
    # a 2xx status alone.
    check = requests.get(url, headers=headers, verify=False, timeout=30)
    check.raise_for_status()
    if check.content != content:
        raise RuntimeError(f"seed_xrd: readback mismatch at {url}")

    adler = "%08x" % (zlib.adler32(content) & 0xFFFFFFFF)
    return len(content), adler


def prepare_xrd_dest(pfn: str, token: str = None) -> None:
    """Pre-create the destination directory via HTTP MKCOL, matching seed_xrd."""
    remote_dir_url = pfn.replace("davs://", "https://", 1).rsplit("/", 1)[0]
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    resp = requests.request(
        "MKCOL", remote_dir_url, headers=headers, verify=False, timeout=30
    )
    # 201 = created, 405/409 = already exists — both fine; anything else is real
    if resp.status_code not in (201, 405, 409):
        raise RuntimeError(
            f"prepare_xrd_dest failed for {remote_dir_url}: HTTP {resp.status_code} {resp.text}"
        )


def seed_and_register_files(
    client, rse: str, scope: str, names: list[str], seed_svc: str, token: str = None
) -> list[dict]:
    """Seed files into an XRootD RSE and return Rucio replica dicts."""
    registered = []
    for name in names:
        pfn = compute_pfn(client, rse, scope, name)
        size, adler32 = seed_xrd(seed_svc, pfn, token=token)
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
    client, rse: str, scope: str, names: list[str], token: str = None
) -> None:
    """Pre-create destination directories on an XRootD RSE for a list of DIDs."""
    for name in names:
        pfn = compute_pfn(client, rse, scope, name)
        prepare_xrd_dest(pfn, token=token)


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
    try:
        resp.raise_for_status()
    except requests.exceptions.HTTPError as e:
        raise requests.exceptions.HTTPError(
            f"{e}: {resp.text}", response=resp
        ) from None
    return resp.json()["access_token"]


def fetch_token_client_credentials(
    url: str,
    client_id: str,
    client_secret: str,
    scope: str = "openid",
    resource=None,  # str, list[str], or None
) -> str:
    data = {"grant_type": "client_credentials", "scope": scope}
    if resource:
        # EGI (RFC 8707): resource stamps the aud claim; audience= does not.
        # requests encodes a list value as repeated resource= form fields,
        # which is how RFC 8707 expresses multiple audiences in one request —
        # needed so a single Teapot token is valid against both teapot1 and
        # teapot2 (each has its own registered audience; a token scoped to
        # only one is rejected by the other).
        data["resource"] = resource
    resp = requests.post(
        url,
        data=data,
        auth=(client_id, client_secret),
        verify=False,
        timeout=10,
    )
    try:
        resp.raise_for_status()
    except requests.exceptions.HTTPError as e:
        raise requests.exceptions.HTTPError(
            f"{e}: {resp.text}", response=resp
        ) from None
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
    log.info("=== Warming up %s Storm-WebDAV instance ===", label)
    resp = None
    last_exc = None
    for attempt in range(1, retries + 1):
        try:
            resp = webdav_propfind(f"{base_url}{path}", token)
        except requests.exceptions.RequestException as e:
            last_exc = e
            log.info(
                "  [%d] %s request failed (%s) — retrying in %ds",
                attempt,
                label,
                e.__class__.__name__,
                interval,
            )
            time.sleep(interval)
            continue
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
        f"(last HTTP {resp.status_code if resp else 'N/A'}"
        f"{', last error: ' + str(last_exc) if last_exc else ''})"
    )


# ── Session-scoped fixtures ───────────────────────────────────────────────


@pytest.fixture(scope="session")
def rucio_client():
    """Rucio Python client (userpass, single OIDC instance)."""
    return make_client()


def _mint(scope: str, resource: str = None) -> str:
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


@pytest.fixture(scope="session")
def oidc_token():
    return _mint(OIDC_EXPECTED_SCOPE, resource=_rse_resource("xrd4"))


@pytest.fixture(scope="session")
def teapot_token():
    # On EGI, audience comes from resource=, NOT the aud:teapot* scope
    # (Keycloak-only syntax → invalid_scope). Keep aud: scope only for wlcg.
    #
    # This single token is used against BOTH teapot1 and teapot2 (see
    # teapots_ready below), so under client_credentials it must carry both
    # audiences — request resource= for each RSE rather than just teapot1.
    if OIDC_GRANT_TYPE == "client_credentials":
        return fetch_token_client_credentials(
            OIDC_TOKEN_URL,
            OIDC_CLIENT_ID,
            OIDC_CLIENT_SECRET,
            scope=OIDC_EXPECTED_SCOPE,
            resource=[_rse_resource("teapot1"), _rse_resource("teapot2")],
        )
    scope = " ".join(filter(None, [OIDC_EXPECTED_SCOPE, OIDC_TEAPOT_AUD_SCOPE]))
    return fetch_token_password(
        OIDC_TOKEN_URL,
        OIDC_CLIENT_ID,
        OIDC_CLIENT_SECRET,
        OIDC_USERNAME,
        OIDC_PASSWORD,
        scope=scope,
    )


@pytest.fixture(scope="session")
def teapots_ready(teapot_token):
    """Warm up both Teapot Storm-WebDAV JVMs before any transfer test runs."""
    webdav_warm_up(TEAPOT1_URL, "/data/", "teapot1", teapot_token)
    webdav_warm_up(TEAPOT2_URL, "/data/", "teapot2", teapot_token)
    return True


@pytest.fixture(scope="session")
def xrd3_write_token():
    """Token scoped for writing to XRD3 — needed by seed_xrd/prepare_xrd_dest
    now that both write over the real protocol (auth-enforced) instead of
    exec (auth-bypassing)."""
    return _mint(OIDC_EXPECTED_SCOPE, resource=_rse_resource("xrd3"))


@pytest.fixture(scope="session")
def xrd4_write_token():
    """Token scoped for writing to XRD4 — destination side of XRD3→XRD4
    transfers and the dataset tests; needed now that prepare_xrd_dest is
    protocol-based (auth-enforced) instead of exec-based."""
    return _mint(OIDC_EXPECTED_SCOPE, resource=_rse_resource("xrd4"))
