#!/bin/bash
set -euo pipefail

if [[ "$#" != 2 ]]; then
    printf 'Usage: scripts/make-dmg.sh <app> <output.dmg>\n' >&2
    exit 2
fi
app_path="$1"
output="$2"
[[ -d "$app_path" ]] || { printf 'App not found: %s\n' "$app_path" >&2; exit 1; }

stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/inlay-dmg.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app_path" "$stage_dir/$(basename "$app_path")"
ln -s /Applications "$stage_dir/Applications"
mkdir -p "$(dirname "$output")"
rm -f "$output"
hdiutil create -volname "Inlay" -srcfolder "$stage_dir" -format UDZO -o "$output" >/dev/null
printf '%s\n' "$output"
