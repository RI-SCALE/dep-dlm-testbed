# Delivering the Rucio policy package

Rucio loads the policy package by import name (`[policy] package`), so any
method that puts it on the Python path works. Options, leanest first:

| Option | How | Pros | Cons |
|---|---|---|---|
| Mount into site-packages | Bind/ConfigMap mount to `.../site-packages/<pkg>` | No build, no startup work, same in compose/Helm/GitOps | Path tied to the image's Python version; copy of the package drifts |
| Mount anywhere + `PYTHONPATH` | Mount to e.g. `/opt/rucio/policy`, set `PYTHONPATH` | Version-independent path | One more env var per container |
| `pip install` at startup | Entrypoint installs from a mounted source | Package metadata present | Slower start, needs pip at runtime; raced in Helm (`postStart` runs alongside the entrypoint) |
| Custom image (current) | `FROM rucio/rucio-server` + `pip install` | Immutable, versioned, fastest start | Image rebuild per policy release and per Rucio bump |
| Init container | Copies the package into a shared `emptyDir` on the path | Policy versioned separately from Rucio image | Extra moving part; Kubernetes only |

**Chosen:** custom image, for the testbed and as the basis for production.
`deploy/compose/Dockerfile.rucio` installs the
[rucio-opa-policy-package](https://github.com/RI-SCALE/rucio-opa-policy-package) release wheel
(pinned by sha256) on top of the official `rucio-server`/`rucio-daemons` images; `images.yml`
publishes them to `ghcr.io/ri-scale/dep-dlm-testbed`. A policy change is a package release plus
a bump of `POLICY_PKG_VERSION`/`POLICY_PKG_SHA256` and an image rebuild, so what is deployed is
always a signed, attested artifact. To try an unreleased change locally, bind-mount the
package over `site-packages` (option 1) for that run only.

## Links

- [Rucio Policy Packages Overview](https://rucio.github.io/documentation/operator/policy_packages/policy_packages_overview/)
- [rucio-opa-policy-package](https://github.com/RI-SCALE/rucio-opa-policy-package)
