"""
test_rucio_public_ri.py — copies from public RI holdings into testbed storage.

One small, anonymously readable file per research infrastructure, at the same
URL the CERN RI-SCALE instance has registered (ENES_DKRZ, EBI_BIA_BIOSTUDIES).
Each run registers the file under a fresh name on the read-only source RSE
(non-deterministic, explicit PFN) and replicates it via FTS to both storage
implementations of the testbed: TEAPOT1 (StoRM WebDAV) and XRD3 (XRootD).

As on the CERN instance, FTS runs an HTTP-TPC pull: the destination fetches
the file from the public server itself. The sources are plain HTTPS download
servers (GET/HEAD only, no WebDAV), registered as https; the destinations use
davs, so the job still runs with tokens (see configure_public_ri_rses in
scripts/init-testbed.sh). Both destinations must trust the sources' public
roots (certs/public-roots, installed as trust anchors by `make certs`).

    make test-public-ri-transfers
"""

import logging
import os
import time
import urllib.request

import pytest

from conftest import (
    add_rule,
    compute_pfn,
    prepare_xrd_dest,
    register_replica,
    validate_rule,
)

log = logging.getLogger("test-public-ri")

SCOPE = "test"  # shared data lives in one scope (ADR-008)
RUCIO_SVC = "rucio-server"
DEST_RSES = ["TEAPOT1", "XRD3"]

# XRootD warm-up for every test in the module (session-scoped: runs once).
pytestmark = pytest.mark.usefixtures("xrootd_ready")

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


def _reachable(pfn):
    try:
        req = urllib.request.Request(pfn, method="HEAD")
        return urllib.request.urlopen(req, timeout=15).status == 200
    except Exception as e:  # network, TLS or HTTP error: not the testbed's fault
        log.warning("  source not reachable: %s (%s)", pfn, e)
        return False


@pytest.mark.parametrize("dest_rse", DEST_RSES)
@pytest.mark.parametrize("src_rse, pfn, size, adler32", HOLDINGS)
def test_public_ri_pull(
    rucio_client, teapots_ready, xrd3_write_token, src_rse, pfn, size, adler32, dest_rse
):
    """Replicate one public RI file to dest_rse (HTTP-TPC pull from the public server)."""
    if not _reachable(pfn):
        pytest.skip(f"{src_rse} source unreachable")

    name = f"{src_rse.lower()}-{dest_rse.lower()}-{int(time.time())}-{os.path.basename(pfn)}"
    log.info("[ %s → %s  name=%s ]", src_rse, dest_rse, name)

    if dest_rse.startswith("XRD"):
        # XRootD needs the destination directory up front (auth-enforced).
        dst_pfn = compute_pfn(rucio_client, dest_rse, SCOPE, name)
        prepare_xrd_dest(dst_pfn, token=xrd3_write_token)

    register_replica(rucio_client, src_rse, SCOPE, name, pfn, size, adler32)
    rule_id = add_rule(rucio_client, SCOPE, name, dest_rse)

    validate_rule(rucio_client, rule_id, f"{src_rse}→{dest_rse}", RUCIO_SVC)
