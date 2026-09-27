#!/usr/bin/env bash
#
# Fetches the vendored third-party sources. They are not committed because they
# are a large upstream project; this pins the exact revision we build against.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/Vendor"
SWIFTTERM_DIR="$VENDOR_DIR/SwiftTerm"
SWIFTTERM_COMMIT="fe4fb45"
GHOSTTY_DIR="$VENDOR_DIR/ghostty"
GHOSTTY_COMMIT="b40acce"

mkdir -p "$VENDOR_DIR"

if [[ -d "$SWIFTTERM_DIR/.git" ]]; then
	echo "==> SwiftTerm already present"
else
	echo "==> cloning SwiftTerm"
	git clone https://github.com/migueldeicaza/SwiftTerm.git "$SWIFTTERM_DIR"
	git -C "$SWIFTTERM_DIR" checkout "$SWIFTTERM_COMMIT"
fi
echo "    SwiftTerm at $(git -C "$SWIFTTERM_DIR" rev-parse --short HEAD)"

if [[ -d "$GHOSTTY_DIR/.git" ]]; then
	echo "==> Ghostty already present"
else
	echo "==> cloning Ghostty (large; this fetches the terminal core we embed)"
	git clone --depth 1 https://github.com/ghostty-org/ghostty.git "$GHOSTTY_DIR"
fi
echo "    Ghostty at $(git -C "$GHOSTTY_DIR" rev-parse --short HEAD)"

echo ""
echo "Next: make ghostty   (needs the Zig toolchain: brew install zig)"
