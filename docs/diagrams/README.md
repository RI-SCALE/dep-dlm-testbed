# Deployment views

Generated from code with [diagrams](https://diagrams.mingrammer.com); the
`.py` files are the source, `generated/*.png` the committed renderings.

```bash
pip install diagrams          # needs graphviz (`dot`)
cd docs/diagrams
for f in sandbox staging production staging_gcp; do python3 "$f.py"; done
```

| | Sandbox | Staging | Production | Staging (GCP) |
|---|---|---|---|---|
| Audience | developers | RI integration engineers | RI end users | RI integration engineers |
| IdP | bundled Keycloak | external AAI | external AAI | external AAI |
| Secrets | in-cluster Vault (dev) | partner Vault | partner Vault | Secret Manager |
| PostgreSQL | in-cluster | managed | managed | Cloud SQL |
| Storage RSEs | bundled XRootD/WebDAV | external | external | external + validation VM |
| OPA | in-cluster, Job-ingested | in-cluster, policy bundle | in-cluster, policy bundle | in-cluster, policy bundle |
| Observability | in-cluster stack (`OBSERVABILITY=1`) | collectors in-cluster, external backend | collectors in-cluster, external backend | Managed Prometheus + Cloud Logging |
| Scale / ingress | single replica, none | single replica, TLS | scaled, public DNS/TLS | single replica, GKE Gateway |

Staging and production share one shape on purpose; production only adds scale. Ingress choice, Terraform provisioning and per-RI fan-out are covered in [Design-007: GitOps deployment blueprint](../design/design-doc-007-gitops-blueprint.md)(original
design).
