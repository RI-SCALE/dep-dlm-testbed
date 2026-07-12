# Why `tpl` is Required for Values Containing Helm Templates

Some values in `values.yaml` intentionally contain Helm template expressions rather than plain strings. For example:

```yaml
configMap:
  name: '{{ if eq .Values.global.scopeProfile "egi-dev" }}testbed-configs-egi-dev{{ else }}testbed-configs{{ end }}'
```

## Why this doesn't work by default

Helm **does not template `values.yaml`**. During rendering:

1. `values.yaml` is loaded as data.
2. The template expression above is stored as a literal string.
3. If a chart simply emits the value with:

```gotemplate
{{ toYaml .Values.volumes | nindent 8 }}
```

the rendered manifest still contains the literal `{{ if ... }}` text. Kubernetes then looks for a ConfigMap with that exact name, which results in a `FailedMount` error.

## The solution

When a value is expected to contain Helm template expressions, it must be passed through `tpl` before being written to the manifest:

```gotemplate
{{ tpl (toYaml .Values.volumes) $ | nindent 8 }}
```

`tpl` evaluates the embedded template using the current Helm rendering context (`$`), producing the final string before the manifest is emitted.

In the example above, the rendered manifest contains either:

```yaml
configMap:
  name: testbed-configs
```

or

```yaml
configMap:
  name: testbed-configs-egi-dev
```

depending on the value of `.Values.global.scopeProfile`.

## Guideline

Any chart value that is intentionally allowed to contain Helm template expressions must be rendered with `tpl`; otherwise, those expressions are treated as plain text and are never evaluated.
