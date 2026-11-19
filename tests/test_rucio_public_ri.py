"""
test_rucio_public_ri.py — copies from public RI holdings into testbed storage.

One small, anonymously readable file per research infrastructure, at the same
URL the CERN RI-SCALE instance has registered (ENES_DKRZ, EBI_BIA_BIOSTUDIES).
Each run registers the file under a fresh name on the read-only source RSE
(non-deterministic, explicit PFN) and replicates it to TEAPOT1 via FTS.

The sources are plain HTTPS download servers (GET/HEAD only, no WebDAV), so
they are registered as https and FTS streams the file instead of a
third-party copy (force_streamed_teapot1, as for COPERNICUS_S3); the
destination uses davs, so the job still runs with tokens (see
configure_public_ri_rses in scripts/init-testbed.sh).

Opt-in, like COPERNICUS_S3: needs `make init PUBLIC_RI=1` and outbound HTTPS.

    make test-public-ri-transfers
"""

import logging
import os
import time
import urllib.request
from urllib.parse import urlparse

import pytest

from conftest import (
    TEAPOT1_URL,
    add_rule,
    fts_mysql_exec,
    register_replica,
    run_daemons,
    validate_rule,
)

log = logging.getLogger("test-public-ri")

SCOPE = "test"  # shared data lives in one scope (ADR-008)
RUCIO_SVC = "rucio-server"
DEST_RSE = "TEAPOT1"

# (source RSE, PFN, bytes, adler32): verified 2026-11-19 with curl + zlib.adler32
HOLDINGS = [
    pytest.param(
        "ENES_DKRZ",
        "https://esgf3.dkrz.de:443/thredds/fileServer/cmip6/AerChemMIP/CNRM-CERFACS/"
        "CNRM-ESM2-1/hist-1950HC/r1i1p1f2/fx/sftlf/gr/v20190621/"
        "sftlf_fx_CNRM-ESM2-1_hist-1950HC_r1i1p1f2_gr.nc",
        53605,
        "28daee93",
        id="enes-cmip6-sftlf",
    ),
    pytest.param(
        "EBI_BIA_BIOSTUDIES",
        "https://ftp.ebi.ac.uk:443/biostudies/fire/S-BIAD/822/S-BIAD2822/S-BIAD2822.tsv",
        5371,
        "5c764f2d",
        id="ebi-bia-s-biad2822",
    ),
]

pytestmark = pytest.mark.skipif(
    os.environ.get("PUBLIC_RI") != "1", reason="PUBLIC_RI=1 not set"
)


@pytest.fixture
def force_streamed_teapot1():
    """
    Stream through FTS instead of a third-party copy. FTS pulls when the
    destination allows it and pushes when the source does (a missing t_se
    row counts as FULL); the public sources are plain download servers (405
    on COPY), so mark TEAPOT1 and every source host tpc_support=NONE and
    restore afterwards. Same approach as force_streamed_teapot2 in
    test_rucio_transfers_with_copernicus.py.
    """
    hosts = [urlparse(TEAPOT1_URL).hostname] + [
        urlparse(h.values[1]).hostname for h in HOLDINGS
    ]
    storages = [f"{scheme}://{host}" for host in hosts for scheme in ("davs", "https")]
    values = ",".join(f"('{s}','NONE')" for s in storages)
    in_list = ",".join(f"'{s}'" for s in storages)
    fts_mysql_exec(
        f"INSERT INTO t_se (storage, tpc_support) VALUES {values} "
        "ON DUPLICATE KEY UPDATE tpc_support='NONE';"
    )
    yield
    fts_mysql_exec(f"DELETE FROM t_se WHERE storage IN ({in_list});")


def _reachable(pfn):
    try:
        req = urllib.request.Request(pfn, method="HEAD")
        return urllib.request.urlopen(req, timeout=15).status == 200
    except Exception as e:  # network, TLS or HTTP error: not the testbed's fault
        log.warning("  source not reachable: %s (%s)", pfn, e)
        return False


@pytest.mark.parametrize("src_rse, pfn, size, adler32", HOLDINGS)
def test_public_ri_to_teapot(
    rucio_client, teapots_ready, force_streamed_teapot1, src_rse, pfn, size, adler32
):
    """Replicate one public RI file to TEAPOT1 (FTS streams it from the public server)."""
    if not _reachable(pfn):
        pytest.skip(f"{src_rse} source unreachable")

    name = f"{src_rse.lower()}-{int(time.time())}-{os.path.basename(pfn)}"
    log.info("[ %s → %s  name=%s ]", src_rse, DEST_RSE, name)

    register_replica(rucio_client, src_rse, SCOPE, name, pfn, size, adler32)
    rule_id = add_rule(rucio_client, SCOPE, name, DEST_RSE)

    run_daemons(RUCIO_SVC)
    validate_rule(rucio_client, rule_id, f"{src_rse}→{DEST_RSE}", RUCIO_SVC)
