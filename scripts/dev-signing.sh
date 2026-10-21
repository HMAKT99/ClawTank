#!/usr/bin/env bash
# Stable code-signing identity for local dev builds (ADR-015).
#
# macOS ties Screen Recording / Accessibility grants to an app's code signature. Ad-hoc
# signatures change on every build, so grants would be lost after each rebuild. This creates
# a self-signed "ClawTank Dev" identity in a *separate* keychain with its own random password
# (your login keychain is never touched or unlocked), and signs the app with it.
#
#   scripts/dev-signing.sh setup          # idempotent; creates the keychain + identity
#   scripts/dev-signing.sh sign <app>     # re-signs an .app with the identity
#   scripts/dev-signing.sh remove         # deletes the keychain and local secrets
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
state="$repo/build/dev-signing"
keychain="$HOME/Library/Keychains/clawtank-dev.keychain-db"
name="ClawTank Dev"

password() { cat "$state/keychain-password"; }

identity_hash() {
    security find-identity -p codesigning "$keychain" 2>/dev/null \
        | awk -v n="\"$name\"" '$0 ~ n { print $2; exit }'
}

setup() {
    if [[ -f "$keychain" && -f "$state/keychain-password" && -n "$(identity_hash)" ]]; then
        echo "dev signing identity ready: $name ($(identity_hash))"
        return
    fi
    [[ -f "$keychain" ]] && { echo "error: $keychain exists but is incomplete; run '$0 remove' first" >&2; exit 1; }

    mkdir -p "$state" && chmod 700 "$state"
    umask 077
    openssl rand -hex 24 > "$state/keychain-password"
    security create-keychain -p "$(password)" "$keychain"
    security set-keychain-settings "$keychain"   # no auto-lock timeout
    security unlock-keychain -p "$(password)" "$keychain"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$name" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    # `security` wants a PKCS#1 ("traditional") RSA key; OpenSSL 3 writes PKCS#8 by default.
    openssl rsa -in "$tmp/key.pem" -out "$tmp/key-rsa.pem" -traditional 2>/dev/null
    security import "$tmp/key-rsa.pem" -k "$keychain" -t priv -f openssl -T /usr/bin/codesign >/dev/null
    security import "$tmp/cert.pem" -k "$keychain" -t cert -f openssl >/dev/null
    # Let codesign use the key without a GUI prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(password)" "$keychain" >/dev/null
    cp "$tmp/cert.pem" "$state/ClawTankDev.cer.pem"

    [[ -n "$(identity_hash)" ]] || { echo "error: identity not found after import" >&2; exit 1; }
    echo "created dev signing identity: $name ($(identity_hash)) in $keychain"
}

sign() {
    local app="$1"
    [[ -n "$(identity_hash)" ]] || { echo "error: run '$0 setup' first" >&2; exit 1; }
    security unlock-keychain -p "$(password)" "$keychain"
    # codesign only finds the private key in keychains on the user search list, so add ours
    # for the duration of the signing and then restore the exact previous list.
    local original=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
        [[ -n "$line" ]] && original+=("$line")
    done < <(security list-keychains -d user)
    # shellcheck disable=SC2064
    trap "security list-keychains -d user -s $(printf '%q ' "${original[@]}")" RETURN
    security list-keychains -d user -s "${original[@]}" "$keychain"
    # Nested executables first (the MCP shim), then the app that seals them.
    local helper="$app/Contents/MacOS/clawtank-mcp"
    if [[ -f "$helper" ]]; then
        codesign --force --sign "$(identity_hash)" --keychain "$keychain" \
            --options runtime --timestamp=none "$helper"
    fi
    codesign --force --sign "$(identity_hash)" --keychain "$keychain" \
        --options runtime --timestamp=none "$app"
    codesign --verify --strict "$app"
    echo "signed $app with $name"
}

remove() {
    if [[ -f "$keychain" ]]; then
        security delete-keychain "$keychain"
        echo "deleted $keychain"
    fi
    rm -rf "$state"
}

case "${1:-}" in
    setup) setup ;;
    sign) sign "${2:?usage: $0 sign <path/to/App.app>}" ;;
    remove) remove ;;
    *) echo "usage: $0 setup | sign <app> | remove" >&2; exit 2 ;;
esac
