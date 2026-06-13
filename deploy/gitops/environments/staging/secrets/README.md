# environments/staging/secrets/ — keep from your working tree

Copy your overlays/staging/clustersecretstore.yaml here (same store NAME
dep-dlm-vault, real Vault, kubernetes auth, NO seed job). Then a
kustomization.yaml listing:
  - ../../../base/externalsecrets
  - clustersecretstore.yaml
with `namespace: dep-dlm-staging`.
Operator seeds real Vault with secrets and prepares rucio db schema trough a seed-job.yaml similar to `environments/sandbox/secrets/seed-job.yaml` with different connection credentials.
