# Vendored: opa-ri-scale ODRL evaluator

| | |
|---|---|
| Source | https://github.com/mgajek-cern/opa-ri-scale (fork of RI-SCALE/opa-ri-scale) |
| Ref | `vendor-2026-10-05` |
| Commit | `d2b30f0560463628dfb164dcac49c12ec5217d97` |
| Path | `OPA/src/dep` → `dep/` |
| Excluded | `data.yaml`/`demo.yaml` (demo policies), `OPA/src/system` (OPA API auth) |
| Local changes | none — fixes go upstream (RI-SCALE/opa-ri-scale#3), then re-vendor |

Update with `make vendor-opa-ri-scale OPA_RI_SCALE_REF=<tag>`; don't edit
files here by hand (pre-commit and `fmt-rego` skip this directory).
Switch `OPA_RI_SCALE_REPO` to upstream once #3 is merged there.