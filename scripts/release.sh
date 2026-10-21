#!/usr/bin/env bash
# Builds release artifacts from an already-built ClawTank.app:
#   dist/ClawTank-<version>-<arch>.dmg, dist/SHA256SUMS, dist/RELEASE_NOTES.md
# and verifies them (DMG integrity, signature, architecture, versions).
#
# Signing: ad-hoc by default. With CLAWTANK_SIGN_IDENTITY="Developer ID Application: …" it signs
# with Developer ID and, if CLAWTANK_NOTARY_PROFILE names a `notarytool store-credentials`
# profile, notarizes and staples. UNTESTED: the maintainer has no Developer ID yet (ADR-024).
#
# Usage: scripts/release.sh <version> <path/to/ClawTank.app>
set -euo pipefail

version="$1"
app="$2"
[[ -d "$app" ]] || { echo "error: $app not found" >&2; exit 1; }
cd "$(dirname "$0")/.."

plist="$app/Contents/Info.plist"
app_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version $app_version != core version $version (app/project.yml vs core/Cargo.toml)" >&2
    exit 1
}
grep -q "^## \[$version\]" CHANGELOG.md || { echo "error: CHANGELOG.md has no [$version] section" >&2; exit 1; }

arch="$(lipo -archs "$app/Contents/MacOS/ClawTank" | tr ' ' '+')"
dmg="dist/ClawTank-$version-${arch/x86_64+arm64/universal}.dmg"
rm -rf dist && mkdir -p dist

if [[ -n "${CLAWTANK_SIGN_IDENTITY:-}" ]]; then
    echo "Signing with $CLAWTANK_SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$CLAWTANK_SIGN_IDENTITY" \
        "$app/Contents/MacOS/clawtank-mcp"
    codesign --force --options runtime --timestamp --sign "$CLAWTANK_SIGN_IDENTITY" "$app"
fi
codesign --verify --deep --strict "$app"

scripts/package-dmg.sh "$app" "$dmg" >/dev/null
rm -f "$dmg.sha256"

if [[ -n "${CLAWTANK_SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$CLAWTANK_SIGN_IDENTITY" "$dmg"
    if [[ -n "${CLAWTANK_NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$dmg" --keychain-profile "$CLAWTANK_NOTARY_PROFILE" --wait
        xcrun stapler staple "$dmg"
    fi
fi

# Verify what users will download: integrity, contents, signature, architecture.
hdiutil verify -quiet "$dmg"
mount="$(mktemp -d)"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg"
trap 'hdiutil detach -quiet "$mount" || true; rmdir "$mount" 2>/dev/null || true' EXIT
[[ -d "$mount/ClawTank.app" && -L "$mount/Applications" ]] || { echo "error: DMG layout wrong" >&2; exit 1; }
codesign --verify --deep --strict "$mount/ClawTank.app"
[[ -x "$mount/ClawTank.app/Contents/MacOS/clawtank-mcp" ]] || { echo "error: clawtank-mcp missing" >&2; exit 1; }
signature="$(codesign -dv "$mount/ClawTank.app" 2>&1 | sed -n 's/^Signature=//p')"
hdiutil detach -quiet "$mount"
trap - EXIT
rmdir "$mount"

(cd dist && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS)

# Release notes: this version's CHANGELOG section plus install instructions.
{
    echo "# ClawTank $version"
    echo
    # The summary above the per-phase "###" details; the full list stays in CHANGELOG.md.
    awk -v v="$version" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^##/ {exit} on' CHANGELOG.md
    echo "Full list of changes: [CHANGELOG.md](https://github.com/HMAKT99/ClawTank/blob/v$version/CHANGELOG.md)."
    echo
    echo "## Install"
    echo
    echo "1. Download \`$(basename "$dmg")\`, open it and drag ClawTank to Applications."
    if [[ "${signature:-adhoc}" == "adhoc" ]]; then
        echo "2. This build is not notarized. The first time you open it, macOS blocks it. Go to"
        echo "   **System Settings → Privacy & Security**, click **Open Anyway** next to the ClawTank message,"
        echo "   then confirm. See the README's \"Install\" section for details."
    else
        echo "2. Open ClawTank from Applications."
    fi
    echo "3. Follow the setup window: Screen Recording, Accessibility and a password, then connect from any RDP client."
    echo
    echo "Requires macOS 14 Sonoma or later on $( [[ "$arch" == arm64 ]] && echo "Apple silicon" || echo "$arch" )."
    echo
    echo "SHA-256: \`$(cut -d' ' -f1 dist/SHA256SUMS)\`"
} > dist/RELEASE_NOTES.md

echo "Release $version ($arch, signature: ${signature:-adhoc}):"
ls -l dist
cat dist/SHA256SUMS
