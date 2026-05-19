"""
test_rucio_transfers.py — OIDC end-to-end transfer tests for dep-dlm-testbed.

Covers:
  - XRootD SciTokens TPC:  XRD3  → XRD4    (davs/SciTokens, FTS OIDC)
  - Teapot WebDAV TPC:     TEAPOT1 → TEAPOT2 (davs/bearer token, FTS OIDC)

Prerequisites (handled by bootstrap-testbed.sh):
  - RSEs XRD3, XRD4, TEAPOT1, TEAPOT2 registered with OIDC attributes
  - FTS t_token_provider seeded with keycloak-rucio issuer entries
  - Rucio accounts ddmlab / randomaccount with quota on all four RSEs

Typical invocations:
    # Compose
    docker exec compose-rucio-client-1 \\
        bash -c "RUNTIME=compose pytest /tests/test_rucio_transfers.py -v"

    # Kubernetes
    kubectl -n dep-dlm-testbed exec deploy/rucio-client -- \\
        bash -c "RUNTIME=k8s K8S_NAMESPACE=dep-dlm-testbed pytest /tests/test_rucio_transfers.py -v"
"""

import binascii
import logging
import time
import zlib
from urllib.parse import urlparse

from conftest import (
    TEAPOT1_URL,
    add_rule,
    compute_pfn,
    prepare_xrd_dest,
    register_replica,
    run_daemons,
    seed_xrd,
    validate_rule,
    webdav_delete,
    webdav_get,
    webdav_put,
)

log = logging.getLogger("test-transfers")

SCOPE = "ddmlab"
RUCIO_SVC = "rucio"


# ── XRootD SciTokens: XRD3 → XRD4 ───────────────────────────────────────

class TestXRootDOIDC:
    """
    XRootD SciTokens TPC via FTS OIDC.

    The transfer uses davs:// (HTTP-TPC) rather than xroot:// because
    XRootD SciTokens auth for third-party copy requires HTTP/WebDAV.
    FTS issues a storage.read + storage.modify token from Keycloak
    (audience: https://xrd3:1094 / https://xrd4:1094) and performs
    an HTTP COPY between the two XRootD endpoints.

    To answer Andrea Manzi's question: the XRootD TPC here uses the
    HTTP protocol (davs://), not the native xroot:// protocol. XRootD
    exposes an HTTP interface via the xrd.protocol http:1094 directive
    in xrdrucio-scitokens.cfg, and SciTokens validation is done by
    the libXrdAccSciTokens.so plugin on the server side. FTS submits
    the job with the davs:// PFN and a Bearer token; the two XRootD
    nodes then perform an HTTP COPY (TPC pull).
    """

    def test_xrd3_to_xrd4(self, rucio_client):
        """Replicate a file from XRD3 to XRD4 via SciTokens + FTS OIDC."""
        name = f"xrd-oidc-{int(time.time())}"
        log.info("[ XRD3 → XRD4  name=%s ]", name)

        # Compute PFNs
        src_pfn = compute_pfn(rucio_client, "XRD3", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "XRD4", SCOPE, name)
        log.info("  src PFN: %s", src_pfn)
        log.info("  dst PFN: %s", dst_pfn)

        # Seed source file inside the xrd3 container
        size, adler32 = seed_xrd("xrd3", src_pfn)
        log.info("  seeded %d bytes  adler32=%s", size, adler32)

        # Pre-create destination directory
        prepare_xrd_dest("xrd4", dst_pfn)

        # Register replica and create replication rule
        register_replica(rucio_client, "XRD3", SCOPE, name, src_pfn, size, adler32)
        rule_id = add_rule(rucio_client, SCOPE, name, "XRD4")

        # Advance conveyor pipeline and poll until done
        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "XRD3→XRD4 SciTokens", RUCIO_SVC)


# ── Teapot WebDAV: TEAPOT1 → TEAPOT2 ─────────────────────────────────────

class TestTeapotOIDC:
    """
    Teapot WebDAV OIDC TPC via FTS OIDC.

    Teapot is a multi-tenancy WebDAV proxy that sits in front of
    per-user Storm-WebDAV JVMs. It validates bearer tokens issued by
    Keycloak (audience: teapot). FTS performs an HTTP COPY (TPC pull)
    between teapot1 and teapot2 using a token it obtains from Keycloak
    via the t_token_provider entry registered during bootstrap.

    Source file is seeded via an authenticated WebDAV PUT (no filesystem
    exec available for Teapot) rather than svc_exec/seed.
    """

    def test_teapot1_to_teapot2(self, rucio_client, oidc_token, teapots_ready):
        """Replicate a file from TEAPOT1 to TEAPOT2 via bearer token + FTS OIDC."""
        name = f"teapot-{int(time.time())}"
        seed_content = b"rucio-teapot-oidc-test\n"
        log.info("[ TEAPOT1 → TEAPOT2  name=%s ]", name)

        # Compute PFNs
        src_pfn = compute_pfn(rucio_client, "TEAPOT1", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "TEAPOT2", SCOPE, name)
        log.info("  src PFN: %s", src_pfn)
        log.info("  dst PFN: %s", dst_pfn)

        # Derive the WebDAV path from the PFN
        src_path = urlparse(src_pfn).path   # e.g. /data/ddmlab/ab/cd/teapot-...

        # Clean up any stale file from a previous run
        webdav_delete(f"{TEAPOT1_URL}{src_path}", oidc_token)

        # Seed via authenticated WebDAV PUT
        resp = webdav_put(f"{TEAPOT1_URL}{src_path}", oidc_token, seed_content)
        assert resp.status_code in {200, 201, 204}, (
            f"Seed PUT returned HTTP {resp.status_code}: {resp.text[:200]}"
        )
        log.info("  ✓ Seeded via WebDAV PUT (HTTP %s)", resp.status_code)

        # Verify seed is readable
        verify = webdav_get(f"{TEAPOT1_URL}{src_path}", oidc_token)
        assert verify.status_code == 200, (
            f"Seed not readable: GET {TEAPOT1_URL}{src_path} → HTTP {verify.status_code}"
        )
        log.info("  ✓ Seed confirmed readable (HTTP 200)")

        # Compute checksum locally (Teapot PROPFIND does not expose adler32)
        adler32 = binascii.hexlify(
            zlib.adler32(seed_content).to_bytes(4, "big")
        ).decode()
        size = len(seed_content)

        # Register replica and create replication rule
        register_replica(rucio_client, "TEAPOT1", SCOPE, name, src_pfn, size, adler32)
        rule_id = add_rule(rucio_client, SCOPE, name, "TEAPOT2")

        # Advance conveyor pipeline and poll until done
        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "TEAPOT1→TEAPOT2 WebDAV OIDC", RUCIO_SVC)