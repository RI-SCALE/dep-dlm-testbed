"""
Post-deploy smoke tests for deploy/terraform/environments/<TF_ENV>.

Run after `make tf-apply` (and `make tf-kubeconfig`):
    TF_ENV=staging pytest deploy/terraform/tests/test_deployed_infra.py -v

Everything is sourced from `terraform output -json` — no hardcoded project
IDs, instance names, or secret paths — so this stays correct across staging/
production and across bootstrap re-applies (which regenerate project
suffixes). Requires:
    pip install pytest google-cloud-secret-manager --break-system-packages

DB connectivity checks run as one-shot `kubectl run` pods, not a direct
client connection — Cloud SQL has no public IP (ipv4_enabled = false),
and there's no route to the private IP from outside the cluster's VPC
(confirmed: the Cloud SQL Python Connector's ip_type="PRIVATE" doesn't
help either, since it still needs a real network path — it only skips
looking for a *public* IP). Running the check as a pod inside the
cluster gives it the same network path Rucio/FTS pods actually use,
and works identically whether this is run locally or in CI.
"""

import json
import os
import subprocess
import time

import pytest
from google.cloud import secretmanager

TF_ENV = os.environ.get("TF_ENV", "staging")
TF_DIR = f"deploy/terraform/environments/{TF_ENV}"
EXPECTED_KEYS = {
    "certs": {"hostcert.pem", "hostkey.pem", "rucio_ca.pem"},
    "secrets": {"server.cfg", "idpsecrets.json", "fts3config"},
}
DB_CHECK_RETRIES = 1
DB_CHECK_BACKOFF_S = 15
GATEWAY_CHECK_RETRIES = 3
GATEWAY_CHECK_BACKOFF_S = 20


@pytest.fixture(scope="session")
def tf_outputs():
    result = subprocess.run(
        ["terraform", f"-chdir={TF_DIR}", "output", "-json"],
        capture_output=True,
        text=True,
        check=True,
    )
    return {k: v["value"] for k, v in json.loads(result.stdout).items()}


@pytest.fixture(scope="session")
def secret_client():
    return secretmanager.SecretManagerServiceClient()


# --- secrets -----------------------------------------------------------
# Deliberately NOT retried — a missing key or empty value is a real,
# deterministic bug, not transient flakiness. Retrying would just delay
# reporting it.


@pytest.mark.parametrize("secret_name", EXPECTED_KEYS.keys())
def test_secret_populated_with_expected_keys(tf_outputs, secret_client, secret_name):
    secret_id = tf_outputs["secret_ids"][secret_name]
    version = secret_client.access_secret_version(name=f"{secret_id}/versions/latest")
    payload = version.payload.data.decode("utf-8")
    assert payload, f"{secret_name} secret is empty"

    data = json.loads(payload)  # every secret here is a jsonencode() blob
    missing = EXPECTED_KEYS[secret_name] - data.keys()
    assert not missing, f"{secret_name} missing expected keys: {missing}"
    assert all(v.strip() for v in data.values()), f"{secret_name} has an empty value"


def test_rucio_cfg_points_at_rucio_database(tf_outputs, secret_client):
    secret_id = tf_outputs["secret_ids"]["secrets"]
    version = secret_client.access_secret_version(name=f"{secret_id}/versions/latest")
    data = json.loads(version.payload.data.decode("utf-8"))
    assert tf_outputs["rucio_database_private_ip"] in data["server.cfg"]


# --- database connectivity (via kubectl, see module docstring) -----------


def _run_db_check_pod_once(pod_name, image, *cmd_args):
    # Clear any stale pod from a previous run whose cleanup didn't
    # complete — `kubectl run` fails outright if the name already exists.
    subprocess.run(
        ["kubectl", "delete", "pod", pod_name, "--ignore-not-found"],
        capture_output=True,
    )
    try:
        run = subprocess.run(
            [
                "kubectl",
                "run",
                pod_name,
                f"--image={image}",
                "--restart=Never",
                "--command",
                "--",
                *cmd_args,
            ],
            capture_output=True,
            text=True,
        )
        assert run.returncode == 0, f"kubectl run {pod_name} failed: {run.stderr}"

        wait = subprocess.run(
            [
                "kubectl",
                "wait",
                "--for=jsonpath={.status.phase}=Succeeded",
                f"pod/{pod_name}",
                "--timeout=150s",
            ],
            capture_output=True,
            text=True,
        )
        logs = subprocess.run(
            ["kubectl", "logs", pod_name], capture_output=True, text=True
        ).stdout
        assert wait.returncode == 0, (
            f"{pod_name} didn't reach Succeeded — logs:\n{logs}"
        )
        return logs
    finally:
        subprocess.run(
            ["kubectl", "delete", "pod", pod_name, "--ignore-not-found"],
            capture_output=True,
        )


def _run_db_check_pod(pod_name, image, *cmd_args):
    last_error = None
    for attempt in range(1, DB_CHECK_RETRIES + 2):
        try:
            return _run_db_check_pod_once(pod_name, image, *cmd_args)
        except AssertionError as e:
            last_error = e
            if attempt <= DB_CHECK_RETRIES:
                time.sleep(DB_CHECK_BACKOFF_S)
    raise last_error


def test_rucio_database_connection(tf_outputs):
    dsn = (
        f"postgresql://rucio:{tf_outputs['rucio_db_password']}"
        f"@{tf_outputs['rucio_database_private_ip']}/rucio"
    )
    logs = _run_db_check_pod(
        "db-test-rucio", "postgres:16", "psql", dsn, "-c", "SELECT 1;"
    )
    assert "1" in logs


def test_fts_database_connection(tf_outputs):
    logs = _run_db_check_pod(
        "db-test-fts",
        "mysql:8",
        "mysql",
        "-h",
        tf_outputs["fts_database_private_ip"],
        "-u",
        "fts",
        f"-p{tf_outputs['fts_db_password']}",
        "fts",
        "-e",
        "SELECT 1;",
    )
    assert "1" in logs


# --- kubeconfig ----------------------------------------------------------


def test_kubeconfig_can_reach_cluster(tf_outputs):
    # Assumes `make tf-kubeconfig TF_ENV=...` already ran — this only
    # checks the resulting context actually works, doesn't fetch it itself.
    # Listing namespaces (not nodes) deliberately: GKE Autopilot provisions
    # nodes lazily on first scheduled pod, so `kubectl get nodes` can be
    # empty even on a perfectly healthy, reachable cluster.
    result = subprocess.run(
        ["kubectl", "get", "ns"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"kubectl can't reach the cluster — run 'make tf-kubeconfig TF_ENV={TF_ENV}' "
        f"first. stderr: {result.stderr}"
    )
    assert "default" in result.stdout

    # Catches the "wrong context selected" mistake specifically — e.g.
    # still pointed at staging while testing production, or vice versa.
    ctx = subprocess.run(
        ["kubectl", "config", "current-context"],
        capture_output=True,
        text=True,
    )
    assert tf_outputs["cluster_name"] in ctx.stdout, (
        f"current kubectl context ({ctx.stdout.strip()!r}) doesn't reference "
        f"{TF_ENV}'s cluster ({tf_outputs['cluster_name']!r}) — wrong context "
        f"selected? run 'make tf-kubeconfig TF_ENV={TF_ENV}' again"
    )


# --- public gateway reachability ------------------------------------------


def _check_gateway_endpoint(scheme, ip, hostname, path, expected_status=200):
    import requests

    url = f"{scheme}://{ip}{path}"
    last_error = None
    for attempt in range(1, GATEWAY_CHECK_RETRIES + 2):
        try:
            resp = requests.get(
                url, headers={"Host": hostname}, timeout=10, verify=False
            )
            assert resp.status_code == expected_status, (
                f"{hostname}{path} via gateway {ip} returned "
                f"{resp.status_code}, expected {expected_status}"
            )
            return resp
        except (requests.RequestException, AssertionError) as e:
            last_error = e
            if attempt <= GATEWAY_CHECK_RETRIES:
                time.sleep(GATEWAY_CHECK_BACKOFF_S)
    raise last_error


def test_rucio_server_gateway_reachable(tf_outputs):
    _check_gateway_endpoint(
        "http",
        tf_outputs["gateway_static_ip"],
        tf_outputs["rucio_public_hostname"],
        "/ping",
    )


def test_fts_gateway_reachable(tf_outputs):
    _check_gateway_endpoint(
        "http",
        tf_outputs["gateway_static_ip"],
        tf_outputs["fts_public_hostname"],
        "/whoami",
    )
