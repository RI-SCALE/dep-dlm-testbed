# Backlog

- [ ] Extend test coverage with
    - [ ] `test_add_dataset` test
    - [ ] `test_add_files_to_dataset` test
    - [x] XRootD-to-Storm WebDAV transfer test
- [ ] Document patches applied to FTS, Rucio and Teapot in `shared/patches/README.md` and iteratively replace patches with proper configuration where possible
- [ ] Add configuration reference links for the technologies in use (FTS, Rucio, XrootD and Teapot), with emphasis on token-based authentication
- [ ] Deploy Rucio daemons in both Compose and Kubernetes setups and allow tests to utilise these instead of invoking `kubectl` or `docker` CLI
- [ ] S3 setup and test coverage in `shared/tests/test-rucio-transfers.py`
