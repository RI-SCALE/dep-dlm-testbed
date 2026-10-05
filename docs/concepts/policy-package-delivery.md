# Delivering the Rucio policy package

Rucio loads the policy package by import name (`[policy] package`), so any
method that puts it on the Python path works. Options, leanest first:

| Option | How | Pros | Cons |
|---|---|---|---|
| Mount into site-packages (current) | Bind/ConfigMap mount to `.../site-packages/<pkg>` | No build, no startup work, same in compose/Helm/GitOps | Path tied to the image's Python version |
| Mount anywhere + `PYTHONPATH` | Mount to e.g. `/opt/rucio/policy`, set `PYTHONPATH` | Version-independent path | One more env var per container |
| `pip install` at startup | Entrypoint installs from a mounted source | Package metadata present | Slower start, needs pip at runtime; raced in Helm (multiple containers, shared volume) |
| Custom image | `FROM rucio/rucio-server` + `pip install` | Immutable, versioned, fastest start | Image build/registry per policy change; rebuild on every Rucio bump |
| Init container | Copies the package into a shared `emptyDir` on the path | Policy versioned separately from Rucio image | Extra moving part; Kubernetes only |

Testbed: mount (option 1), since policy changes are frequent and must not require image rebuilds. Production: a custom image or a versioned
init-container image, so the deployed policy is immutable and auditable.

## Links

- [Rucio Policy Packages Overview](https://rucio.github.io/documentation/operator/policy_packages/policy_packages_overview/)
