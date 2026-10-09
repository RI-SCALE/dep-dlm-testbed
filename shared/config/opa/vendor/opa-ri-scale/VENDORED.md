# Vendored: opa-ri-scale ODRL evaluator

| | |
|---|---|
| Source | https://github.com/mgajek-cern/opa-ri-scale (fork of RI-SCALE/opa-ri-scale) |
| Ref | `vendor-2026-10-08` |
| Commit | `47909c2585cc72c3bf6c679224078f446cdfd4e2` |
| Path | `OPA/src/dep` → `dep/` |
| Excluded | `data.yaml`/`demo.yaml` (demo policies), `OPA/src/system` (OPA API auth) |
| Local changes | none |

Update with `make vendor-opa-ri-scale OPA_RI_SCALE_REF=<tag>`; don't edit
files here by hand (pre-commit and `fmt-rego` skip this directory).
Switch `OPA_RI_SCALE_REPO` to upstream once #3 is merged there.