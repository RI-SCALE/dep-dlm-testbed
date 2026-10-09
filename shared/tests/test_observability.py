"""Observability smoke test (design-doc-005, phases 1-2).

Runs inside the rucio-client container/pod like the other tests.
Contract with shared/config/observability/:
  - Prometheus scrape jobs are named "rucio-server" and "rucio-daemons".
  - Alloy labels every log stream with service=<compose service / app name>.
"""

import json
import os
import time
import urllib.parse
import urllib.request

import pytest

PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")
LOKI_URL = os.environ.get("LOKI_URL", "http://loki:3100")
DAEMON_MODE = os.environ.get("DAEMON_MODE", "direct")
TIMEOUT_S = int(os.environ.get("OBSERVABILITY_TIMEOUT", "180"))


def _get(url, params=None):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=10) as resp:
        return json.load(resp)


def _wait_for(check, what):
    """Poll check() until it returns a truthy value or TIMEOUT_S passes."""
    deadline = time.time() + TIMEOUT_S
    last = None
    while time.time() < deadline:
        try:
            result = check()
            if result:
                return result
        except Exception as exc:  # endpoint not up yet
            last = exc
        time.sleep(5)
    pytest.fail(f"{what} not satisfied after {TIMEOUT_S}s (last error: {last})")


def _expected_jobs():
    jobs = ["rucio-server"]
    # Daemons only run long-lived (and expose metrics) in DAEMON_MODE=daemons.
    if DAEMON_MODE == "daemons":
        jobs.append("rucio-daemons")
    return jobs


@pytest.mark.parametrize("job", _expected_jobs())
def test_prometheus_target_up(job):
    def check():
        data = _get(f"{PROMETHEUS_URL}/api/v1/targets", {"state": "active"})
        targets = [
            t for t in data["data"]["activeTargets"] if t["labels"].get("job") == job
        ]
        return targets and all(t["health"] == "up" for t in targets)

    _wait_for(check, f"Prometheus job {job!r} up")


@pytest.mark.parametrize("job", _expected_jobs())
def test_prometheus_has_rucio_series(job):
    # A reachable but empty endpoint would still be "up"; require real series.
    query = f'count({{job="{job}", __name__!~"up|scrape_.*"}})'

    def check():
        data = _get(f"{PROMETHEUS_URL}/api/v1/query", {"query": query})
        result = data["data"]["result"]
        return result and float(result[0]["value"][1]) > 0

    _wait_for(check, f"Rucio metric series for job {job!r}")


def test_loki_has_rucio_server_logs():
    def check():
        now = time.time_ns()
        data = _get(
            f"{LOKI_URL}/loki/api/v1/query_range",
            {
                "query": '{service="rucio-server"}',
                "start": now - 15 * 60 * 10**9,
                "end": now,
                "limit": 1,
            },
        )
        return data["data"]["result"]

    _wait_for(check, "rucio-server log lines in Loki")
