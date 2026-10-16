#!/usr/bin/env bash
# Generate unified diffs of locally patched files against a pinned upstream ref.
#
# Usage: make-patches.sh <name> <git-url> <ref> <manifest> <out-dir>
#
# Manifest: one "<local file> <upstream path>" pair per line; '#' comments
# and blank lines are ignored. Upstream paths are relative to the repo root.
set -euo pipefail

name=$1 url=$2 ref=$3 manifest=$4 out=$5
up=".upstream/$name"
ref_file=".upstream/$name.ref"

[ -f "$manifest" ] || { echo "$name: manifest '$manifest' not found" >&2; exit 1; }

# (Re-)clone when missing or when the pinned ref changed.
if [ ! -d "$up" ] || [ "$(cat "$ref_file" 2>/dev/null)" != "$ref" ]; then
  rm -rf "$up"
  mkdir -p .upstream
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" "$url" "$up"
  echo "$ref" > "$ref_file"
fi

rm -rf "$out" && mkdir -p "$out"

n=0
while read -r local upstream _ || [ -n "${local:-}" ]; do
  [[ -z "${local:-}" || "$local" == \#* ]] && continue
  [ -n "${upstream:-}" ] || { echo "$name: no upstream path for '$local'" >&2; exit 1; }
  [ -f "$local" ]       || { echo "$name: local file '$local' missing" >&2; exit 1; }

  orig="$up/$upstream" a_label="a/$upstream"
  if [ ! -f "$orig" ]; then
    echo "$name: warning: '$upstream' not in $ref, treating as new file" >&2
    orig=/dev/null a_label=/dev/null
  fi

  patch="$out/${upstream//\//__}.patch"
  rc=0
  diff -u --label "$a_label" --label "b/$upstream" "$orig" "$local" > "$patch" || rc=$?
  [ "$rc" -le 1 ] || { echo "$name: diff failed for '$local'" >&2; exit "$rc"; }

  if [ -s "$patch" ]; then n=$((n + 1)); else rm -f "$patch"; fi
done < "$manifest"

echo "$name: $n patch(es) vs $ref"
