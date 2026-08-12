# Backlog

## Testing

- [x] Extend test coverage with
    - [x] `test_add_dataset` test
    - [x] `test_add_files_to_dataset` test
    - [x] XRootD-to-Storm WebDAV transfer test
- [x] Test replication rule deletion lifecycle via Rucio daemons

## Configuration & Patches

- [x] Add configuration reference links for the technologies in use (FTS, Rucio, XrootD and Teapot), with emphasis on token-based authentication
- [x] Patches
    - [x] Document patches applied to FTS, Rucio and Teapot
- [x] Adjust patches where possible to support managed configuration using token exchange instead of unmanaged configuration for FTS, allowing FTS to manage the token lifecycle
- [x] Add a DAEMON_MODE flag (direct | daemons): run Rucio daemons as long-running services in Compose and Kubernetes, with the test harness switching between direct `--run-once` CLI invocation (deterministic, current behaviour) and polling the running daemons

## GitOps Deployment

- [x] Enable GitOps-based deployment for DEP DLM data orchestration layer workloads (Argo CD or Flux), using the testbed Helm charts as the initial blueprint. Prefer upstream charts where available (e.g. the official rucio/helm-charts for rucio-server and rucio-daemons, Bitnami PostgreSQL) with DEP DLM-specific overlays on top.
- [x] Validate staging GitOps deployment against real external infrastructure on a hyperscaler: provisioned a managed Kubernetes cluster (GKE), PostgreSQL (Cloud SQL), and GCP Secret Manager (via External Secrets Operator) as the testbed's own validation target, automated via Terraform; wired to external AAI federation hubs as the OIDC issuer (both EGI Check-In Dev and LS AAI Perun); confirmed convergence on both Argo CD and Flux, verified at the pod level (rucio-server, rucio-daemons, fts Running with correct DB connections, OIDC credentials, and certs).
- [ ] Expose rucio-server/fts via a public endpoint — Gateway API preferred over classic Ingress (GKE's current recommended path, and more portable in API shape across hyperscalers than provider-specific Ingress controllers). Confirms external reachability; doesn't require a registered RSE.
- [ ] Provision a testbed-owned XRootD/Teapot validation target with a public endpoint (separate Terraform module, e.g. `modules/validation-storage` — GCP VMs, a lean install script for XRootD/Teapot), register it as an RSE against the module's own Terraform outputs (VM IP/hostname) — protocol/PFN config, distance/attribute setup, extending the existing seeding mechanism (`init-testbed.sh`, which currently only knows sandbox's hardcoded values) — and run the existing e2e transfer tests (`test-rucio-transfers`, `test-copernicus-transfers`, `test-rucio-deletion`) against it. Genuinely validates the full external-storage integration path — real network reachability, real WebDAV/XRootD protocol handling, real OIDC token flow — not just in-cluster plumbing, since it's publicly reachable and runs the same software stack a partner endpoint would. Not necessarily representative of scale or backend specifics for every RI-SCALE use case's actual storage.
- [ ] **Optional:** extend/repeat the above once RI-SCALE use cases register a real RSE against their own data holdings — same protocol/PFN/distance-attribute pattern, against a real production endpoint. Data holdings are owned by the use cases, not this testbed, so this remains an extension the use cases opt into rather than a required follow-on. Follow-on to runbook 03 (bring-your-own-storage).
- [ ] **Optional:** Extend the above to a second hyperscaler (EKS/AKS) for multi-cloud parity, and/or validate a Vault-on-hyperscaler variant — this round deliberately moved staging/production off Vault onto GCP Secret Manager (sandbox keeps Vault), so Vault-backed secrets management on a hyperscaler remains unvalidated.
- [ ] Validate the same against on-premise infrastructure: provisioning of Vault, PostgreSQL and the Kubernetes cluster is anticipated to require manual or partner-managed setup rather than automated tooling — needs clarification with the partner on who owns this provisioning and whether it happens via IaC outside the GitOps deployment scope.
- [ ] Set up a dedicated `dep-dlm-deployment` repo (Terraform to provision managed Kubernetes/DB/secrets on a public cloud, plus the GitOps convergence on top — for partners without on-premises infrastructure, or for whom maintaining it is impractical), separate from the testbed.

## Documentation & Runbooks

- [ ] Provide runbooks explaining the key configurations to apply (Rucio rucio.cfg, OIDC, FTS, RSE settings, certificates, WP4 token-provider integration) so partners and DEP owners can deploy and operate their own workloads — applying their own sensitive credentials, which are not checked into this repository.
    - [x] Sandbox quickstart end-to-end — see [01-sandbox-quickstart.md](docs/runbooks/01-sandbox-quickstart.md).
    - [x] Bring-your-own runbook set (IdP, storage, config reference) + index — see [docs/runbooks/](docs/runbooks/).
    - [ ] Remaining staging/production runbooks: external Vault secrets, certificate installation (Rucio/FTS) and observability.

## External Identity Provider Integration

- [x] Replicate the CERN FTS and Rucio test-instance configurations for integration against an external token provider (EGI Check-In Dev), with proper certificate installation for trusted connections to the IAM backend — see [06-adding-a-new-idp-profile.md](docs/runbooks/06-adding-a-new-idp-profile.md) and the `SCOPE_PROFILE=egi-dev` CI workflow. Sensitive values (real idpsecrets, cert keys) are NOT checked in — supplied per-environment via Vault/external-secrets or local env files; the repo holds only templated/example configs.
- [x] Integrate the testbed against LS AAI (Perun) as a second external token provider, following the `06-adding-a-new-idp-profile.md` pattern. Confirm `resource=` support on client_credentials and token-exchange first - constraints differ from EGI/IAM and may require `scope_profile` to become a per-IdP capability flag rather than a binary wlcg/egi switch.

## Authorization

- [ ] Storage authorization hardening (XRootD SciTokens + Teapot Storm-WebDAV): VO-based Teapot mapping via `eduperson_entitlements` — configure Keycloak to issue `eduperson_entitlement` claims alongside `wlcg.groups` and demonstrate Teapot's VO mapping mode as an alternative to FILE mapping (requires group membership claims not available on the current service account token path). Investigate whether equivalent group/entitlement-based authorization exists for XRootD SciTokens (current understanding: scope-based only).
- [ ] Design & scaffold an Authorization Service as its own repository (e.g. `dep-authz-service`), in Go, embedding OPA via its native SDK to avoid an extra network hop — see opa-policy-package ADRs ([authorization-service](https://github.com/mgajek-cern/opa-policy-package/blob/main/docs/adrs/adr-001-authz-service.md), [opa-deployment-topology](https://github.com/mgajek-cern/opa-policy-package/blob/main/docs/adrs/adr-003-opa-deploy-topology.md)) for the contract. Consumers: Rucio and, on behalf of storage endpoints, their AAI IAM; FTS is out of scope as a direct consumer per the ADR. OpenAPI-first, plain direct integration only (no service mesh, per the deployment-topology ADR — storage-endpoint deployment model still needs confirmation before that's finalized). Reuse the Rego policy bundles and Phase 4 OIDC/Keycloak integration already built in [opa-policy-package](https://github.com/mgajek-cern/opa-policy-package/tree/main) rather than rebuilding them. Once available, this testbed integrates against it rather than building authorization logic itself.
