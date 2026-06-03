# FTS, gfal2 and davix: how the three layers fit together

A short orientation for anyone touching the data-transfer stack in this
testbed — especially when a change (like the Copernicus S3 header-signing
fix) turns out to span more than one of these projects.

## One sentence each

- **davix** — a standalone C++ client library for HTTP-family protocols
  (HTTP/WebDAV and S3/Azure/GCloud/Swift over HTTP). It knows how to
  build, sign and execute a single request against a remote store. It
  has no concept of "a transfer job" or of gfal2's configuration files.

- **gfal2** — a protocol-abstraction layer. It presents a uniform
  POSIX-like API (`stat`, `open`, `read`, `copy`, …) and dispatches each
  call to a protocol plugin. The HTTP plugin (`libgfal_plugin_http.so`)
  is a thin adapter that turns gfal2 calls and gfal2 configuration into
  davix calls and davix `RequestParams`.

- **FTS3** — the transfer service / scheduler. It manages job queues,
  retries, credential delegation and bulk submission and it drives
  gfal2 to perform the actual byte movement. Rucio submits jobs to FTS;
  FTS calls gfal2; gfal2 calls davix.

## The call chain

```
Rucio  ──submit──▶  FTS3  ──▶  gfal2 (http plugin)  ──▶  davix  ──▶  remote storage
                                     │                      │
                          reads [S3:HOST] config     builds + signs the
                          and maps it onto davix      HTTP request
                          RequestParams
```

For an `s3s://` source in a Rucio pull transfer, FTS asks gfal2 to read
the object; gfal2's HTTP plugin builds a davix `RequestParams` from its
configuration and credentials, then hands the request to davix, which
signs it and puts it on the wire.

## Why a change can span layers

The split is along ownership and reuse lines, not feature lines. davix
is reused by clients other than gfal2; gfal2 is reused by clients other
than FTS. A capability and the switch that turns it on therefore often
live in different repositories:

- A new **signing behaviour** is a davix concern — davix owns request
  construction. It is exposed as an API setting on `RequestParams`.
- The **decision to enable it for a given endpoint** is a gfal2
  concern — gfal2 owns the per-endpoint configuration model
  (`[S3:HOST]` groups, `ALTERNATE`, `REGION`, etc.). gfal2 must read the
  option and call the davix setter.

So a davix-only change can compile and ship a capability that is never
activated, because nothing tells davix to use it. The Copernicus
header-signing fix is exactly this case: davix gained the v4
header-signing path and a `setAwsSigV4HeaderMode` opt-in and gfal2's
HTTP plugin gained a `SIGV4_HEADER_MODE` config reader that calls it.
Both are required; either alone is inert.

## Practical implications for this testbed

- All three are built from source in the FTS image
  (`deploy/compose/Dockerfile.fts`). Build order is davix → gfal2 →
  FTS3, because gfal2's `find_package(Davix)` resolves the
  just-installed davix and FTS links gfal2.
- When patching, match versions: a gfal2 build that calls a davix
  setter requires a davix build where that setter exists, or gfal2
  won't compile.
- Quick activation check after a build — confirm the capability is in
  davix *and* that gfal2 can switch it on:

  ```bash
  docker exec compose-fts-1 strings /lib64/libdavix.so.0 \
    | grep -i "header mode"
  docker exec compose-fts-1 strings \
    /usr/lib64/gfal2-plugins/libgfal_plugin_http.so \
    | grep -i SIGV4_HEADER_MODE
  ```

  Both should return hits. If only the first does, the davix capability
  is present but gfal2 never enables it.

## Where to look

| Concern | Project | Typical file |
|---|---|---|
| Request building / signing | davix | `src/utils/davix_s3_utils.cpp`, `src/backend/BackendRequest.cpp` |
| Stat / read / copy dispatch | davix | `src/fileops/davmeta.cpp`, `src/fileops/S3IO.cpp` |
| Per-endpoint config → davix params | gfal2 | `src/plugins/http/gfal_http_plugin.cpp` |
| Job scheduling / delegation | FTS3 | (separate service; not usually patched for protocol behaviour) |
