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
- [x] Map LS AAI user entitlements to ODRL tiers
- [ ] Storage authorization hardening: Teapot VO mapping via `eduperson_entitlement` as an alternative to file mapping; check whether XRootD SciTokens supports group/entitlement-based authorization
- [x] External storage: testbed-owned XRootD/Teapot VM with public endpoint, registered as RSEs, e2e tests run against it
- [x] Upstream compatibility: minimal patches to Rucio, FTS, Teapot documented in [docs/patches.md](docs/patches.md); FTS manages the token lifecycle (token exchange)

## 2. Production architecture validation

- [x] GitOps with Argo CD and Flux (sandbox, staging), upstream charts with DEP DLM overlays
- [x] Terraform on GCP: GKE, Cloud SQL, Secret Manager + External Secrets, Gateway API public endpoints; full rebuild validated in CI
- [x] Observability: Managed Prometheus, Cloud Logging, Cloud Monitoring dashboards and alert policies — [design doc 005](docs/design/design-doc-005-observability.md)
- [ ] Decide whether transfer events are needed beyond metrics and logs (design-005 phase 3: Hermes to the log backend vs ActiveMQ/OpenSearch)
- [ ] Production reference environment applied and validated end to end
- [ ] TLS and trust: align with the CERN Rucio instance and the partner documentation (Confluence); partners bring a private PKI or a public CA for Rucio/FTS host certificates and public TLS on the Gateway (cert-manager); FTS trusts the IGTF/public CAs of real RSEs
- [ ] On-premises: single-node reference validated in `dep-dlm-deployment` (kubeadm, PostgreSQL, Vault); open: partner ownership of Kubernetes, databases and Vault; fleet offerings (GKE Enterprise, Azure Arc, EKS Anywhere) and GitOps against attached clusters

## 3. Production enablement

Tracked in [dep-dlm-deployment](https://github.com/RI-SCALE/dep-dlm-deployment) (curated Terraform/GitOps, deployment CI, promotion, upgrades).
Testbed side:

- [ ] Partner runbooks: [01–07](docs/runbooks/) done; open: TLS and trust (once decided, section 2)

## 4. Technology evolution

- [ ] FTS4, once mature; not blocking `dep-dlm-deployment`
- [ ] **Optional:** second hyperscaler (EKS/AKS) and Vault-backed secrets on a hyperscaler
- [ ] Additional storage technologies, as use cases require

## 5. Research infrastructure adoption

- [ ] Third-party copies from public RI holdings (ENES_DKRZ, EBI_BIA_BIOSTUDIES; anonymous HTTPS, same endpoints as on the CERN RI-SCALE instance): one small file per RI replicated into the testbed's own storage (`make test-public-ri-transfers`), Compose first, then CI; settle which CA bundle FTS and Teapot need for public endpoints
- [ ] Third-party copies from token-protected RI holdings (EISCAT_WEBDAV, Teapot): clarify the accepted issuer/audience, then the same test with a token-capable source. MUSICA_* and TUBITAK_WEBDAV as destinations later
- [ ] **Optional:** use cases register further RSEs for their data holdings ([runbook 03](docs/runbooks/03-bring-your-own-storage.md)); sensitive/personal holdings (e.g. BBMRI): real destination in CI, synthetic source from the testbed's own storage
- [ ] Partner integration and operational handover
