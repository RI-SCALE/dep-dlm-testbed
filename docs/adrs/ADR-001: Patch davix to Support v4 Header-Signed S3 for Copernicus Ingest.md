---
status: proposed
date: 2026-06-02
decision-makers: dep-dlm-testbed contributors
consulted: none
informed: dep-dlm-testbed contributors
---

# ADR-001: Patch davix to Support v4 Header-Signed S3 for Copernicus Ingest

## Context and Problem Statement

The dep-dlm-testbed integrates Rucio with FTS3 for third-party-copy
transfers. We want Copernicus Data Space Sentinel data
(`eodata.dataspace.copernicus.eu`) to be available as a source for
Rucio replication rules.

The standard approach is to expose Copernicus as an S3-backed RSE and
let FTS fetch objects directly via gfal2 and davix. End-to-end testing
showed every transfer returns `HTTP 403 Forbidden` from the Copernicus
endpoint, while the identical credentials succeed via boto3. Source
review of davix established that the failure is a specific, bounded
gap: davix's v4 S3 signer only emits query-string-signed URLs (the
"presigned URL" pattern that Copernicus rejects), while its
header-signing path supports v2 only.

The testbed already builds davix from source as part of the FTS
image. A davix patch that adds v4 header signing and routes the
transfer code paths through it is therefore a contained change inside
the existing build pipeline, not an architectural addition. No
configuration-only workaround exists.

How should Copernicus data be integrated into Rucio?

## Decision Drivers

* Must work against the current Copernicus production endpoint.
* Rucio remains the source of truth for replicas and rules.
* Prefer fixing the root cause over working around it, when the fix is
  bounded.
* Minimize permanent operational surface: avoid new services, new
  RSEs, and multi-hop transfers when a direct fix exists.
* The fix should generalize to other endpoints with the same
  limitation.
* Existing deployments using query-string S3 signing must keep
  working.

## Considered Options

1. Patch davix to implement v4 header-signed SigV4 and use it from the
   transfer code paths.
2. Build and operate a boto3-based staging service that pulls
   Copernicus objects into a Rucio-managed staging RSE.
3. Document the limitation and do not support Copernicus ingest.

## Decision Outcome

Chosen option: **Patch davix to support v4 header-signed S3 and use it
for the streaming-read code path that Rucio invokes for `s3s://`
sources.**

The patched davix is consumed by the existing FTS image build. The
Copernicus `s3s://` RSE is registered directly, and the existing FTS
cloud_storage credentials mechanism is reused without change.
Header-signing is selected per storage via configuration; the default
remains query-string signing, so any deployment not opting in is
unaffected.

The boto3 staging service (option 2) is retained as a documented
fallback pattern for future external sources whose incompatibilities
cannot be addressed by a davix change — for example, sources using
auth models other than SigV4, or non-S3 protocols. It is not built
now.

> The fix in fact spans three layers. The FTS path does not read
> the static gfal2 config for S3 credentials: at transfer time the server
> writes a short-lived `--cloud-config` (via `writeS3Creds()` in
> `CloudStorageConfig.cpp`) and passes it to the per-file `fts_url_copy`
> executor — that file, not `/etc/gfal2.d`, is authoritative on the FTS
> path. So `region`/`sigv4_header_mode` must also be modelled per storage
> in FTS3 (`t_cloudStorage` → `CloudStorageAuth` → `writeS3Creds`) and
> emitted into the generated cloud-config. The required changes therefore
> are: **davix** (v4 header-signing branch + `setAwsSigV4HeaderMode`),
> **gfal2** (read `SIGV4_HEADER_MODE`/`REGION` from `[S3:HOST]`, call the
> setter), and **FTS3** (per-storage modelling + cloud-config emit). A mistake
> at any layer leaves the feature compiled but inactive.

## Subsequent findings (post-implementation)

The three signing layers (davix + gfal2 + FTS3) make the **source read**
succeed, but two further, independent concerns had to be resolved before an
S3-source → token-WebDAV-destination transfer completed end-to-end. Both are
documented in detail in `patches.md`:

1. **Copy mode must be STREAMED, not third-party-pull.** An S3 (SigV4) source
   and a token-WebDAV destination cannot do a direct TPC: neither endpoint can
   present the other's credential, and CDSE issues no pre-signed URLs. FTS's
   `getCopyMode()` defaults a row-less SE to full TPC support, yielding
   `--copy-mode pull`. The streaming branch is gated on the *destination*'s
   `t_se.tpc_support`, so both the S3 source and the WebDAV destination must be
   marked `tpc_support=NONE` to force `CopyMode::STREAMING`.

2. **Cloud-storage credential resolution is keyed on `user_dn`.** FTS resolves
   the SigV4 keys from `t_cloudStorageUser` by `(cloudStorage_name, user_dn,
   vo_name)`. For a token-authenticated job the DN FTS sees is the OIDC subject,
   not `/CN=fts-oidc`; a mismatch makes the lookup miss, davix signs with an
   empty secret, and CDSE returns 403 even though signing, region and keys are
   all correct.

Net: the davix signing fix is necessary but not sufficient. The end-to-end
path also requires the copy-mode and `user_dn` configuration captured in
`patches.md` and applied by `init-testbed.sh`.

### Positive Consequences

* Fixes the problem at the right architectural layer.
* Preserves single-hop transfers: no doubled bandwidth, no staging
  RSE to operate, no new long-lived service.
* Reuses the FTS cloud_storage credentials path the testbed already
  configures.
* Default behaviour is unchanged for existing deployments; header
  signing is opt-in per storage.

### Negative Consequences

* Requires C++ work on a security-sensitive library.
* Header-signed SigV4 has subtle differences from query-string SigV4
  that require careful spec-compliance testing.
* Does not help with future sources whose problems are not davix
  signing-mode issues; for those, the staging-service pattern remains
  the fallback.
* The fix touches two separately-released libraries (davix and gfal2);
  a davix-only build silently fails to activate the feature,
  so both must be version-matched in the image.

## Confirmation

* The patched davix passes davix's existing test suites unchanged in
  the default (query-string) mode.
* New tests cover the v4 header-signing path against authoritative
  fixtures and against a header-signing-capable S3 endpoint.
* The existing FTS S3 tests continue to pass with the patched davix
  in default mode, demonstrating no regression for query-string
  consumers.
* The Copernicus integration test
  (`tests/test_rucio_transfers_with_copernicus.py`) moves from `xfail`
  to expected-pass both patched libraries are in use (`davix` with the
  header-signing branch, `gfal2` with the `SIGV4_HEADER_MODE` reader).
  With only the davix patch, the test still fails with `HTTP 403`,
  because the header-signing path is never selected.

## Pros and Cons of the Options

### 1. Patch davix (chosen)

* Good — root-cause fix at the correct layer.
* Good — single-hop transfers preserved; no new service.
* Good — already inside the existing build pipeline.
* Good — opt-in via configuration; existing deployments unaffected.
* Bad — C++ work on a security-sensitive library demands careful
  review and testing.
* Bad — does not address future sources whose limitations are not
  signing-mode related.

### 2. boto3 staging service

* Good — works around any source-side limitation, not only signing
  mode. Generalizes to future incompatible sources.
* Good — pure-Python; familiar to the team.
* Bad — permanent new service to operate alongside Rucio and FTS.
* Bad — doubles bandwidth and adds latency vs. single-hop transfer.
* Bad — adds a staging RSE with its own lifecycle (eviction, quotas,
  provenance carry-through).
* Neutral — design retained as a documented fallback pattern.

### 3. Document the limitation, do not ingest Copernicus

* Good — zero engineering cost.
* Bad — does not deliver the requirement.
* Bad — leaves consumers to build their own ingestion outside Rucio.

## Evidence / Links

* Copernicus S3 access via boto3 (working path):
  <https://documentation.dataspace.copernicus.eu/APIs/S3.html>

* Davix source review (`cern-fts/davix`). Both transfer call sites in
  davix sign S3 requests by embedding the signature in the URL. The
  v4 implementation produces only query-string-signed URLs. A
  header-signing function exists but its v4 branch raises a runtime
  error indicating the feature is not implemented. The fix therefore
  consists of implementing the v4 header-signing branch and routing
  the transfer code paths through it when configured.

* Davix S3 signing behavior — runtime evidence via `gfal-copy`:

  ```bash
  docker exec compose-fts-1 gfal-copy -vvv \
    -D"S3:EODATA.DATASPACE.COPERNICUS.EU:ACCESS_KEY=$S3_ACCESS_KEY" \
    -D"S3:EODATA.DATASPACE.COPERNICUS.EU:SECRET_KEY=$S3_SECRET_KEY" \
    -D"S3:EODATA.DATASPACE.COPERNICUS.EU:ALTERNATE=false" \
    -D"S3:EODATA.DATASPACE.COPERNICUS.EU:REGION=default" \
    s3s://eodata.dataspace.copernicus.eu/.../manifest.safe \
    file:///tmp/manifest.safe
  ```

  Observed:

  * `Using S3 v4 signature authentication`
  * Signature carried in query parameters
    (`X-Amz-Signature`, `X-Amz-Credential`, `X-Amz-Date`).
  * No `Authorization: AWS4-HMAC-SHA256` header.
  * Response: `HTTP 403 : Permission refused`.

* Static inspection of the shared library shows only query-string
  signing strings, with no `Authorization` / `AWS4-HMAC` symbols:

  ```bash
  docker exec compose-fts-1 strings /lib64/libdavix.so.0 \
    | grep -iE "x-amz-(signature|date|credential)|aws-alternate"
  ```

* Spec references:

  * AWS SigV4 header-based auth:
    <https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html>
  * AWS canonical request construction:
    <https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html>

* Copernicus community evidence:
  <https://forum.dataspace.copernicus.eu/t/aws-presigned-urls-do-not-work-on-the-s3-resources/3962>
