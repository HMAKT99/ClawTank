#!/usr/bin/env bash
# Packages clawtank-mcp as an MCP Bundle (.mcpb) for Claude Desktop and the MCP Registry,
# and writes the matching registry entry (server.json) next to it.
#
# Usage: scripts/package-mcpb.sh <version> <path/to/clawtank-mcp> <out.mcpb>
set -euo pipefail

version="$1"
binary="$2"
out="$3"
[[ -x "$binary" ]] || { echo "error: $binary not found or not executable" >&2; exit 1; }
[[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "error: expected an arm64 binary" >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/server"
cp "$binary" "$stage/server/clawtank-mcp"
cp "$root/LICENSE" "$stage/LICENSE"
python3 -I - "$root/packaging/mcpb/manifest.json" "$stage/manifest.json" "$version" <<'EOF'
import json, sys
src, dst, version = sys.argv[1:]
m = json.load(open(src))
m["version"] = version
json.dump(m, open(dst, "w"), indent=2, ensure_ascii=False)
EOF

# Fixed timestamps: the same binary always gives the same bundle (and fileSha256).
find "$stage" -exec touch -h -t 202001010000 {} +
rm -f "$out"
(cd "$stage" && zip -qrX "$out" manifest.json LICENSE server)

# The bundle must start the server and list its tools without the ClawTank app running.
check="$(mktemp -d)"
trap 'rm -rf "$stage" "$check"' EXIT
unzip -q "$out" -d "$check"
tools="$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"package-mcpb","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' |
    CLAWTANK_AGENT_TOKEN=ct_package_check "$check/server/clawtank-mcp" 2>/dev/null |
    python3 -I -c 'import sys, json; print(sum(len(json.loads(l).get("result", {}).get("tools", [])) for l in sys.stdin))')"
[[ "$tools" -gt 0 ]] || { echo "error: the bundled clawtank-mcp listed no tools" >&2; exit 1; }

sha="$(shasum -a 256 "$out" | cut -d' ' -f1)"
python3 -I - "$root/server.json" "$(dirname "$out")/server.json" "$version" "$(basename "$out")" "$sha" <<'EOF'
import json, sys
src, dst, version, name, sha = sys.argv[1:]
s = json.load(open(src))
s["version"] = version
pkg = s["packages"][0]
pkg["identifier"] = f"https://github.com/HMAKT99/ClawTank/releases/download/v{version}/{name}"
pkg["fileSha256"] = sha
json.dump(s, open(dst, "w"), indent=2, ensure_ascii=False)
open(dst, "a").write("\n")
EOF
echo "$out ($tools tools, sha256 $sha)"
