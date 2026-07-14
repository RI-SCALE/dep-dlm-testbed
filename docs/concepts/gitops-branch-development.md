# Developing GitOps on a child branch

The sandbox GitOps path clones and reconciles from a **branch ref baked into
several manifests**. On `main` these all say `main`. To test a child branch,
you must point them at your branch, then revert before merge.

## Refs to change (main → <your-branch>)

| File | Field |
|------|-------|
| `deploy/gitops/flux/flux-system/gitrepository.yaml` | `spec.ref.branch` |
| `deploy/gitops/environments/sandbox/secrets/seed-job.yaml` | clone `--branch=` |
| `deploy/gitops/argocd/applicationsets/{sandbox,staging,production}.yaml` | every `targetRevision` and `ref: values` source |
| `deploy/gitops/argocd/entrypoints/app-of-apps-{sandbox,staging,production}.yaml` | `source.targetRevision` (apps + secrets) |

Quick sweep to find any you missed:
```bash
grep -rn "targetRevision:\|--branch=\|branch:" deploy/gitops | grep -v "40.0.0\|0.10.7\|0.28.1\|18.3.0"
```

## Why
`init-argocd.sh --revision` only overrides the app-of-apps ROOT, not the inner
ApplicationSet `targetRevision`/`ref: values` or the seed-job clone. Those are
read straight from Git, so they must already point at the branch you're testing.

## Workflow
1. Flip all refs above to your branch; push.
2. `make flux-install` (or `argocd-install`).
3. Verify the source tracks your branch, not main:
   ```bash
   flux get sources git -A          # expect <your-branch>@sha1:<tip>
   ```
4. **Before merging: revert every ref back to `main`.** Post-merge, a stray
   `<your-branch>` ref tracks a deleted branch — the seed clone fails and
   ApplicationSets sync nothing.
