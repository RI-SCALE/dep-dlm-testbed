# Backlog

- Extend test coverage with `test_add_dataset`, `test_add_files_to_dataset` and XRootD-to-Storm WebDAV transfer test cases
- Document patches applied to FTS, Rucio and Teapot in `shared/patches/README.md` and iteratively replace patches with proper configuration where possible
- Add configuration reference links for the technologies in use (FTS, Rucio and Teapot), with emphasis on token-based authentication
- Deploy Rucio daemons in both Compose and Kubernetes setups and allow tests to utilise these instead of invoking `kubectl` or `docker` CLI
