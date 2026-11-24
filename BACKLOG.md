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
- [ ] Check-In demo/prod: split the Rucio OIDC client into a user client (authorization code, token exchange) and a client_credentials-only service client; patch `request_token`'s cc path to use the `SCIM` entry
- [ ] TLS and trust: align with the CERN Rucio instance and the partner documentation (Confluence); partners bring a private PKI or a public CA for Rucio/FTS host certificates and public TLS on the Gateway (cert-manager); FTS and storage trust the IGTF/public CAs of real RSEs
- [ ] On-premises: single-node reference validated in `dep-dlm-deployment` (kubeadm, PostgreSQL, Vault); open: partner ownership of Kubernetes, databases and Vault; fleet offerings (GKE Enterprise, Azure Arc, EKS Anywhere) and GitOps against attached clusters
- [x] Usage reporting: nightly reporter (Rucio → ARGO Accounting), dry-run on Compose, Helm, Flux and Argo CD; read-only OPA tier `rucio:reporter` — [design doc 009](docs/design/design-doc-009-dep-dlm-transfer-usage-reporter-for-argo-accounting.md)
- [ ] Usage reporter on external IdPs (EGI Check-In Dev, LS AAI): client_credentials tokens carry no entitlement; asked both IdPs, bridge is an `iss` + `sub` whitelist in OPA
- [ ] Usage reporter writes to ARGO devel, then staging and production (needs GRNET credentials)

## 3. Production enablement

Tracked in [dep-dlm-deployment](https://github.com/RI-SCALE/dep-dlm-deployment) (curated Terraform/GitOps, deployment CI, promotion, upgrades).
Testbed side:

- [ ] Partner runbooks: [01–07](docs/runbooks/) done; open: TLS and trust (once decided, section 2)

## 4. Technology evolution

- [ ] FTS4, once mature; not blocking `dep-dlm-deployment`
- [ ] **Optional:** second hyperscaler (EKS/AKS) and Vault-backed secrets on a hyperscaler
- [ ] Additional storage technologies, as use cases require

## 5. Research infrastructure adoption

- [x] Third-party copies from public RI holdings (ENES_DKRZ, EBI_BIA_BIOSTUDIES): HTTP-TPC pull into TEAPOT1 and XRD3, as on the CERN RI-SCALE instance (`make test-public-ri-transfers`)
- [ ] Third-party copies from token-protected RI holdings (EISCAT_WEBDAV, Teapot): clarify the accepted issuer/audience, then the same test with a token-capable source
- [ ] Partner integration and operational handover
