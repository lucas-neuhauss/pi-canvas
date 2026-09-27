#!/usr/bin/env bash
#
# Builds Ghostty's core (libghostty) into build/ghostty, for the app to link
# against with `import GhosttyKit`.
#
# REQUIREMENTS — please read before changing this script:
#
#   1. The Zig toolchain, version >= the one in Vendor/ghostty/build.zig.zon
#      (`brew install zig`).
#   2. **A working Metal compiler** (`xcrun -sdk macosx metal --version`).
#      Ghostty compiles its Metal shaders offline and embeds the result in the
#      library. That dependency is unconditional for macOS targets — see the
#      `isDarwin()` branch in src/build/SharedDeps.zig — so it applies even with
#      `-Drenderer=opengl`. Command Line Tools alone do NOT provide `metal`; it
#      ships with Xcode. Without Xcode this script cannot succeed, and faking the
#      tool is worse than failing: a stub produces a tiny bogus metallib that
#      links fine and renders nothing.
#   3. `xcodebuild` to package the xcframework. With (2) available, Xcode is
#      present, so this follows.
#
# When libghostty is not built, `scripts/build-app.sh` still builds and runs the
# app using the SwiftTerm backend, so this is safe to skip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GHOSTTY_SRC="$ROOT/Vendor/ghostty"
OUT_DIR="$ROOT/build/ghostty"
XCFRAMEWORK="$GHOSTTY_SRC/macos/GhosttyKit.xcframework"

die() {
	echo "error: $*" >&2
	exit 1
}

[[ -d "$GHOSTTY_SRC" ]] || die "Vendor/ghostty is missing. Run ./scripts/fetch-deps.sh"

# --- Toolchain checks -------------------------------------------------------

if ! command -v zig >/dev/null 2>&1; then
	die "zig is not installed. Install it with: brew install zig"
fi

ZIG_VERSION="$(zig version)"
REQUIRED_ZIG="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY_SRC/build.zig.zon")"
echo "==> zig $ZIG_VERSION (Ghostty requires $REQUIRED_ZIG)"

if ! /usr/bin/xcrun -sdk macosx metal --version >/dev/null 2>&1; then
	cat >&2 <<'MESSAGE'

error: the Metal compiler is not available.

  Ghostty compiles its Metal shaders at build time and embeds them in the
  library. This is required for every macOS build of libghostty, even with
  -Drenderer=opengl, and `metal` ships with Xcode rather than with the
  Command Line Tools alone.

  Install Xcode, then:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    sudo xcodebuild -license accept
    xcodebuild -downloadComponent metalToolchain     # or Xcode > Settings > Components
  and verify with:
    xcrun -sdk macosx metal --version

  The app builds and runs on the SwiftTerm backend in the meantime.
MESSAGE
	exit 1
fi

# --- Build ------------------------------------------------------------------

echo "==> building libghostty (this takes several minutes the first time)"
rm -rf "$XCFRAMEWORK"
# The xcframework packaging step shells out to xcodebuild. With Xcode installed
# that succeeds; if it is the only step that fails, the compiled library is still
# in the Zig cache and we collect it below rather than rebuilding.
BUILD_STATUS=0
(
	cd "$GHOSTTY_SRC"
	zig build \
		-Dapp-runtime=none \
		-Doptimize=ReleaseFast \
		-Demit-xcframework=true \
		-Demit-macos-app=false
) || BUILD_STATUS=$?

# --- Collect the macOS slice ------------------------------------------------

mkdir -p "$OUT_DIR/include"

MACOS_SLICE="$(find "$XCFRAMEWORK" -maxdepth 2 -name "macos-*" -type d 2>/dev/null | head -1)"
if [[ -n "$MACOS_SLICE" && -f "$MACOS_SLICE/libghostty.a" ]]; then
	cp "$MACOS_SLICE/libghostty.a" "$OUT_DIR/libghostty.a"
	cp "$MACOS_SLICE/Headers/ghostty.h" "$OUT_DIR/include/ghostty.h"
else
	# Fall back to the library the build produced before packaging.
	STATIC_LIB="$(find "$GHOSTTY_SRC/.zig-cache" -name "ghostty-internal*.a" -newermt "-2 hours" 2>/dev/null | head -1)"
	if [[ -z "$STATIC_LIB" ]]; then
		echo "error: the build produced no usable library (status $BUILD_STATUS)" >&2
		echo "       see the zig output above" >&2
		exit 1
	fi
	echo "==> using the compiled library from the zig cache"
	cp "$STATIC_LIB" "$OUT_DIR/libghostty.a"
	cp "$GHOSTTY_SRC/include/ghostty.h" "$OUT_DIR/include/ghostty.h"
fi

cat > "$OUT_DIR/module.modulemap" <<'MAP'
module GhosttyKit {
    header "include/ghostty.h"
    link "ghostty"
    export *
}
MAP

echo "==> built libghostty"
ls -la "$OUT_DIR"
echo
echo "Next: make app   (it will detect libghostty and use the Ghostty backend)"
