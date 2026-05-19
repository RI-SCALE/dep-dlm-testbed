# DEP DLM Testbed — Helm Charts

Kubernetes translation of the `dep-dlm-testbed` docker-compose stack,
following the idioms of [rucio/helm-charts](https://github.com/rucio/helm-charts)
and [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial).

## Layout

```
helm-charts/
├── dep-dlm-testbed/        # Umbrella (meta) chart — deploy this
│   ├── Chart.yaml                # Declares deps on all subcharts below
│   ├── values.yaml               # Single source of truth (toggle services, OIDC, etc.)
│   ├── files/                    # Symlinks to repo root (fixed for Helm context)
│   │   ├── certs/    → ../../../certs
│   │   ├── configs/  → ../../../shared/config
│   │   └── scripts/  → ../../../shared/scripts
│   │   └── tests/    → ../../../shared/tests
│   │   └── patches/  → ../../../shared/patches
│   └── templates/
│       ├── certs-secret.yaml         # All host/CA certs as one Secret
│       ├── configs-cm.yaml           # Shared config files as ConfigMap(s)
│       ├── rucio-cfg-secrets.yaml    # Pass-through Secrets for rucio-server's secretMounts
│       └── scripts-cm.yaml           # Bootstrap & entrypoint scripts
│
├── fts/                          # Custom image (Dockerfile.fts) — OIDC FTS server
├── xrootd/                       # rucio/test-xrootd (SciTokens)
├── keycloak/                     # quay.io/keycloak/keycloak
└── rucio-client/                 # rucio/rucio-clients
```

`ruciodb` reuses `bitnami/postgresql` and the Rucio server deployment reuses the upstream `rucio/rucio-server` chart.

## Repairing Symlinks

```bash
# Navigate to the umbrella chart's files directory
cd dep-dlm-testbed/files

# Recreate corrected links (4 levels up to reach repo root)
rm -f certs configs scripts tests patches
ln -s ../../../../certs certs
ln -s ../../../../shared/config configs
ln -s ../../../../shared/scripts scripts
ln -s ../../../../shared/tests tests
ln -s ../../../../shared/patches patches
```

## Quickstart

```sh
# 1. Generate certs (once) from repo root
make certs

# 2. Create the namespace and install
kubectl create namespace dep-dlm-testbed
helm dependency update helm-charts/dep-dlm-testbed
helm install testbed helm-charts/dep-dlm-testbed --namespace dep-dlm-testbed
```

You should end up with something like:

```bash
$  kubectl get pods -n dep-dlm-testbed
NAME                            READY   STATUS    RESTARTS   AGE
fts-5b96566fc4-6gjr5            0/1     Running   0          18s
ftsdb-0                         1/1     Running   0          18s
keycloak-55845db8df-r8f5j       1/1     Running   0          18s
rucio-67b9b5867-6fmkn           1/2     Running   0          18s
rucio-bootstrap-db-4gs76        1/1     Running   0          18s
rucio-client-84c8d68bb5-jbxmj   1/1     Running   0          18s
ruciodb-0                       0/1     Running   0          18s
teapot1-57665787d9-pflps        1/1     Running   0          18s
teapot2-79b79dd45-v7tkd         1/1     Running   0          18s
xrd3-59ff7785f4-fj4jl           1/1     Running   0          18s
xrd4-5f94846b87-bjxq9           1/1     Running   0          18s
```

Tear down:

```sh
helm uninstall testbed -n dep-dlm-testbed
kubectl -n dep-dlm-testbed delete pvc --all   # PVCs aren't removed by `helm uninstall`
```
