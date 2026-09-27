#!/usr/bin/env bash
#
# Fetches the vendored third-party sources. They are not committed because they
# are a large upstream project; this pins the exact revision we build against.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/Vendor"
SWIFTTERM_DIR="$VENDOR_DIR/SwiftTerm"
SWIFTTERM_COMMIT="fe4fb45"

mkdir -p "$VENDOR_DIR"

if [[ -d "$SWIFTTERM_DIR/.git" ]]; then
	echo "==> SwiftTerm already present"
	exit 0
fi

echo "==> cloning SwiftTerm"
git clone https://github.com/migueldeicaza/SwiftTerm.git "$SWIFTTERM_DIR"
git -C "$SWIFTTERM_DIR" checkout "$SWIFTTERM_COMMIT"
echo "==> SwiftTerm at $(git -C "$SWIFTTERM_DIR" rev-parse --short HEAD)"
