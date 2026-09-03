# Developing GitOps on a child branch

The sandbox GitOps path clones and reconciles from a **branch ref baked into
several manifests**. On `main` these all say `main`. To test a child branch,
you must point them at your branch, then revert before merge.

## Refs to change (main → <your-branch>)

| File | Field |
|------|-------|
| `deploy/gitops/flux/flux-system/gitrepository-dep-dlm-testbed.yaml` | `spec.ref.branch` |
| `deploy/gitops/argocd/applicationsets/{sandbox,staging,production}.yaml` | every `targetRevision` and `ref: values` source pointing at `ri-scale/dep-dlm-testbed.git` |
| `deploy/gitops/argocd/entrypoints/app-of-apps-{sandbox,staging,production}.yaml` | `source.targetRevision` (apps + secrets) |

**No longer a row here:** `environments/sandbox/secrets/seed-job.yaml` — that
file is gone. Vault seeding and the DB-bootstrap Job are now imperative scripts
(`shared/scripts/seed-vault.sh`, `shared/scripts/run-bootstrap-db.sh`), and
`init-argocd.sh`/`init-flux.sh` pass `--repo-url`/`--revision` straight through
to them. Pointing `make argocd-install`/`make flux-install` at your branch via
`GITOPS_REPO_URL`/`GITOPS_REVISION` is now sufficient for those two steps —
nothing to hand-edit.

**Also not a row to touch — ever:** anything sourcing the Rucio chart fork
(`mgajek-cern/helm-charts.git`), namely:
- `deploy/gitops/flux/flux-system/gitrepository-rucio-charts-fork.yaml`
- the `rucio-server`/`rucio-daemons` chart sources inside
  `argocd/applicationsets/<env>.yaml` (`repoURL:
  https://github.com/mgajek-cern/helm-charts.git`, `targetRevision: master`)

These track the Rucio chart fork's own `master` branch, independent of
whatever branch of `dep-dlm-testbed` you're testing. `--revision`/
`GITOPS_REVISION` never touches them by design — the `dep-dlm-testbed`
`GitRepository` was deliberately split out of the fork's `GitRepository` into
its own file specifically so a blanket branch override can't bleed across.
If you patch this by hand and accidentally repoint the fork's `branch:` to
your feature branch, `rucio-charts-fork` will fail with `couldn't find
remote ref` (it doesn't exist in that repo), and `rucio-server`/`rucio-daemons`
will never get a HelmChart artifact.

Quick sweep to find any you missed (excludes the fork's permanent `master`
pin and pinned chart versions, which are correct as-is):
```bash
grep -rn "targetRevision:\|branch:" deploy/gitops | grep -v "41.2.1\|0.10.7\|0.28.1\|18.3.0\|master"
```

## Why

`init-argocd.sh --revision` / `init-flux.sh --revision` override:
- the app-of-apps root's own source (Argo) / the `dep-dlm-testbed`
  `GitRepository` ref (Flux) — always
- `seed-vault.sh` and `run-bootstrap-db.sh`'s clone/apply revision — always; these are script flags now, not committed refs

They do **not** override:
- the inner ApplicationSet's per-component `targetRevision`/`ref: values` (Argo) —
  those are read straight from whatever's committed in
  `argocd/applicationsets/<env>.yaml`, regardless of what you pass on the CLI
- the `rucio-charts-fork` `GitRepository` (Flux) or the fork's `repoURL`/
  `targetRevision` inside the ApplicationSets (Argo) — these are a separate
  source entirely and are pinned to the fork's own `master` branch, not this
  repo's branch

So the remaining manual-edit surface is smaller than it used to be — just the
`dep-dlm-testbed` ApplicationSet/entrypoint refs, not the seed/bootstrap path,
and never the Rucio chart fork sources.

## Workflow
1. Flip the refs in the table above to your branch; push.
2. `make flux-install GITOPS_REVISION=<your-branch> GITOPS_REPO_URL=<your-fork>`
   (or `argocd-install`) — this now also covers seeding/bootstrap automatically.
3. Verify the sources track what you expect:
   ```bash
   flux get sources git -A
   ```
   Expect **two** rows: `dep-dlm-testbed` at `<your-branch>@sha1:<tip>`, and
   `rucio-charts-fork` at `master@sha1:<tip>` — the fork should *always* read
   `master` here regardless of which `dep-dlm-testbed` branch you're testing.
   If `rucio-charts-fork` shows anything else, or shows `Ready: False` with
   `couldn't find remote ref`, you've accidentally overridden it — see above.
4. **Before merging: revert every ref in the table back to `main`.** Post-merge, a
   stray `<your-branch>` ref tracks a deleted branch — the ApplicationSet/entrypoint
   sync fails to resolve. (Seeding/bootstrap have no such risk anymore — they only
   ever use whatever `--revision`/`GITOPS_REVISION` you pass at install time.
   The fork refs never need reverting since they're never changed.)
