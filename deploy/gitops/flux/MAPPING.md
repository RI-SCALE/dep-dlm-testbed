# Argo -> Flux mapping (essentials)

| Argo construct                          | Flux equivalent                                  |
|-----------------------------------------|--------------------------------------------------|
| ApplicationSet (list generator)         | directory of HelmRelease + per-env Kustomization |
| Application (chart + values)            | HelmRelease (chart.spec.sourceRef + valuesFrom)  |
| repoURL: <chart repo>                   | HelmRepository source object (one per registry)  |
| $values multi-source valueFiles         | HelmRelease.valuesFrom -> ConfigMap of values    |
| repoURL: <git> path: <chart>            | HelmRelease w/ chart.spec.sourceRef GitRepository|
| repoURL: <git> path: <dir> (bootstrap)  | Flux Kustomization (path:) + dependsOn           |
| sync-wave ordering                      | HelmRelease.dependsOn / Kustomization.dependsOn  |
| app-of-apps root                        | one env Kustomization aggregating components+secrets |
| destination.namespace                   | HelmRelease.targetNamespace / Kustomization.targetNamespace |
| automated{prune,selfHeal}               | Flux is pruning+self-healing by default          |
| fullnameOverride (naming discipline)    | SAME — carries over verbatim                      |

Key asymmetry: Flux Kustomization has NO cross-dir load-restrictor, so a shared
components/ dir referenced from env overlays works natively (the thing Argo
rejected). That's why this layout is DRY without ApplicationSet templating.
