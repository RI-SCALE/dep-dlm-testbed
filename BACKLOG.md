# Backlog

- [x] Extend test coverage with
    - [x] `test_add_dataset` test
    - [x] `test_add_files_to_dataset` test
    - [x] XRootD-to-Storm WebDAV transfer test
- [x] Test replication rule deletion lifecycle via Rucio daemons
- [x] Add configuration reference links for the technologies in use (FTS, Rucio, XrootD and Teapot), with emphasis on token-based authentication
- [x] Patches
    - [x] Document patches applied to FTS, Rucio and Teapot
- [x] Adjust patches where possible to support managed configuration using token exchange instead of unmanaged configuration for FTS, allowing FTS to manage the token lifecycle
- [x] Add a DAEMON_MODE flag (direct | daemons): run Rucio daemons as long-running services in Compose and Kubernetes, with the test harness switching between direct `--run-once` CLI invocation (deterministic, current behaviour) and polling the running daemons
- [ ] Enable GitOps-based deployment for DEP DLM data orchestration layer workloads (Argo CD or Flux), using the testbed Helm charts as the initial blueprint. Prefer upstream charts where available (e.g. the official rucio/helm-charts for rucio-server and rucio-daemons, Bitnami PostgreSQL) with DEP DLM-specific overlays on top. Provide runbooks briefly explaining the most important configurations to apply (e.g. Rucio rucio.cfg, OIDC, FTS, RSE settings) so that
partners can deploy and operate their own DEP DLM data orchestration workloads.
- [ ] Ensure internal Helm charts follow Helm and Kubernetes best practices for consistency, security, maintainability and CI validation
- [ ] S3 setup and test coverage in `shared/tests/test-rucio-transfers.py`
- [ ] VO-based Teapot mapping via `eduperson_entitlements`: configure Keycloak to issue `eduperson_entitlement` claims alongside `wlcg.groups` and demonstrate Teapot's VO mapping mode as an alternative to FILE mapping (requires group membership claims not available on the current service account token path). Investigate whether equivalent group/entitlement-based authorization exists for XRootD SciTokens (current understanding: scope-based only).
