# Runbook 6 — Secrets via GCP Secret Manager + ExternalSecrets

## Purpose
How staging/production actually provision secrets — Terraform-managed GCP
Secret Manager entries, synced into the cluster via ExternalSecrets
Operator (ESO) over Workload Identity. This supersedes the originally
planned "external Vault" approach; **sandbox alone still uses in-cluster
Vault** (`deploy/gitops/flux/components/vault.yaml`) — nothing below
applies there.

## Prerequisites
- `deploy/terraform/modules/secrets` applied for the target environment
  (`make tf-apply TF_ENV=<env>`) — this is what actually creates the
  Secret Manager entries.
- ESO installed via `make argocd-install`/`make flux-install`
  `GITOPS_ENV=<env>`, which installs it **into the environment's own
  namespace** (`dep-dlm-<env>`, e.g. `dep-dlm-staging`) as
  `external-secrets-<env>` — not a separate `external-secrets` namespace.
  Its ServiceAccount must be Workload-Identity-bound to the
  `eso_service_account_email` Terraform output — see Steps below if this
  binding hasn't been done yet.

## Configuration reference

| What | Where |
|---|---|
| Terraform module | `deploy/terraform/modules/secrets/` |
| What gets created | Two GCP Secret Manager secrets per environment: `certs` and `secrets` — each holding multiple files as key/value pairs (rendered from `templates/*.tftpl`: `idpsecrets.json`, `oidc-client.cfg`, `rucio.cfg`, `alembic.ini`, `userpass-client.cfg`, `fts3config`, `fts3restconfig`, `fts3-docker-entrypoint.sh`) |
| Terraform output | `secret_ids = { certs = "...", secrets = "..." }` — full Secret Manager resource IDs, per environment's `main.tf`/`outputs.tf` |
| ESO connector | `deploy/gitops/environments/<env>/secrets/clustersecretstore.yaml(.tmpl)` — `gcpsm` provider, authenticates via Workload Identity (no static key) |
| Sync target | `deploy/gitops/environments/<env>/secrets/testbed-secrets.yaml`, `testbed-certs.yaml` — `ExternalSecret` resources that pull from the two Secret Manager entries above into in-cluster `Secret`s the Helm charts mount |
| Wiring | `deploy/gitops/environments/<env>/secrets/kustomization.yaml` ties the `ClusterSecretStore` + both `ExternalSecret`s together as one Kustomization |
| Workload Identity binding | `eso_service_account_email` Terraform output — must be annotated onto ESO's k8s ServiceAccount (`iam.gke.io/gcp-service-account=<this>`) for the `ClusterSecretStore` to authenticate |

`staging` additionally ships a `clustersecretstore.yaml.tmpl` (templated)
alongside a plain `clustersecretstore.yaml` — check which one is actually
referenced by that environment's `kustomization.yaml` before assuming
either is live; `production` only has the `.tmpl` variant.

## Steps

1. **Apply Terraform** for the target environment — this creates/updates
   the two Secret Manager secrets and (re)renders their contents from the
   `templates/*.tftpl` files against current `terraform.tfvars`:
   ```bash
   make tf-apply TF_ENV=<env>
   make tf-output TF_ENV=<env>   # note secret_ids and eso_service_account_email
   ```

2. **Install/reconcile GitOps**, which brings up ESO in `dep-dlm-<env>`:
   ```bash
   make argocd-install GITOPS_ENV=<env>   # or: make flux-install GITOPS_ENV=<env>
   ```

3. **Find ESO's actual ServiceAccount name** — don't assume it, confirm
   it, since it's derived from the Helm release name:
   ```bash
   kubectl -n dep-dlm-<env> get sa | grep external-secrets
   ```

4. **Confirm the Workload Identity binding** on that ServiceAccount:
   ```bash
   kubectl -n dep-dlm-<env> get sa <name from step 3> -o yaml | grep -A2 annotations
   # expect: iam.gke.io/gcp-service-account: <eso_service_account_email from step 1>
   ```
   If missing, this should be set by the GitOps install itself (check
   `deploy/gitops/{argocd,flux}`'s ESO wiring — likely a
   `serviceAccount.annotations` Helm value templated from the Terraform
   output) rather than patched by hand, so the fix survives the next
   reconcile. Re-run step 2 after fixing the source.

5. **Confirm the `ClusterSecretStore` is healthy**:
   ```bash
   kubectl get clustersecretstore -o wide
   kubectl describe clustersecretstore <name>   # check Status.Conditions
   ```

6. **Confirm both `ExternalSecret`s are syncing**:
   ```bash
   kubectl -n dep-dlm-<env> get externalsecret
   kubectl -n dep-dlm-<env> describe externalsecret testbed-secrets
   kubectl -n dep-dlm-<env> describe externalsecret testbed-certs
   ```
   `SecretSynced` / `Ready: True` on both means the in-cluster `Secret`s
   are populated and Helm-mounted values should be current.

## Rotation

Rotation is Terraform-applied, not edited in-cluster:

1. Update the source value (OIDC client secret, DB password, cert
   material, etc.) — either a `terraform.tfvars` change or whatever
   upstream input feeds that `.tftpl` template.
2. `make tf-apply TF_ENV=<env>` — this writes a **new version** of the
   Secret Manager entry.
3. Force ESO to pick it up rather than waiting for its normal refresh
   interval:
   ```bash
   kubectl -n dep-dlm-<env> annotate externalsecret testbed-secrets \
     force-sync="$(date +%s)" --overwrite
   kubectl -n dep-dlm-<env> annotate externalsecret testbed-certs \
     force-sync="$(date +%s)" --overwrite
   ```
4. Restart whatever actually reads the value from its mounted Secret —
   env vars and volume-mounted files are not hot-reloaded by the
   consuming pods:
   ```bash
   kubectl -n dep-dlm-<env> rollout restart deployment rucio-server \
     rucio-daemons-conveyor-submitter rucio-daemons-conveyor-poller \
     rucio-daemons-conveyor-finisher fts
   ```

## Verification

```bash
# Confirm the in-cluster Secret actually has current values (not stale)
kubectl -n dep-dlm-<env> get secret testbed-secrets -o jsonpath='{.data.idpsecrets\.json}' | base64 -d

# Cross-check against Secret Manager directly (name is dep-dlm-<env>-secrets)
gcloud secrets versions access latest \
  --secret=dep-dlm-<env>-secrets --project=<project_id>
# e.g.: --secret=dep-dlm-staging-secrets --project=dep-dlm-staging-e52e0d90
```
If these diverge, the `ExternalSecret` hasn't synced yet — re-check step 4
above (`force-sync` annotation) before assuming Terraform failed.
