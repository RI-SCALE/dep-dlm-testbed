"""Observability smoke test (design-doc-005, phases 1-2).

Runs inside the rucio-client container/pod like the other tests, against
either backend:
  - prometheus (Compose, sandbox): in-cluster Prometheus and Loki.
  - gmp (staging, production): Managed Service for Prometheus and Cloud
    Logging, authenticated with GCP_ACCESS_TOKEN.

Contract with configs/observability/:
  - Scrape jobs are named "rucio-server", "fts" and "rucio-db"
    (PodMonitoring names on GKE).
  - Loki streams carry service=<compose service / app name>; on GKE the
    container name identifies the service.
"""

import datetime
import json
import os
import time
import urllib.parse
import urllib.request

import pytest

BACKEND = os.environ.get("OBSERVABILITY_BACKEND", "prometheus")  # prometheus | gmp
GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "")
GCP_ACCESS_TOKEN = os.environ.get("GCP_ACCESS_TOKEN", "")
K8S_NAMESPACE = os.environ.get("K8S_NAMESPACE", "dep-dlm-staging")
TIMEOUT_S = int(os.environ.get("OBSERVABILITY_TIMEOUT", "180"))

if BACKEND == "gmp":
    PROMETHEUS_URL = (
        "https://monitoring.googleapis.com/v1/projects/"
        f"{GCP_PROJECT_ID}/location/global/prometheus"
    )
else:
    PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")
LOKI_URL = os.environ.get("LOKI_URL", "http://loki:3100")


def _request(url, params=None, body=None):
    headers = (
        {"Authorization": f"Bearer {GCP_ACCESS_TOKEN}"} if GCP_ACCESS_TOKEN else {}
    )
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def _query(promql):
    return _request(f"{PROMETHEUS_URL}/api/v1/query", {"query": promql})["data"][
        "result"
    ]


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


# `up` works on both backends (GMP has no /api/v1/targets).
@pytest.mark.parametrize("job", ["rucio-server", "fts", "rucio-db"])
def test_scrape_target_up(job):
    def check():
        result = _query(f'min(up{{job="{job}"}})')
        if not (result and float(result[0]["value"][1]) == 1):
            raise RuntimeError(f"up{{job={job!r}}} = {result}")
        return True

    _wait_for(check, f"scrape job {job!r} up")


# FTS series only exist once t_file has rows, so only Rucio is checked here.
# Exact metric name: Managed Prometheus rejects regex/negative __name__ matchers.
# Rucio creates it on the first rule, so run this after the transfer tests.
@pytest.mark.parametrize("job", ["rucio-server"])
def test_rucio_series_present(job):
    # A reachable but empty endpoint would still be "up"; require real series.
    query = f'count(rucio_core_rule_add_rule_apply_rule_count{{job="{job}"}})'

    def check():
        result = _query(query)
        return result and float(result[0]["value"][1]) > 0

    _wait_for(check, f"Rucio metric series for job {job!r}")


def test_rucio_server_logs():
    if BACKEND == "gmp":
        since = (
            datetime.datetime.now(datetime.timezone.utc)
            - datetime.timedelta(minutes=15)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        log_filter = (
            'resource.type="k8s_container" '
            f'resource.labels.namespace_name="{K8S_NAMESPACE}" '
            'resource.labels.container_name="rucio-server" '
            f'timestamp>="{since}"'
        )

        def check():
            data = _request(
                "https://logging.googleapis.com/v2/entries:list",
                body={
                    "resourceNames": [f"projects/{GCP_PROJECT_ID}"],
                    "filter": log_filter,
                    "pageSize": 1,
                },
            )
            return data.get("entries")

        _wait_for(check, "rucio-server log entries in Cloud Logging")
        return

    def check():
        now = time.time_ns()
        data = _request(
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
