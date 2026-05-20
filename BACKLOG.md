# Backlog

- [x] Extend test coverage with
    - [x] `test_add_dataset` test
    - [x] `test_add_files_to_dataset` test
    - [x] XRootD-to-Storm WebDAV transfer test
- [x] Test replication rule deletion lifecycle via Rucio daemons
- [ ] Document patches applied to FTS, Rucio and Teapot in `shared/patches/README.md` and iteratively replace patches with proper configuration where possible
- [ ] Add configuration reference links for the technologies in use (FTS, Rucio, XrootD and Teapot), with emphasis on token-based authentication
- [ ] Deploy Rucio daemons in both Compose and Kubernetes setups and allow tests to utilise these instead of invoking `kubectl` or `docker` CLI
- [ ] S3 setup and test coverage in `shared/tests/test-rucio-transfers.py`
- [ ] VO-based Teapot mapping via `eduperson_entitlements`: configure Keycloak to issue `eduperson_entitlement` claims alongside `wlcg.groups` and demonstrate Teapot's VO mapping mode as an alternative to FILE mapping (requires group membership claims not available on the current service account token path). Investigate whether equivalent group/entitlement-based authorization exists for XRootD SciTokens (current understanding: scope-based only).
