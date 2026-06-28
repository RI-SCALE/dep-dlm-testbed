# Runbook 1 — Sandbox Quickstart

## Purpose
Stand up the full DEP DLM testbed (Rucio, FTS, Keycloak, storage) in the sandbox,
initialize it and run transfers and an interactive upload end to end.

## Prerequisites
- A Kubernetes cluster with `kubectl` pointed at it.
- The repo dev container (recommended) or local `make`, `helm`, `kubectl`.
- Cluster access to create namespaces and secrets.

## Steps

1. **Generate certificates.**
```bash
make certs
```

2. **Bootstrap via GitOps.**
```bash
make argocd-install   # or: make flux-install
```

3. **Watch it converge** — all components reach Running / Completed.
```bash
kubectl get pods -n dep-dlm-sandbox -w
```
Expect Rucio (`rucio-server`, conveyor/judge/reaper daemons), datastores
(`ruciodb-0`, `ftsdb-0`), services (`fts-*`, `keycloak-*`, `teapot-*`,
`xrootd-*`), Vault/external-secrets and run-once jobs
(`rucio-bootstrap-db-*`, `vault-seed-*`) reaching `Completed`.

> Early daemon `RESTARTS` are normal — they back off until the DB bootstrap
> and Vault seed finish, then settle.

4. **Initialize the testbed.**
```bash
export RUNTIME=k8s
export K8S_NAMESPACE=dep-dlm-sandbox
export TOKEN_MODE=managed # or TOKEN_MODE=unmanaged
make init
```

Provisions accounts (`ddmlab` SERVICE/admin, `randomaccount` USER/admin,
`root`), scopes (`test`, `ddmlab`, `randomaccount`), RSEs (`XRD3`/`XRD4`
XRootD, `TEAPOT1`/`TEAPOT2` Teapot) with distances and infinite quotas, an
optional `COPERNICUS_S3` source and — in managed mode — token-exchange
grants plus seeded OIDC subject tokens.

5. **Run a test transfer** from the `rucio-client` pod (it has in-cluster DNS;
FTS moves the bytes server-side):
```bash
make test-rucio-transfers
# or
kubectl exec -n dep-dlm-sandbox deploy/rucio-client -- \
   bash -c "RUNTIME=k8s K8S_NAMESPACE=dep-dlm-sandbox pytest /tests/test_rucio_transfers.py -v"
```
Expected: `TestXRootDOIDC`, `TestTeapotOIDC`, `TestCrossProtocolOIDC`,
`TestDatasetOIDC` all pass — rules reach `state=OK`.

## Interactive OIDC login + upload (WORKING — dev-container recipe)

Both interactive login **and** `rucio upload` run entirely from the dev
container: `rucio whoami` authenticates via the browser and `rucio upload`
moves bytes to Teapot or XRootD storage using a native gfal2 client. No
token-copy, no pod hop.

### oidc-client.cfg

```ini
[client]
rucio_host  = http://localhost:8080
auth_host   = http://localhost:8080
auth_type   = oidc
account     = randomaccount
oidc_scope  = openid offline_access storage.read:/ storage.modify:/ aud:rucio
oidc_issuer = https://keycloak:8443/realms/rucio
```

> `aud:rucio` is required. Storm-WebDAV (Teapot) authorizes by issuer, but its
> JWT decoder rejects a token with no `aud` claim before authorization runs (the
> access log then shows the principal as `-`). `aud:rucio` is an optional,
> requestable scope on the `rucio` client whose audience-mapper fires without
> appearing in the scope string, so the interactive token carries `aud=['rucio']`
> and is accepted. `rucio` is also an accepted audience in XRootD's SciTokens
> config, so the same token works for XRD3. This does **not** affect the FTS
> token-exchange path, so transfers stay green.

### One-time dev-container client setup
The dev container for Apple Silicon (M4 and newer) uses Ubuntu Jammy on ARM.
In this environment, the pip build of `gfal2-python` fails because Jammy ships `libgfal2` 2.20.3,
which does not include `bring_online_v2`. Conda-forge is preinstalled and configured for terminal use;
see `install_rucio_gfal()` in `.devcontainer/setup.sh`.
It creates a conda env with `gfal2`, `python-gfal2`, `gfal2-util`, pins `rucio-clients`
to the server major (39.x) and puts the env on `PATH`. Verify:
```bash
rucio --version                         # 39.x
python -c "import gfal2; print('ok')"   # ok
```

### Host name resolution

Within the dev container, the following hostnames must be configured and
must resolve to `127.0.0.1`. Add the required entries to `/etc/hosts`,
e.g. `echo "127.0.0.1 xrd3" | sudo tee -a /etc/hosts`:

```text
127.0.0.1 rucio
127.0.0.1 keycloak
127.0.0.1 teapot1
127.0.0.1 xrd3
```

These entries are required because:

- `keycloak` is the OIDC issuer hostname used during browser authentication.
- `teapot1` is the Teapot WebDAV endpoint used by `gfal2`.
- `xrd3` is the XRootD (HTTP/davs) endpoint used by `gfal2`.
- `rucio` is the Rucio server hostname used by the client.

No changes are required inside the dev container.

If you use the **interactive browser-based OIDC login**, your **host machine**
(browser) must also be able to resolve `keycloak`. Add the following entry to
the host system's `/etc/hosts` if it is not already present:

```bash
echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```

Without this entry, the browser cannot reach the OIDC issuer and the login
flow will fail.

### Run it (login + upload)

```bash
# control-plane + auth forwards
kubectl -n dep-dlm-sandbox port-forward svc/rucio-server 8080:80 &
kubectl -n dep-dlm-sandbox port-forward svc/keycloak     8443:8443 &
# storage forwards (gfal2 hits these directly; the local port must match the
# RSE PFN port: Teapot davs = 8081, XRootD davs = 1094)
kubectl -n dep-dlm-sandbox port-forward svc/teapot1      8081:8081 &
kubectl -n dep-dlm-sandbox port-forward svc/xrd3         1094:1094 &
# Check background jobs
jobs

# CA trust for the davs PUT — the dir must be a DIRECTORY, not a file
sudo mkdir -p /etc/grid-security/certificates
sudo cp certs/rucio_ca.pem certs/5fca1cb1.0 certs/b96dc756.0 \
        /etc/grid-security/certificates/
( cd /etc/grid-security/certificates && sudo openssl rehash . )
export X509_CERT_DIR=/etc/grid-security/certificates

export RUCIO_CONFIG=/workspaces/dep-dlm-testbed/shared/config/rucio/oidc-client.cfg
rucio whoami   # browser login as randomaccount / secret, paste the code

# upload to Teapot (Storm-WebDAV, davs port 8081)
echo "Hello from randomaccount" >> /tmp/hello-from-randomaccount.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-from-randomaccount.txt

# upload to XRootD (HTTP/davs port 1094)
echo "Hello XRD upload" >> /tmp/hello-xrd.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/hello-xrd.txt
```
Each upload ends with `Successfully uploaded file ...` and exit code `0`.

### Replicate to another RSE

`rucio upload` only places the file on the chosen RSE. To copy it elsewhere,
create a replication rule — the bytes are then moved **server-side by FTS** (the
same path the transfer test suite exercises), not by your client. The rule
starts `REPLICATING` and reaches `OK` once the conveyor cycle completes.

```bash
rucio add-rule randomaccount:hello-xrd.txt 1 XRD4
rucio rule list --did randomaccount:hello-xrd.txt   # XRD3 OK[1/0/0], XRD4 REPLICATING -> OK

# verify the rule and the destination replica
rucio rule show <rule_id>                            # REPLICATING -> OK
rucio replica list file randomaccount:hello-xrd.txt  # replica on XRD4
```

A rule state of `OK` with a replica on the destination means catalog → FTS →
storage works end to end.

### Watching the replication (FTS daemon logs)

To watch the `REPLICATING -> OK` transition (or diagnose a stuck rule), tail the
conveyor daemons:
```bash
# submitter — hands the transfer to FTS (look for "Submit job ... to https://fts:8446")
kubectl -n dep-dlm-sandbox logs -f deploy/rucio-daemons-conveyor-submitter
# poller — polls FTS for job state (look for "UPDATING REQUEST ... state(...)")
kubectl -n dep-dlm-sandbox logs -f deploy/rucio-daemons-conveyor-poller
# finisher — finalizes the replica + rule (look for the lock moving to OK)
kubectl -n dep-dlm-sandbox logs -f deploy/rucio-daemons-conveyor-finisher
```

What each stage tells you:
- **submitter**: `Submit job <uuid> to https://fts:8446` — the transfer reached
  FTS. If you instead see `exchange returned no token aud=<rse>`, the managed
  token path isn't seeded (re-run `make init TOKEN_MODE=managed`).
- **poller**: `UPDATING REQUEST ... state(RequestState.DONE)` — FTS finished the
  copy. A `state(FAILED)` with `[TokenExchange] ... HTTP 400` points at the
  Keycloak token-exchange (subject-token audience), not the storage.
- **finisher**: the rule's lock flips to `OK`; `rucio rule list --did
  randomaccount:hello-xrd.txt` then shows `OK[1/0/0]` on XRD4.

Alternatively, drive the conveyor yourself with one-shot `--run-once`
invocations against the `rucio-server` pod (deterministic; this is what the
test harness does in `DAEMON_MODE=direct`). Run them in order until the rule
is `OK` (the `-c rucio-server` flag is required — the pod is multi-container):
```bash
# 1. judge-evaluator — turn the rule into a transfer request
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-judge-evaluator --run-once
# 2. conveyor-submitter — submit the transfer to FTS
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-conveyor-submitter --run-once
# 3. conveyor-poller — poll FTS for the job's state
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-conveyor-poller --run-once --older-than 0
# 4. conveyor-finisher — finalize the replica + flip the rule lock to OK
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-conveyor-finisher --run-once

# then confirm:
rucio rule list --did randomaccount:hello-xrd.txt   # XRD4 -> OK[1/0/0]
```

> In `DAEMON_MODE=direct` (the test harness default) the conveyor runs as
> one-shot `--run-once` invocations rather than long-running deployments; in the
> GitOps sandbox they run as the `rucio-daemons-conveyor-*` deployments above, so
> `logs -f` works directly.

### Gotchas
- **Upload under a scope the account owns** (`--scope randomaccount`). Scope
  `test` belongs to `root` → "Scope test not found".
- **Use a fresh filename** per attempt. A re-upload of an existing DID fails with
  `Data Identifier Already Exists` / checksum mismatch — not an error in the
  pipeline.
- **Match the storage port-forward to the RSE PFN port.** gfal2 connects to the
  PFN's port, not your forward's left side: Teapot davs is `8081`, XRootD davs is
  `1094`. A `Domain name resolution failed` or `connection reset` at the gfal PUT
  usually means a missing `/etc/hosts` entry or a port mismatch — not auth.
- **A `401 AccessDenied` on `POST /replicas` is *authorization*, not auth** —
  the client misreads it and re-launches the browser login. The real fix is the
  `admin=True` attribute, not re-authenticating.
- **Config changes must reach the running pods.** idpsecrets/realm are
  Vault-seeded via external-secrets; editing repo files alone doesn't update
  pods. Re-seed Vault + restart, or apply live via `kcadm`. Keycloak only
  imports a realm on first start — a plain restart won't re-import.

### Delete a replica (rule lifetime → judge-cleaner → reaper)

Deleting the replication rule (or expiring its lifetime) releases the lock; the
**judge-cleaner** then tombstones the replica and the **reaper** physically
removes it from storage. As with the conveyor, you can let the long-running
daemons converge or drive them once by hand.

```bash
# expire the rule immediately and mark its replicas for purge
rucio update-rule --lifetime -1 <rule_id>           # or: rucio delete-rule <rule_id>

# watch the long-running daemons:
kubectl -n dep-dlm-sandbox logs -f deploy/rucio-daemons-judge-cleaner
kubectl -n dep-dlm-sandbox logs -f deploy/rucio-daemons-reaper

# OR drive them once by hand (DAEMON_MODE=direct equivalent):
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-judge-cleaner --run-once
kubectl -n dep-dlm-sandbox exec deploy/rucio-server -c rucio-server -- \
  rucio-reaper --run-once --greedy

# confirm the replica is gone from the catalogue:
rucio replica list file randomaccount:hello-xrd.txt   # XRD4 replica removed
```

> `judge-cleaner` releases the expired rule's lock and sets an OBSOLETE
> tombstone (with `purge_replicas`); `reaper` finds tombstoned replicas and
> deletes them from storage via davs:// (it needs gfal2). The source replica on
> the original RSE survives if the rule only covered the destination.

## Teardown
```bash
make argocd-uninstall   # or: make flux-uninstall
```
If you ran the interactive experiment, also stop the forwards and remove the
`/etc/hosts` entries for `rucio`/`keycloak`/`teapot1`/`xrd3`:

```bash
jobs
kill %1 %2 %3 %4
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Daemons `CrashLoopBackOff` early | DB bootstrap / Vault seed not finished | Wait for `rucio-bootstrap-db` and `vault-seed` to `Completed`; daemons self-recover |
| `make init` "already exists" | Stack already seeded; init is idempotent | Harmless — let it continue |
| Rule `STUCK` / `NO_SOURCES` | No RSE distance, or no source replica | Add a distance; ensure the source DID has bytes |
| Rule `STUCK` + `exchange returned no token aud=<rse>` | FTS token path not seeded | Re-run `make init TOKEN_MODE=managed`; check `ftsdb-0` `t_token_provider` |
| OIDC `whoami` -> `500` | apache worker can't read CA (`0600 root`) -> discovery `PermissionError(13)` | Mount `rucio_ca.pem` `0644` per-item; `rollout restart deploy/rucio-server` |
| OIDC login -> `Invalid parameter: redirect_uri` | `rucio` client `redirectUris` lacks the sent URI | Add `http://localhost:8080/auth/*` and re-import the realm |
| OIDC login -> `invalid_scope` | Requested scope includes `profile` or a non-requestable scope | Use `openid offline_access storage.read:/ storage.modify:/ aud:rucio` (all requestable on the `rucio` client) |
| OIDC URL is `https://` but forward is `http` | Server advertises `https` via `X-Forwarded-Proto` | Open the `http://` form of the printed URL |
| OIDC redirect goes to `https://rucio/...` | `oidc.py` picks the redirect at random | Trim the idpsecrets issuer-URL key's `redirect_uris` to the `localhost:8080` forms only |
| `rucio upload` -> `gfal2` import / build fails on jammy | libgfal2 2.20.3 lacks `bring_online_v2`; pip build can't compile | Use the conda-forge client (`install_rucio_gfal()`), not system pip |
| Upload -> `Domain name resolution failed` / `connection reset` at the gfal PUT | Missing `/etc/hosts` entry for the storage host, or the port-forward doesn't match the RSE PFN port | Add `127.0.0.1 <host>`; forward the PFN's port (Teapot `8081`, XRootD `1094`) |
| `gfal-ls` -> `issuer is not trusted` | `X509_CERT_DIR` points at a file, or no hash symlink | Make it a real dir; copy CA + `*.0`; `openssl rehash`; export `X509_CERT_DIR` |
| `gfal-ls` -> `HTTP 401` | `gfal-ls` sends no token (expected) | Judge by `rucio upload`, which attaches the bearer token |
| Upload -> `401` at `POST /replicas` | Account lacks `add_replicas` permission | `rucio-admin account add-attribute <acct> --key admin --value True` (run as admin) |
| Upload -> `401` at the gfal2 PUT to storage (principal logged as `-`) | Interactive token has no `aud`; Storm-WebDAV's JWT decoder rejects it before authz | Request `aud:rucio` in `oidc_scope` (it's optional+requestable on the `rucio` client); any populated `aud` satisfies the decoder — no realm default-scope change needed |
