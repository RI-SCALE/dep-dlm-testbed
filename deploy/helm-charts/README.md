# DEP DLM Testbed — Helm Charts

Kubernetes translation of the `dep-dlm-testbed` docker-compose stack,
following the idioms of [rucio/helm-charts](https://github.com/rucio/helm-charts)
and [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial).

## Layout

```
helm-charts/
├── dep-dlm-testbed/            # Umbrella chart — deploy this
│   ├── Chart.yaml              # Subcharts below (file://) plus external ones
│   ├── values.yaml             # Single source of truth (toggles, OIDC, images)
│   ├── files/                  # Symlinks to the repo root (Helm can't read outside the chart)
│   │   ├── certs/    → <repo>/certs
│   │   ├── configs/  → <repo>/configs
│   │   ├── scripts/  → <repo>/scripts
│   │   ├── tests/    → <repo>/tests
│   │   └── patches/  → <repo>/patches
│   └── templates/
│       ├── testbed-certs.yaml           # Host and CA certs — Secret
│       ├── testbed-secrets.yaml         # rucio.cfg, alembic.ini, idpsecrets.json, realm.json,
│       │                                # userpass-client.cfg, fts3config — Secret
│       ├── testbed-configs.yaml         # Non-sensitive shared config — ConfigMap
│       ├── testbed-patches.yaml         # Python source patches — ConfigMap
│       ├── testbed-scripts.yaml         # Bootstrap and entrypoint scripts — ConfigMap
│       ├── testbed-tests.yaml           # E2E test suite — ConfigMap
│       ├── opa-policies-cm.yaml         # authz.rego and ODRL policies — ConfigMap
│       ├── opa-evaluator.yaml           # Vendored ODRL evaluator — ConfigMap
│       ├── opa-ingest-policies-job.yaml # Pushes policies into OPA (hook)
│       └── rucio-bootstrap-job.yaml     # Rucio DB bootstrap (hook)
├── fts/              # FTS3 server (+ optional ftsdb) — ghcr.io/ri-scale/dep-dlm-containers/fts
├── keycloak/         # Keycloak for local OIDC — quay.io/keycloak/keycloak
├── observability/    # Exporters, alert rules, dashboard (design-doc-005)
├── opa/              # OPA server for the Rucio policy package — openpolicyagent/opa
├── rucio-client/     # Test runner pod — ghcr.io/ri-scale/dep-dlm-testbed/rucio-client
├── teapot/           # Teapot WebDAV — ghcr.io/ri-scale/dep-dlm-testbed/teapot
└── xrootd/           # XRootD with SciTokens (xrd3, xrd4) — rucio/test-xrootd (pinned by digest)
```

External subcharts (`helm dependency update` fetches them; versions in `Chart.lock`):

- `ruciodb`: bitnami/postgresql.
- `rucio-server`, `rucio-daemons`: a fork of rucio/helm-charts, pinned to a
  commit, that adds `configMounts` (ConfigMap-sourced mounts) next to the
  native `secretMounts`. Needed because `testbed-patches` and
  `testbed-configs` are ConfigMaps, not Secrets: classified by actual
  sensitivity, not by which object kind happened to be convenient (ADR-004).
- kube-prometheus-stack, Loki and Alloy (with `observability.enabled`).
- `usage-reporter`: `oci://ghcr.io/ri-scale/charts/dep-dlm-usage-reporter`,
  a nightly CronJob (dry-run in the testbed).

These templates are the single source of truth for `testbed-configs`/
`testbed-patches`/`testbed-scripts`/`testbed-tests` across every
deployment path — GitOps renders the same templates via
`scripts/render-testbed-configmaps.sh` rather than maintaining a
separate definition.

`testbed-certs` and `testbed-secrets` are the only Secrets in this chart;
everything else is a ConfigMap.

## Repairing Symlinks

```bash
cd dep-dlm-testbed/files
rm -f certs configs scripts tests patches
ln -s ../../../../certs certs
ln -s ../../../../configs configs
ln -s ../../../../scripts scripts
ln -s ../../../../tests tests
ln -s ../../../../patches patches
```

## Quickstart

```sh
cd ../..
make certs   # once, from repo root

export TOKEN_MODE=managed # FTS token mode: managed | unmanaged
export DAEMON_MODE=direct # Daemon mode: direct | daemons
export RUNTIME=k8s

make start
```

```bash
$ kubectl get pods -n dep-dlm-sandbox
NAME                            READY   STATUS      RESTARTS   AGE
fts-5b96566fc4-6gjr5            1/1     Running     0          18s
ftsdb-0                         1/1     Running     0          18s
keycloak-55845db8df-r8f5j       1/1     Running     0          18s
opa-7c9f6d5b8b-q2wkz            1/1     Running     0          18s
rucio-server-67b9b5867-6fmkn    2/2     Running     0          18s
rucio-bootstrap-db-4gs76        0/1     Completed   0          18s
rucio-client-84c8d68bb5-jbxmj   1/1     Running     0          18s
ruciodb-0                       1/1     Running     0          18s
teapot1-57665787d9-pflps        1/1     Running     0          18s
teapot2-79b79dd45-v7tkd         1/1     Running     0          18s
xrd3-59ff7785f4-fj4jl           1/1     Running     0          18s
xrd4-5f94846b87-bjxq9           1/1     Running     0          18s
```

Tear down:

```sh
cd ../..
make stop
```
