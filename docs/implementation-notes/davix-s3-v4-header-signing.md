# Implementation Notes: davix v4 Header-Signed S3

Companion to [ADR-001](../adr/adr-001-patch-davix-s3-v4-header-signing.md).
This document covers *how* the decision in ADR-001 is wired through the
code — it is not itself a decision record and should be updated freely as
the implementation evolves, without reopening the ADR.

## Why three components, not one

The fix spans three layers because the FTS transfer path does not read S3
credentials from the static gfal2 config at all. At transfer time, the FTS
server writes a short-lived `--cloud-config` file (via `writeS3Creds()` in
`CloudStorageConfig.cpp`) and passes it to the per-file `fts_url_copy`
executor. That generated file — not `/etc/gfal2.d` — is authoritative on
the FTS transfer path.

Consequently, `region` / `sigv4_header_mode` must be modelled per storage
in FTS3's own schema (`t_cloudStorage` → `CloudStorageAuth` →
`writeS3Creds`) and emitted into the generated cloud-config, not just set
in a static gfal2 config file. The required changes are:

| Layer | Change |
|---|---|
| **davix** | Implement the v4 header-signing branch; add `setAwsSigV4HeaderMode` |
| **gfal2** | Read `SIGV4_HEADER_MODE` / `REGION` from `[S3:HOST]` config section, call the davix setter |
| **FTS3** | Model `region` / `sigv4_header_mode` per storage in `t_cloudStorage`; emit them into the generated `--cloud-config` via `writeS3Creds()` |

A mistake at any single layer leaves the feature compiled but silently
inactive — e.g. a davix-only build still produces query-string-signed
requests, because gfal2 never calls the new setter and FTS never emits the
config that would trigger it. This is the practical reason the Confirmation
section of ADR-001 explicitly tests the davix-only case as a still-failing
regression, not just the fully-patched case.

## Subsequent findings (post-implementation)

The three signing layers above make the **source read** succeed, but two
further, independent concerns had to be resolved before an S3-source →
token-WebDAV-destination transfer completed end-to-end. Both are also
captured in `patches.md`, which is what `init-testbed.sh` applies at
deploy time.

### 1. Copy mode must be STREAMED, not third-party-pull

An S3 (SigV4) source and a token-WebDAV destination cannot do a direct
TPC: neither endpoint can present the other's credential, and CDSE issues
no pre-signed URLs. FTS's `getCopyMode()` defaults a row-less SE to full
TPC support, yielding `--copy-mode pull`. The streaming branch is gated on
the *destination*'s `t_se.tpc_support`, so both the S3 source and the
WebDAV destination must be marked `tpc_support=NONE` to force
`CopyMode::STREAMING`.

`init-testbed.sh`'s `configure_fts_cloud_storage()` sets this
(`t_se.tpc_support = 'NONE'` for the S3 storage element).

### 2. Cloud-storage credential resolution is keyed on `user_dn`

FTS resolves the SigV4 keys from `t_cloudStorageUser` by
`(cloudStorage_name, user_dn, vo_name)`. For a token-authenticated job the
DN FTS sees is the OIDC subject, not `/CN=fts-oidc`; a mismatch makes the
lookup miss, davix signs with an empty secret, and CDSE returns 403 even
though signing, region, and keys are all otherwise correct.

`init-testbed.sh` sets `FTS_USER_DN` to match what `/whoami` returns for
the credential Rucio submits with, and inserts the `t_cloudStorageUser` row
under that DN.

## Net

The davix signing fix (ADR-001) is necessary but not sufficient on its
own. The end-to-end path also requires the copy-mode and `user_dn`
configuration above, both captured in `patches.md` and applied
automatically by `init-testbed.sh`'s `configure_fts_cloud_storage()`.
