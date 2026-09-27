#!/usr/bin/env bash
#
# Builds PiCanvas.app with swiftc directly.
#
# Why not SwiftPM? This machine has Command Line Tools without Xcode, and the
# CLT's libPackageDescription.dylib is missing its exported symbols, so every
# `swift build` fails with "Invalid manifest ... Undefined symbols". Driving
# swiftc ourselves is both more robust here and faster for a small app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="PiCanvas"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

CONFIG="${CONFIG:-debug}"
SDK_PATH="$(xcrun --show-sdk-path)"
TARGET="${SWIFT_TARGET:-arm64-apple-macosx14.0}"

SWIFT_FLAGS=(-swift-version 5 -target "$TARGET" -sdk "$SDK_PATH" -g)
if [[ "$CONFIG" == "release" ]]; then
	SWIFT_FLAGS+=(-O)
else
	SWIFT_FLAGS+=(-Onone)
fi

SWIFTTERM_DIR="$BUILD_DIR/swiftterm"
SWIFTTERM_LIB="$SWIFTTERM_DIR/libSwiftTerm.a"
SWIFTTERM_MODULE="$SWIFTTERM_DIR/SwiftTerm.swiftmodule"

if [[ ! -f "$SWIFTTERM_LIB" || ! -f "$SWIFTTERM_MODULE" ]]; then
	echo "==> building SwiftTerm (missing artifacts)"
	"$ROOT/scripts/build-swiftterm.sh"
fi

echo "==> compiling $APP_NAME ($CONFIG)"
mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources"
cp "$ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

SOURCES=()
while IFS= read -r file; do
	SOURCES+=("$file")
done < <(find "$ROOT/Sources/$APP_NAME" -name '*.swift' | sort)

if [[ ${#SOURCES[@]} -eq 0 ]]; then
	echo "error: no Swift sources found" >&2
	exit 1
fi

swiftc \
	"${SWIFT_FLAGS[@]}" \
	-module-name "$APP_NAME" \
	-I "$SWIFTTERM_DIR" \
	-L "$SWIFTTERM_DIR" \
	"${SOURCES[@]}" \
	-lSwiftTerm \
	-o "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
	codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "==> built $APP_DIR"
echo "    binary: $MACOS_DIR/$APP_NAME"
