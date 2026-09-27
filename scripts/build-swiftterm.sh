#!/usr/bin/env bash
#
# build-swiftterm.sh — build the vendored SwiftTerm into a linkable static
# module using raw swiftc/ar, without SwiftPM (which is broken on this
# machine: the CLT libPackageDescription.dylib exports no Package symbols).
#
# Outputs (all under <repo>/build):
#   build/tools/SwiftTermBuildInfoGenerator   generator executable
#   build/generated/SwiftTermBuildInfo.swift  real plugin output
#   build/generated/SwiftTermTerminfo.swift   real plugin output
#   build/swiftterm/SwiftTerm.swiftmodule     module for `-I build/swiftterm`
#   build/swiftterm/SwiftTerm.swiftdoc        (emitted alongside the module)
#   build/swiftterm/SwiftTerm.o               whole-module object
#   build/swiftterm/libSwiftTerm.a            static archive
#   build/swiftterm/.stamp                    input fingerprint for warm skips
#
# Usage:
#   scripts/build-swiftterm.sh [--clean]
#
# --clean removes previous outputs first, then performs a cold build.
# Re-running with unchanged inputs is a no-op.
#
# Environment overrides (optional):
#   SWIFTTERM_TARGET   default arm64-apple-macosx14.0
#   SWIFTTERM_SDK      default `xcrun --show-sdk-path`
#   SWIFTTERM_BUILD_BRANCH / _TAG / _COMMIT / _DIRTY
#                      forwarded to the generator as it is in the build plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VENDOR="$ROOT/Vendor/SwiftTerm"
BUILD="$ROOT/build"
OUT="$BUILD/swiftterm"
GEN="$BUILD/generated"
TOOLS="$BUILD/tools"
GEN_BIN="$TOOLS/SwiftTermBuildInfoGenerator"
STAMP="$OUT/.stamp"

TARGET="${SWIFTTERM_TARGET:-arm64-apple-macosx14.0}"
SWIFT_VERSION="6"
SDK="${SWIFTTERM_SDK:-$(xcrun --show-sdk-path)}"

# The manifest excludes these two paths from the SwiftTerm target on macOS
# (`platformExcludes` is otherwise empty). Shaders.metal cannot compile
# without the Metal toolchain, which is absent here. No .swift file is
# excluded.
MANIFEST_EXCLUDES=(
  "Sources/SwiftTerm/Apple/Metal/Shaders.metal"
  "Sources/SwiftTerm/Mac/README.md"
)

if [[ "${1:-}" == "--clean" ]]; then
  echo "==> --clean: removing $OUT, $GEN, $TOOLS"
  rm -rf "$OUT" "$GEN" "$TOOLS"
fi

mkdir -p "$OUT" "$GEN" "$TOOLS"

# --------------------------------------------------------------------------
# Discover library sources: every .swift under Vendor/SwiftTerm/Sources/SwiftTerm,
# which on macOS is the full set the manifest compiles (Mac/, Apple/, iOS/,
# Portable/ all included).
# --------------------------------------------------------------------------
SWIFT_SOURCES=()
while IFS= read -r file; do
  SWIFT_SOURCES+=("$file")
done < <(find "$VENDOR/Sources/SwiftTerm" -name '*.swift' -type f | sort)

if (( ${#SWIFT_SOURCES[@]} == 0 )); then
  echo "error: no Swift sources found under $VENDOR/Sources/SwiftTerm" >&2
  exit 1
fi

# Assert the manifest's non-Swift excludes are not accidentally in the list.
for excluded in "${MANIFEST_EXCLUDES[@]}"; do
  for file in "${SWIFT_SOURCES[@]}"; do
    if [[ "$file" == "$VENDOR/$excluded" ]] && [[ "$file" == *.swift ]]; then
      echo "error: excluded file would be compiled: $file" >&2
      exit 1
    fi
  done
done

COMMON_FLAGS=(
  -target "$TARGET"
  -sdk "$SDK"
  -swift-version "$SWIFT_VERSION"
  -O
  -whole-module-optimization
  -module-name SwiftTerm
)

# --------------------------------------------------------------------------
# Fingerprint: script + flags + toolchain + every input the outputs depend on.
# Includes generator sources, the vendored source tree (path/size/mtime),
# swifterm-terminfo and Package.swift (plugin input files), and git state
# (the build-info output depends on it).
# --------------------------------------------------------------------------
fingerprint_inputs() {
  echo "target: $TARGET"
  echo "sdk: $SDK"
  echo "swift_version: $SWIFT_VERSION"
  echo "flags: ${COMMON_FLAGS[*]}"
  echo "swiftc: $(swiftc --version 2>&1 | tr '\n' ' ')"
  echo "env: SWIFTTERM_BUILD_BRANCH=${SWIFTTERM_BUILD_BRANCH:-} SWIFTTERM_BUILD_TAG=${SWIFTTERM_BUILD_TAG:-} SWIFTTERM_BUILD_COMMIT=${SWIFTTERM_BUILD_COMMIT:-} SWIFTTERM_BUILD_DIRTY=${SWIFTTERM_BUILD_DIRTY:-}"

  find "$VENDOR/Sources" -type f | sort | while IFS= read -r f; do
    stat -f '%N %z %m' "$f" 2>/dev/null || true
  done
  stat -f '%N %z %m' \
    "$VENDOR/swifterm-terminfo" \
    "$VENDOR/Package.swift" \
    "$ROOT/scripts/build-swiftterm.sh" 2>/dev/null || true

  # The generator never throws on git failure; capture the state it sees.
  git -C "$VENDOR" rev-parse HEAD 2>/dev/null || echo "no-git-head"
  git -C "$VENDOR" status --porcelain 2>/dev/null || echo "no-git-status"
  cat "$VENDOR/.git/HEAD" 2>/dev/null || echo "no-dotgit-head"
}

fingerprint() {
  fingerprint_inputs | shasum -a 256 | awk '{print $1}'
}

outputs_present() {
  [[ -s "$OUT/SwiftTerm.swiftmodule" ]] &&
    [[ -s "$OUT/SwiftTerm.o" ]] &&
    [[ -s "$OUT/libSwiftTerm.a" ]] &&
    [[ -s "$GEN/SwiftTermBuildInfo.swift" ]] &&
    [[ -s "$GEN/SwiftTermTerminfo.swift" ]]
}

START_SECONDS=$SECONDS
CURRENT_FINGERPRINT="$(fingerprint)"

if [[ -s "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$CURRENT_FINGERPRINT" ]] && outputs_present; then
  echo "==> SwiftTerm up to date (stamp $CURRENT_FINGERPRINT)"
  echo "    module:  $OUT/SwiftTerm.swiftmodule"
  echo "    archive: $OUT/libSwiftTerm.a"
  exit 0
fi

echo "==> Building SwiftTerm (target=$TARGET, swift-version=$SWIFT_VERSION)"
echo "    SDK:      $SDK"
echo "    sources:  ${#SWIFT_SOURCES[@]} .swift files (manifest non-Swift excludes: ${MANIFEST_EXCLUDES[*]})"

# 1. Build and run the real generator exactly as the plugin does.
echo "==> Compiling SwiftTermBuildInfoGenerator"
swiftc -O -module-name SwiftTermBuildInfoGenerator \
  -o "$GEN_BIN" \
  "$VENDOR"/Sources/SwiftTermBuildInfoGenerator/*.swift

echo "==> Running generator (repoPath=$VENDOR)"
"$GEN_BIN" \
  "$VENDOR" \
  "$GEN/SwiftTermBuildInfo.swift" \
  "$GEN/SwiftTermTerminfo.swift"

# 2. Compile the whole module to one object and emit the .swiftmodule/.swiftdoc.
echo "==> Compiling SwiftTerm library"
swiftc "${COMMON_FLAGS[@]}" \
  -emit-module \
  -emit-module-path "$OUT/SwiftTerm.swiftmodule" \
  -c -o "$OUT/SwiftTerm.o" \
  "${SWIFT_SOURCES[@]}" \
  "$GEN/SwiftTermBuildInfo.swift" \
  "$GEN/SwiftTermTerminfo.swift"

if [[ ! -f "$OUT/SwiftTerm.swiftdoc" ]]; then
  echo "    note: no .swiftdoc emitted"
fi

# 3. Archive the compiled object(s).
echo "==> Archiving libSwiftTerm.a"
rm -f "$OUT/libSwiftTerm.a"
ar crs "$OUT/libSwiftTerm.a" "$OUT/SwiftTerm.o"

# 4. Record the fingerprint only after every output exists.
printf '%s\n' "$CURRENT_FINGERPRINT" > "$STAMP.tmp"
mv "$STAMP.tmp" "$STAMP"

ELAPSED=$(( SECONDS - START_SECONDS ))
echo "==> Built SwiftTerm in ${ELAPSED}s"
echo "    module:  $OUT/SwiftTerm.swiftmodule ($(stat -f '%z' "$OUT/SwiftTerm.swiftmodule") bytes)"
echo "    archive: $OUT/libSwiftTerm.a ($(stat -f '%z' "$OUT/libSwiftTerm.a") bytes, $(ar t "$OUT/libSwiftTerm.a" | grep -c '\.o$') object file(s))"