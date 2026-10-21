#!/usr/bin/env bash
# Packages a built ClawTank.app into a compressed DMG with an /Applications shortcut.
# Usage: scripts/package-dmg.sh <path/to/ClawTank.app> <output.dmg>
set -euo pipefail

app="$1"
out="$2"
[[ -d "$app" ]] || { echo "error: $app not found (run make build)" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil create -quiet -volname "ClawTank" -srcfolder "$staging" -fs HFS+ -format UDZO "$out"
shasum -a 256 "$out" | tee "$out.sha256"
