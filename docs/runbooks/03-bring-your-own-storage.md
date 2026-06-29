# Runbook 3 — Bring Your Own Storage

## Purpose
Omit the bundled XRootD/Teapot storage and register your own external storage
endpoints as Rucio Storage Elements (RSEs), wired for FTS third-party-copy (TPC)
transfers.

## Prerequisites
- A storage endpoint speaking `davs` (WebDAV) or XRootD/`https`, reachable from
  FTS.
- For token auth: the endpoint trusts your OIDC issuer (XRootD `scitokens.conf` /
  StoRM/Teapot config), and accepts the capability scopes (`read:/ write:/`).
- An FTS instance both your source and destination endpoints can reach.

## Steps

> **CLI note:** Rucio's command surface is still evolving — newer clients use the
> unified `rucio rse add` / `rucio rule add` form shown here, while older ones use
> `rucio-admin rse add` / `rucio add-rule`. If a command errors as unknown, check
> `rucio --help` / `rucio-admin --help` for the spelling your client version
> exposes (this stack: 39.x).

1. **Disable bundled storage** in your environment values (omit the `xrootd` /
   `teapot` components from the kustomization/app-of-apps for your environment).

2. **Create the RSE.**
   ```bash
   rucio rse add MY_RSE
   ```

3. **Add the protocol** (davs example; set the real host/port/prefix).
   ```bash
   rucio rse protocol add MY_RSE \
     --scheme davs \
     --host-name storage.example.org \
     --port 443 \
     --prefix /my-area \
     --impl rucio.rse.protocols.gfal.Default \
     --domain-json '{"lan":{"read":1,"write":1,"delete":1},"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1}}'
   ```

4. **Set the required attributes.**
   ```bash
   rucio rse attribute add MY_RSE --key fts --value https://<fts-host>:8446
   rucio rse attribute add MY_RSE --key oidc_support --value True   # for token auth
   ```

5. **Add distances** (both directions) to every RSE you'll transfer to/from.
   ```bash
   rucio rse distance add --distance 1 SOURCE_RSE MY_RSE
   rucio rse distance add --distance 1 MY_RSE SOURCE_RSE
   ```

6. **Grant account quota** for any account that will write there.
   ```bash
   rucio account limit add <account> --rse MY_RSE --bytes infinity
   ```

## Verification
```bash
rucio rse show MY_RSE          # confirm oidc_support=True, davs protocol, fts set
# Test transfer from an existing RSE with a real replica
rucio rule add <scope>:<name> --copies 1 --rses MY_RSE
rucio rule show <rule_id>      # REPLICATING -> OK
```
Watch the submitter: a line like `OAuth2/OIDC available for transfer` followed by
`Using a token to authenticate with FTS` confirms `_use_tokens` engaged (RSE is
`oidc_support` + `davs`/`https`). A rule reaching `OK` confirms the storage
accepted the write.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Rule `NO_SOURCES`, "dropped by PathDistance" | Missing RSE distance | Add distance both directions (step 5) |
| Transfer falls back to cert (no token) | RSE not `oidc_support=True` or scheme not `davs`/`https` | Set the attribute; `_use_tokens` requires both |
| `Copy failed ... HTTP 500` during pull | Storage-side server error (not auth) | Check the endpoint's server logs; auth is fine if you see a 500, not 401/403 |
| `401`/`403` on copy | Token lacks scope, or endpoint doesn't trust the issuer | Verify scopes in token + issuer registered on the endpoint |
| Source 404 | Replica registered but bytes absent | Use a DID with a physically present replica |
