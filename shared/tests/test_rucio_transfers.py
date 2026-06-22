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
    kubectl -n dep-dlm-sandbox exec deploy/rucio-client -- \\
        bash -c "RUNTIME=k8s K8S_NAMESPACE=dep-dlm-sandbox pytest /tests/test_rucio_transfers.py -v"
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
    prepare_xrd_dest_files,
    register_replica,
    run_daemons,
    seed_and_register_files,
    seed_xrd,
    validate_rule,
    webdav_delete,
    webdav_get,
    webdav_put,
)

log = logging.getLogger("test-transfers")

SCOPE = "ddmlab"
RUCIO_SVC = "rucio-server"


# ── XRootD SciTokens: XRD3 → XRD4 ───────────────────────────────────────


class TestXRootDOIDC:
    """
    XRootD SciTokens TPC via FTS OIDC.

    The transfer uses davs:// (HTTP-TPC) rather than xroot:// because
    XRootD SciTokens auth for third-party copy requires HTTP/WebDAV.
    FTS issues a storage.read + storage.modify token from Keycloak
    (audience: xrd3 / xrd4) and performs
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

    def test_teapot1_to_teapot2(self, rucio_client, teapot_token, teapots_ready):
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
        src_path = urlparse(src_pfn).path  # e.g. /data/ddmlab/ab/cd/teapot-...

        # Clean up any stale file from a previous run
        webdav_delete(f"{TEAPOT1_URL}{src_path}", teapot_token)

        # Seed via authenticated WebDAV PUT
        resp = webdav_put(f"{TEAPOT1_URL}{src_path}", teapot_token, seed_content)
        assert resp.status_code in {200, 201, 204}, (
            f"Seed PUT returned HTTP {resp.status_code}: {resp.text[:200]}"
        )
        log.info("  ✓ Seeded via WebDAV PUT (HTTP %s)", resp.status_code)

        # Verify seed is readable
        verify = webdav_get(f"{TEAPOT1_URL}{src_path}", teapot_token)
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


# ── Cross-protocol: XRootD SciTokens ↔ Teapot WebDAV ─────────────────────


class TestCrossProtocolOIDC:
    """
    Cross-protocol OIDC TPC via FTS OIDC.

    These tests exercise FTS obtaining tokens for two different audiences
    simultaneously:
      - XRD3 audience:    xrd3  (SciTokens)
      - TEAPOT1 audience: teapot             (WebDAV bearer)

    FTS uses the t_token_provider Keycloak entry to perform token exchange
    for each endpoint independently. The HTTP COPY is still davs:// on both
    sides since XRootD exposes HTTP on port 1094. This is the first validation
    of cross-protocol cross-audience TPC in the dep-dlm-testbed.
    """

    def test_xrd3_to_teapot1(self, rucio_client, teapots_ready):
        """XRD3 (SciTokens) → TEAPOT1 (WebDAV): seed via xrd3 exec, dest via Teapot."""
        name = f"xrd-to-teapot-{int(time.time())}"
        log.info("[ XRD3 → TEAPOT1  name=%s ]", name)

        # Compute PFNs
        src_pfn = compute_pfn(rucio_client, "XRD3", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "TEAPOT1", SCOPE, name)
        log.info("  src PFN: %s", src_pfn)
        log.info("  dst PFN: %s", dst_pfn)

        # Seed source file inside the xrd3 container
        size, adler32 = seed_xrd("xrd3", src_pfn)
        log.info("  seeded %d bytes  adler32=%s", size, adler32)

        # Register replica and create replication rule
        register_replica(rucio_client, "XRD3", SCOPE, name, src_pfn, size, adler32)
        rule_id = add_rule(rucio_client, SCOPE, name, "TEAPOT1")

        # Advance conveyor pipeline and poll until done
        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "XRD3→TEAPOT1 cross-protocol", RUCIO_SVC)

    def test_teapot1_to_xrd3(self, rucio_client, teapot_token, teapots_ready):
        """TEAPOT1 (WebDAV) → XRD3 (SciTokens): seed via WebDAV PUT, dest via xrd3 exec."""
        name = f"teapot-to-xrd-{int(time.time())}"
        seed_content = b"rucio-teapot-to-xrd-test\n"
        log.info("[ TEAPOT1 → XRD3  name=%s ]", name)

        # Compute PFNs
        src_pfn = compute_pfn(rucio_client, "TEAPOT1", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "XRD3", SCOPE, name)
        log.info("  src PFN: %s", src_pfn)
        log.info("  dst PFN: %s", dst_pfn)

        # Seed via authenticated WebDAV PUT
        src_path = urlparse(src_pfn).path
        webdav_delete(f"{TEAPOT1_URL}{src_path}", teapot_token)
        resp = webdav_put(f"{TEAPOT1_URL}{src_path}", teapot_token, seed_content)
        assert resp.status_code in {200, 201, 204}, (
            f"Seed PUT returned HTTP {resp.status_code}: {resp.text[:200]}"
        )
        log.info("  ✓ Seeded via WebDAV PUT (HTTP %s)", resp.status_code)

        verify = webdav_get(f"{TEAPOT1_URL}{src_path}", teapot_token)
        assert verify.status_code == 200, (
            f"Seed not readable: GET {TEAPOT1_URL}{src_path} → HTTP {verify.status_code}"
        )
        log.info("  ✓ Seed confirmed readable (HTTP 200)")

        # Pre-create destination directory on xrd3
        prepare_xrd_dest("xrd3", dst_pfn)

        # Compute checksum locally
        adler32 = binascii.hexlify(
            zlib.adler32(seed_content).to_bytes(4, "big")
        ).decode()
        size = len(seed_content)

        # Register replica and create replication rule
        register_replica(rucio_client, "TEAPOT1", SCOPE, name, src_pfn, size, adler32)
        rule_id = add_rule(rucio_client, SCOPE, name, "XRD3")

        # Advance conveyor pipeline and poll until done
        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "TEAPOT1→XRD3 cross-protocol", RUCIO_SVC)


# ── Dataset operations: XRD3 ──────────────────────────────────────────────


class TestDatasetOIDC:
    """
    Rucio dataset registration and replication via XRD3→XRD4 (OIDC).

    Demonstrates the two dataset population patterns:
      - add_dataset: atomically create a dataset with its initial replicas
      - add_files_to_dataset: extend an existing dataset with new replicas
    """

    def test_add_dataset(self, rucio_client):
        """Register two files into a new dataset on XRD3, replicate to XRD4."""
        ts = int(time.time())
        dataset = f"oidc-dataset-{ts}"
        names = [f"{dataset}-file1", f"{dataset}-file2"]
        log.info("[ add_dataset: XRD3 (seed 2 files) → XRD4 ]")

        registered = seed_and_register_files(rucio_client, "XRD3", SCOPE, names, "xrd3")
        prepare_xrd_dest_files(rucio_client, "XRD4", "xrd4", SCOPE, names)

        log.info(
            "  Creating dataset %s:%s with %d files", SCOPE, dataset, len(registered)
        )
        rucio_client.add_dataset(
            scope=SCOPE, name=dataset, rse="XRD3", files=registered
        )
        log.info("  ✓ Dataset registered")

        rule_id = add_rule(rucio_client, SCOPE, dataset, "XRD4")
        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "add_dataset XRD3→XRD4", RUCIO_SVC)

    def test_add_files_to_dataset(self, rucio_client):
        """Append two files to an existing dataset on XRD3, replicate to XRD4."""
        ts = int(time.time())
        dataset = f"oidc-existing-dataset-{ts}"
        names = [f"{dataset}-v2-file1", f"{dataset}-v2-file2"]
        log.info("[ add_files_to_dataset: extend existing dataset → XRD4 ]")

        rucio_client.add_dataset(scope=SCOPE, name=dataset)
        log.info("  Created empty dataset %s:%s", SCOPE, dataset)

        registered = seed_and_register_files(rucio_client, "XRD3", SCOPE, names, "xrd3")
        prepare_xrd_dest_files(rucio_client, "XRD4", "xrd4", SCOPE, names)

        log.info("  Appending %d files to %s:%s", len(registered), SCOPE, dataset)
        rucio_client.add_files_to_dataset(
            scope=SCOPE, name=dataset, rse="XRD3", files=registered
        )
        log.info("  ✓ Files appended")

        rule_id = add_rule(rucio_client, SCOPE, dataset, "XRD4")
        run_daemons(RUCIO_SVC)
        validate_rule(
            rucio_client, rule_id, "add_files_to_dataset XRD3→XRD4", RUCIO_SVC
        )
