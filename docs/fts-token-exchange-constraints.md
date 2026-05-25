# FTS Token Exchange — Constraints & Testbed Decision

**Status: closed — testbed runs in unmanaged-token mode.** Managed-mode token
exchange is a production-direction, **not achievable by testbed config alone**.

## Goal

OIDC TPC transfers (`test_rucio_transfers.py`, XRD3 → XRD4) with FTS in
**managed-token mode**: Rucio submits per-file access tokens, FTS performs the
OAuth2 `token-exchange` and manages refresh-token lifecycle (CHEP 2024,
*FTS3 Token Support for a Proxy-less WLCG World*,
<https://cds.cern.ch/record/2946559/files/document.pdf>).

## Symptom

`test_rucio_transfers.py` failed with, recurringly:
- `[TokenExchange] Failed to get refresh token for source token: HTTP 400`
- `Failed to submit transfer to https://fts:8446 — 500 Internal Server Error`

## Root causes found (in order)

1. **Audience not a client** — `xrd3/xrd4/teapot` were `aud`-mapper strings,
   not Keycloak clients → `client_not_found`. Fixed by registering them.
2. **User not fully set up** — `randomaccount` failed the password grant on
   Keycloak 26.6. Fixed via `kcadm`.
3. **Exchange permission missing** — each target client needs a
   `token-exchange` permission admitting `fts` → `access_denied`.
4. **FGAP v1 vs v2** — that permission is an FGAP **v1** construct; Keycloak
   26.x ships FGAP v2, which omits it. Standard exchange V2 also won't issue
   offline tokens.
5. **Keycloak pin** — reverting to **23.0.1** restored legacy V1 + FGAP v1;
   manual exchanges then returned `OK`. But 23.0.1 is EOL-ish / CVE-affected.
6. **Structural blocker** — the FTS log showed the per-file token is minted by
   the **`rucio` service account** (`client_credentials`, no user session),
   so it carries no `offline_access`. Keycloak won't exchange it for a refresh
   token → `HTTP 400`. This is **how Rucio mints the token**, not Keycloak config.
7. **Regression** — moving `aud:*` to optional scopes left the token with no
   audience → `t_token.audience NULL` → `POST /jobs` 500. Reverted.

## Conclusion

Managed mode **cannot be completed by config alone**. It needs legacy Keycloak
V1 + FGAP v1 (deprecated, removed in 26.x — pins to 23.0.1), **and** a Rucio
change so per-file tokens are minted in a user-session flow carrying
`offline_access` with a correct per-RSE audience. The latter is upstream work.

## Decision

- **Testbed runs unmanaged-token mode** — FTS skips `token-exchange` /
  `TOKEN_PREP` and uses per-file tokens as-is (the `t_token` schema already
  has an `unmanaged` column). Manual tests confirmed the tokens are otherwise
  valid and correctly scoped.
- **Keycloak returns to 26.6** — the 23.0.1 pin only served legacy V1 exchange.
- **Managed mode = production-direction**, pending upstream Rucio changes.

## Unmanaged-mode toggles

Unmanaged mode is **enabled** by these two flags — they must be **present** in
the final testbed config (they were removed while managed mode was under test):

- Rucio `shared/patches/rucio/fts3.py`, `build_job_params()` —
  `"unmanaged_tokens": True`
- FTS `shared/config/fts/fts3restconfig` — `AllowNonManagedTokens=True`
