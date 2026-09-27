#!/usr/bin/env bash
#
# Captures a PNG of just the PiCanvas window (not the whole desktop).
#
#   scripts/window-shot.sh [output.png] [app-name]
#
# Requires Screen Recording permission for the process that runs this.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-/tmp/picanvas-shot.png}"
APP_NAME="${2:-PiCanvas}"
HELPER="$ROOT/build/windowid"

if [[ ! -x "$HELPER" ]]; then
	echo "==> building windowid helper"
	mkdir -p "$ROOT/build"
	swiftc -O -o "$HELPER" "$ROOT/scripts/tools/windowid.swift"
fi

WINDOW_ID="$("$HELPER" "$APP_NAME" || true)"
if [[ -z "$WINDOW_ID" ]]; then
	echo "error: no on-screen window found for '$APP_NAME'" >&2
	exit 1
fi

screencapture -x -o -l "$WINDOW_ID" "$OUTPUT"
echo "$OUTPUT"
