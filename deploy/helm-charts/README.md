# DEP DLM Testbed — Helm Charts

Kubernetes translation of the `dep-dlm-testbed` docker-compose stack,
following the idioms of [rucio/helm-charts](https://github.com/rucio/helm-charts)
and [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial).

## Layout

```
helm-charts/
├── dep-dlm-testbed/        # Umbrella (meta) chart — deploy this
│   ├── Chart.yaml                 # Declares deps on all subcharts below
│   ├── values.yaml                # Single source of truth (toggle services, OIDC, etc.)
│   ├── files/                     # Symlinks to repo root (fixed for Helm context)
│   │   ├── certs/    → ../../../certs
│   │   ├── configs/  → ../../../shared/config
│   │   ├── scripts/  → ../../../shared/scripts
│   │   ├── tests/    → ../../../shared/tests
│   │   └── patches/  → ../../../shared/patches
│   └── templates/
│       ├── testbed-certs.yaml      # All host/CA certs — Secret
│       ├── testbed-configs.yaml    # Non-sensitive shared config — ConfigMap
│       ├── testbed-secrets.yaml    # rucio.cfg/alembic.ini/idpsecrets.json/realm.json/
│       │                           # userpass-client.cfg/fts3config — Secret
│       ├── testbed-patches.yaml    # Python source patches — ConfigMap
│       ├── testbed-scripts.yaml    # Bootstrap & entrypoint scripts — ConfigMap
│       ├── testbed-tests.yaml      # Rucio E2E test suite — ConfigMap
│       └── rucio-bootstrap-job.yaml
│
├── fts/                          # Custom image (Dockerfile.fts) — OIDC FTS server
├── xrootd/                       # rucio/test-xrootd (SciTokens)
├── keycloak/                     # quay.io/keycloak/keycloak
├── rucio-client/                 # rucio/rucio-clients
├── rucio-server/                 # upstream rucio/rucio-server, patched for configMounts
└── rucio-daemons/                # upstream rucio/rucio-daemons, patched for configMounts
```

`ruciodb` reuses `bitnami/postgresql`. `rucio-server`/`rucio-daemons` are
vendored copies of the upstream charts, carrying a local patch that adds
`configMounts` (ConfigMap-sourced mounts) alongside their native
`secretMounts` — needed since `testbed-patches` and `testbed-configs` are
ConfigMaps, not Secrets; classified by actual sensitivity, not by which
object kind happened to be convenient (see ADR-004).

These templates are the single source of truth for `testbed-configs`/
`testbed-patches`/`testbed-scripts`/`testbed-tests` across every
deployment path — GitOps renders the same templates via
`shared/scripts/render-testbed-configmaps.sh` rather than maintaining a
separate definition.

`testbed-certs` and `testbed-secrets` are the only Secrets anywhere in
this chart; everything else is a ConfigMap.

## Repairing Symlinks

```bash
cd dep-dlm-testbed/files
rm -f certs configs scripts tests patches
ln -s ../../../../certs certs
ln -s ../../../../shared/config configs
ln -s ../../../../shared/scripts scripts
ln -s ../../../../shared/tests tests
ln -s ../../../../shared/patches patches
```

## Quickstart

```sh
cd ../..
make certs   # once, from repo root

export TOKEN_MODE=managed # FTS token mode. Viable options: [managed, unmanaged]
export DAEMON_MODE=direct # Daemon mode. Viable options: [direct, daemons]
export RUNTIME=k8s

make start
```

```bash
$ kubectl get pods -n dep-dlm-sandbox
NAME                            READY   STATUS    RESTARTS   AGE
fts-5b96566fc4-6gjr5            1/1     Running   0          18s
ftsdb-0                         1/1     Running   0          18s
keycloak-55845db8df-r8f5j       1/1     Running   0          18s
rucio-server-67b9b5867-6fmkn    2/2     Running   0          18s
rucio-bootstrap-db-4gs76        0/1     Completed 0          18s
rucio-client-84c8d68bb5-jbxmj   1/1     Running   0          18s
ruciodb-0                       1/1     Running   0          18s
teapot1-57665787d9-pflps        1/1     Running   0          18s
teapot2-79b79dd45-v7tkd         1/1     Running   0          18s
xrd3-59ff7785f4-fj4jl           1/1     Running   0          18s
xrd4-5f94846b87-bjxq9           1/1     Running   0          18s
```

Tear down:

```sh
cd ../..
make stop
```
