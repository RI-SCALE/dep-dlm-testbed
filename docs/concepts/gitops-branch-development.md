# Developing GitOps on a child branch

The sandbox GitOps path clones and reconciles from a **branch ref baked into
several manifests**. On `main` these all say `main`. To test a child branch,
you must point them at your branch, then revert before merge.

## Refs to change (main → <your-branch>)

| File | Field |
|------|-------|
| `deploy/gitops/flux/flux-system/gitrepository.yaml` | `spec.ref.branch` |
| `deploy/gitops/argocd/applicationsets/{sandbox,staging,production}.yaml` | every `targetRevision` and `ref: values` source |
| `deploy/gitops/argocd/entrypoints/app-of-apps-{sandbox,staging,production}.yaml` | `source.targetRevision` (apps + secrets) |

**No longer a row here:** `environments/sandbox/secrets/seed-job.yaml` — that
file is gone. Vault seeding and the DB-bootstrap Job are now imperative scripts
(`shared/scripts/seed-vault.sh`, `shared/scripts/run-bootstrap-db.sh`), and
`init-argocd.sh`/`init-flux.sh` pass `--repo-url`/`--revision` straight through
to them. Pointing `make argocd-install`/`make flux-install` at your branch via
`GITOPS_REPO_URL`/`GITOPS_REVISION` is now sufficient for those two steps —
nothing to hand-edit.

Quick sweep to find any you missed:
```bash
grep -rn "targetRevision:\|branch:" deploy/gitops | grep -v "40.0.0\|0.10.7\|0.28.1\|18.3.0"
```

## Why

`init-argocd.sh --revision` / `init-flux.sh --revision` override:
- the app-of-apps root's own source (Argo) / the `GitRepository` ref (Flux) — always
- `seed-vault.sh` and `run-bootstrap-db.sh`'s clone/apply revision — always; these are script flags now, not committed refs

They do **not** override:
- the inner ApplicationSet's per-component `targetRevision`/`ref: values` (Argo) —
  those are read straight from whatever's committed in
  `argocd/applicationsets/<env>.yaml`, regardless of what you pass on the CLI

So the remaining manual-edit surface is smaller than it used to be — just the
ApplicationSet/entrypoint refs, not the seed/bootstrap path anymore.

## Workflow
1. Flip the refs in the table above to your branch; push.
2. `make flux-install GITOPS_REVISION=<your-branch> GITOPS_REPO_URL=<your-fork>`
   (or `argocd-install`) — this now also covers seeding/bootstrap automatically.
3. Verify the source tracks your branch, not main:
   ```bash
   flux get sources git -A          # expect <your-branch>@sha1:<tip>
   ```
4. **Before merging: revert every ref in the table back to `main`.** Post-merge, a
   stray `<your-branch>` ref tracks a deleted branch — the ApplicationSet/entrypoint
   sync fails to resolve. (Seeding/bootstrap have no such risk anymore — they only
   ever use whatever `--revision`/`GITOPS_REVISION` you pass at install time.)
