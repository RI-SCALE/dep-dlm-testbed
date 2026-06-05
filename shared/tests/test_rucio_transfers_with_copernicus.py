import logging
import os
import time

from conftest import (
    TEAPOT2_URL,
    add_rule,
    register_replica,
    run_daemons,
    validate_rule,
    webdav_delete,
    svc_exec,
)

import boto3
import zlib

import pytest

log = logging.getLogger("test-transfers")

SCOPE = "ddmlab"
RUCIO_SVC = "rucio"
FTS_SVC = "fts"

COPERNICUS_S3 = "COPERNICUS_S3"
COPERNICUS_ENDPOINT = "eodata.dataspace.copernicus.eu"
COPERNICUS_BUCKET = "eodata"

COPERNICUS_TEST_KEY = (
    "Sentinel-1/SAR/SLC/2019/10/13/"
    "S1B_IW_SLC__1SDV_20191013T155948_20191013T160015_018459_022C6B_13A2.SAFE/"
    "manifest.safe"
)


@pytest.fixture
def force_streamed_teapot2():
    """
    Force STREAMED copy mode for S3->TEAPOT2 by marking the destination SE
    tpc_support=NONE. getCopyMode() reaches CopyMode::STREAMING only when the
    DESTINATION is not FULL/PULL. Scoped to this test and torn down so the
    davs<->davs TPC tests (test_rucio_transfers.py) keep their pull behaviour.

    TEAPOT2 is registered with both davs and https protocols, and FTS records
    the SE without a port (davs://teapot2, https://teapot2), so both forms
    must be set.
    """
    sql_set = (
        "INSERT INTO t_se (storage, tpc_support) VALUES "
        "('davs://teapot2','NONE'),('https://teapot2','NONE') "
        "ON DUPLICATE KEY UPDATE tpc_support='NONE';"
    )
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
            sql_set,
        ],
    )
    yield
    sql_unset = (
        "DELETE FROM t_se WHERE storage IN ('davs://teapot2','https://teapot2');"
    )
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
            sql_unset,
        ],
    )


class TestCopernicusS3:
    """
    Copernicus Data Space S3 → TEAPOT2 transfer via FTS.

    Copernicus S3 differs from ordinary AWS S3 usage because it does not
    support the presigned-URL workflow used by Rucio's standard S3 TPC path.

    Expected failure modes:

      - FTS submission rejected with a schema error:
          FTS expects a different credential field name.

      - Transfer submitted but fails with HTTP 403:
          invalid credentials or URL-style mismatch.

      - Rule remains STUCK with "no sources":
          RSE S3 attributes not propagated into the transfer definition.

    Environment notes:

      Some RHEL9 images require:

          export AWS_CA_BUNDLE=/etc/pki/tls/cert.pem

      because botocore may otherwise use an outdated CA bundle and fail
      TLS validation against the Copernicus endpoint.
    """

    @staticmethod
    def _get_copernicus_metadata():
        s3 = boto3.client(
            "s3",
            endpoint_url=f"https://{COPERNICUS_ENDPOINT}",
            aws_access_key_id=os.environ["S3_ACCESS_KEY"],
            aws_secret_access_key=os.environ["S3_SECRET_KEY"],
            region_name="default",
            verify=os.environ.get("AWS_CA_BUNDLE", True),
        )

        obj = s3.get_object(
            Bucket=COPERNICUS_BUCKET,
            Key=COPERNICUS_TEST_KEY,
        )

        body = obj["Body"].read()

        return (
            len(body),
            f"{zlib.adler32(body) & 0xFFFFFFFF:08x}",
        )

    def test_copernicus_s3_to_teapot2(
        self, rucio_client, teapots_ready, teapot_token, force_streamed_teapot2
    ):
        """Replicate a known Copernicus object to TEAPOT2 via FTS."""

        size, adler32 = self._get_copernicus_metadata()

        log.info("  bytes=%d adler32=%s", size, adler32)

        name = f"copernicus-{int(time.time())}"

        pfn = f"s3s://{COPERNICUS_ENDPOINT}/{COPERNICUS_BUCKET}/{COPERNICUS_TEST_KEY}"

        log.info("[ COPERNICUS_S3 → TEAPOT2 ]")
        log.info("  src PFN: %s", pfn)
        log.info(
            "  bytes=%d adler32=%s",
            size,
            adler32,
        )

        # Clean any stale destination file
        webdav_delete(f"{TEAPOT2_URL}/data/{name}", teapot_token)

        register_replica(
            rucio_client,
            COPERNICUS_S3,
            SCOPE,
            name,
            pfn,
            size,
            adler32,
        )

        rule_id = add_rule(rucio_client, SCOPE, name, "TEAPOT2")

        run_daemons(RUCIO_SVC)

        validate_rule(
            rucio_client,
            rule_id,
            "COPERNICUS_S3→TEAPOT2",
            RUCIO_SVC,
        )
