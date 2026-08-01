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
```
Expected: `TestXRootDOIDC`, `TestTeapotOIDC`, `TestCrossProtocolOIDC`,
`TestDatasetOIDC` all pass — rules reach `state=OK`.

> **NOTE:** the automated tests above authenticate via non-interactive grants (password/client-credentials) — no browser involved. The interactive login below is the only path that exercises the real Authorization Code flow a human actually uses.

## Interactive OIDC login + upload (WORKING — dev-container recipe)

Both interactive login **and** `rucio upload` run entirely from the dev
container: `rucio whoami` authenticates via the browser and `rucio upload`
moves bytes to Teapot or XRootD storage using a native gfal2 client. No
token-copy, no pod hop.

### oidc-client.cfg

```ini
[client]
rucio_host  = http://localhost:8090
auth_host   = http://localhost:8090
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

Within the dev container, the following hostnames must resolve to
`127.0.0.1`. Run this once per dev container instance (entries don't
survive a rebuild):

```bash
grep -qxF "127.0.0.1 rucio" /etc/hosts || echo "127.0.0.1 rucio" | sudo tee -a /etc/hosts
grep -qxF "127.0.0.1 keycloak" /etc/hosts || echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
grep -qxF "127.0.0.1 teapot1" /etc/hosts || echo "127.0.0.1 teapot1" | sudo tee -a /etc/hosts
grep -qxF "127.0.0.1 teapot2" /etc/hosts || echo "127.0.0.1 teapot2" | sudo tee -a /etc/hosts
grep -qxF "127.0.0.1 xrd3" /etc/hosts || echo "127.0.0.1 xrd3" | sudo tee -a /etc/hosts
grep -qxF "127.0.0.1 xrd4" /etc/hosts || echo "127.0.0.1 xrd4" | sudo tee -a /etc/hosts
```

Verify:
```bash
grep -E 'rucio|keycloak|teapot1|teapot2|xrd3|xrd4' /etc/hosts
```

These entries are required because:

- `keycloak` is the OIDC issuer hostname used during browser authentication.
- `teapot1` is the Teapot WebDAV endpoint used by `gfal2`.
- `teapot2` is the second Teapot endpoint — only needed if you'll `rucio
  download` directly from TEAPOT2 (see the port-forward note below).
- `xrd3` is the XRootD (HTTP/davs) endpoint used by `gfal2`.
- `xrd4` is the second XRootD endpoint — only needed if you'll `rucio
  download` directly from XRD4 (see the port-forward note below).
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
kubectl -n dep-dlm-sandbox port-forward svc/rucio-server 8090:80 &
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

> **Port-forward rule of thumb:** for a **rule**, you only ever need a storage
> port-forward for the RSE you're *uploading from* — the destination is always
> written server-side by FTS, never by your client. `TEAPOT1 → TEAPOT2` needs
> no `teapot2` forward; the same logic applies to every case below.
>
> **Exception — `rucio download` is different.** It's a direct client pull, so
> it needs a forward for whichever RSE you're downloading *from*, even if that
> wasn't your original upload source (e.g. downloading from XRD4 or TEAPOT2
> after replicating there). Each RSE pair shares a single PFN port (XRD3/XRD4
> on `1094`, TEAPOT1/TEAPOT2 on `8081`), so their forwards can't run at the
> same time — stop one before starting the other:
> ```bash
> kill %<xrd3-job-number>
> kubectl -n dep-dlm-sandbox port-forward svc/xrd4 1094:1094 &
> ```
> With `xrd3` and `teapot1` forwarded (see "Run it" above), every rule in the
> matrix below is already covered — the exception above only applies once you
> add a verification `rucio download` step.

The full matrix below mirrors what `test_rucio_transfers.py` exercises
(`TestXRootDOIDC`, `TestTeapotOIDC`, `TestCrossProtocolOIDC`,
`TestDatasetOIDC`), reproduced here as manual, client-side steps.

**1. XRootD → XRootD**
```bash
echo "Hello XRD upload" >> /tmp/hello-xrd.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/hello-xrd.txt

rucio add-rule randomaccount:hello-xrd.txt 1 XRD4
rucio rule list --did randomaccount:hello-xrd.txt   # XRD3 OK[1/0/0], XRD4 REPLICATING -> OK

rucio rule show <rule_id>                            # REPLICATING -> OK
rucio replica list file randomaccount:hello-xrd.txt  # replica on XRD4

# verifying by download needs its own forward — see the exception above
kill %<xrd3-job-number>
kubectl -n dep-dlm-sandbox port-forward svc/xrd4 1094:1094 &
rucio -v download randomaccount:hello-xrd.txt --rses XRD4
```

**2. Teapot → Teapot**
```bash
echo "Hello Teapot upload" >> /tmp/hello-teapot.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-teapot.txt

rucio add-rule randomaccount:hello-teapot.txt 1 TEAPOT2
rucio rule list --did randomaccount:hello-teapot.txt   # TEAPOT1 OK, TEAPOT2 -> OK

rucio rule show <rule_id>                              # REPLICATING -> OK
rucio replica list file randomaccount:hello-teapot.txt # replica on TEAPOT2

# verifying by download needs its own forward — see the exception above
kill %<teapot1-job-number>
kubectl -n dep-dlm-sandbox port-forward svc/teapot2 8081:8081 &
rucio -v download randomaccount:hello-teapot.txt --rses TEAPOT2
```

**3. Cross-protocol: XRootD → Teapot**
```bash
echo "Hello XRD to Teapot" >> /tmp/hello-xrd-to-teapot.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/hello-xrd-to-teapot.txt

rucio add-rule randomaccount:hello-xrd-to-teapot.txt 1 TEAPOT1
rucio rule list --did randomaccount:hello-xrd-to-teapot.txt   # XRD3 OK, TEAPOT1 -> OK
```

**4. Cross-protocol: Teapot → XRootD**
```bash
echo "Hello Teapot to XRD" >> /tmp/hello-teapot-to-xrd.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-teapot-to-xrd.txt

rucio add-rule randomaccount:hello-teapot-to-xrd.txt 1 XRD3
rucio rule list --did randomaccount:hello-teapot-to-xrd.txt   # TEAPOT1 OK, XRD3 -> OK
```

**5. Dataset — register two files, replicate as a group**

The pytest version seeds files via container exec straight into `xrd3`
(`conftest.seed_and_register_files`). The manual, client-side equivalent
below uploads them individually first, which still validates the same
catalog + rule-evaluation path:
```bash
echo "file one" >> /tmp/ds-file1.txt
echo "file two" >> /tmp/ds-file2.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/ds-file1.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/ds-file2.txt

rucio did add --type dataset randomaccount:manual-test-dataset
rucio attach randomaccount:manual-test-dataset randomaccount:ds-file1.txt randomaccount:ds-file2.txt

rucio add-rule randomaccount:manual-test-dataset 1 XRD4
rucio rule list --did randomaccount:manual-test-dataset   # both files -> OK on XRD4
```

A rule state of `OK` with a replica on the destination means catalog → FTS →
storage works end to end, for any RSE pair or dataset above.

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
`/etc/hosts` entries for `rucio`/`keycloak`/`teapot1`/`teapot2`/`xrd3`/`xrd4`:

```bash
jobs
kill %1 %2 %3 %4
```
