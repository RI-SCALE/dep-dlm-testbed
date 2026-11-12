# Backlog

The testbed validates the DEP DLM architecture; validated patterns are
promoted into `dep-dlm-deployment` for partner deployments. Sections follow
that path, from validation to adoption.

## 1. Architecture validation

- [x] E2E tests: transfers (XRootD, Teapot WebDAV, XRootD→Storm-WebDAV, Copernicus S3), datasets, rule deletion lifecycle via the daemons
- [x] `DAEMON_MODE` (direct | daemons) on Compose and Kubernetes
- [x] Identity providers: EGI Check-In Dev and LS AAI (Perun), managed and unmanaged token modes — [runbook 05](docs/runbooks/05-adding-a-new-idp-profile.md)
- [x] Authorization: Rucio delegates to OPA via the `rucio_opa_v1_policy` package, reusing [opa-policy-package](https://github.com/mgajek-cern/opa-policy-package/tree/main); enabled on sandbox and staging
- [x] Map EGI user entitlements (e.g. `ri-scale-*` groups) to ODRL tiers
- [ ] Map LS AAI user entitlements to ODRL tiers
- [ ] Storage authorization hardening: Teapot VO mapping via `eduperson_entitlement` as an alternative to file mapping; check whether XRootD SciTokens supports group/entitlement-based authorization
- [x] External storage: testbed-owned XRootD/Teapot VM with public endpoint, registered as RSEs, e2e tests run against it
- [x] Upstream compatibility: minimal patches to Rucio, FTS, Teapot documented in [docs/patches.md](docs/patches.md); FTS manages the token lifecycle (token exchange)

## 2. Production architecture validation

- [x] GitOps with Argo CD and Flux (sandbox, staging), upstream charts with DEP DLM overlays
- [x] Terraform on GCP: GKE, Cloud SQL, Secret Manager + External Secrets, Gateway API public endpoints; full rebuild validated in CI
- [x] Observability: Managed Prometheus, Cloud Logging, Cloud Monitoring dashboards and alert policies — [design doc 005](docs/design/design-doc-005-observability.md)
- [ ] Observability phase 3 and open questions (design doc 005)
- [ ] Production reference environment applied and validated end to end
- [ ] Certificates: Rucio/FTS certificate installation; public TLS for the Gateway hostnames (cert-manager, CA choice open)
- [ ] On-premises validation: clarify partner ownership of Kubernetes, PostgreSQL and Vault provisioning; evaluate fleet offerings (GKE Enterprise, Azure Arc, EKS Anywhere) and GitOps against attached clusters

## 3. Production enablement

- [ ] `dep-dlm-deployment` repository: curated Terraform and GitOps for partners, not a copy of the testbed
- [ ] Promotion process: each promoted component has a validated source commit, supported version, CI evidence, configuration requirements and known limitations
- [ ] Production configuration and defaults extracted from the testbed
- [ ] Deployment CI
- [ ] Upgrade and rollback procedures
- [ ] Partner runbooks for configuration (Rucio, OIDC, FTS, RSEs, certificates, WP4 token provider), with credentials supplied by the partner
    - [x] [01–07](docs/runbooks/): sandbox quickstart, IdP, storage, validation storage, IdP profiles, secrets (Secret Manager + ESO), observability
    - [ ] Certificates (Rucio/FTS, public TLS)

## 4. Technology evolution

- [ ] FTS4, once mature; not blocking `dep-dlm-deployment`
- [ ] **Optional:** second hyperscaler (EKS/AKS) and Vault-backed secrets on a hyperscaler
- [ ] Additional storage technologies, as use cases require

## 5. Research infrastructure adoption

- [ ] **Optional:** use cases register real RSEs for their data holdings ([runbook 03](docs/runbooks/03-bring-your-own-storage.md))
    - [ ] Public holdings: validated end to end in CI
    - [ ] Sensitive/personal holdings: real destination in CI, synthetic source from the testbed's own storage
- [ ] Partner integration and operational handover
