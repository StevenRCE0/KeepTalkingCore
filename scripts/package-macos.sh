#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="${KT_BUILD_CONFIG:-release}"
SIGN_IDENTITY="${KT_SIGN_IDENTITY:--}"
SWIFT_BIN="${SWIFT_BIN:-swift}"
OUTPUT_DIR="${1:-$PROJECT_ROOT/dist/KeepTalking-macos}"
CACHE_ROOT="${KT_CACHE_ROOT:-$PROJECT_ROOT/.build/package-cache}"
SKIP_BUILD="${KT_SKIP_BUILD:-0}"
BIN_DIR="${KT_BIN_DIR:-}"

mkdir -p "$CACHE_ROOT/cache" "$CACHE_ROOT/config" "$CACHE_ROOT/security" "$CACHE_ROOT/scratch"
export XDG_CACHE_HOME="$CACHE_ROOT/cache"
export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/cache/clang/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

SWIFT_COMMON_ARGS=(
  --cache-path "$CACHE_ROOT/cache"
  --config-path "$CACHE_ROOT/config"
  --security-path "$CACHE_ROOT/security"
  --scratch-path "$CACHE_ROOT/scratch"
)

cd "$PROJECT_ROOT"
if [[ "$SKIP_BUILD" == "1" ]]; then
  if [[ -z "$BIN_DIR" ]]; then
    BIN_DIR="$PROJECT_ROOT/.build/arm64-apple-macosx/$CONFIG"
  fi
  echo "Skipping build; using artifacts from $BIN_DIR"
else
  echo "Building KeepTalking ($CONFIG)..."
  "$SWIFT_BIN" build "${SWIFT_COMMON_ARGS[@]}" -c "$CONFIG"
  BIN_DIR="$("$SWIFT_BIN" build "${SWIFT_COMMON_ARGS[@]}" -c "$CONFIG" --show-bin-path)"
fi
BIN_SRC="$BIN_DIR/KeepTalking"
FW_SRC="$BIN_DIR/LiveKitWebRTC.framework"

if [[ ! -x "$BIN_SRC" ]]; then
  echo "error: expected executable not found at $BIN_SRC" >&2
  exit 1
fi

if [[ ! -d "$FW_SRC" ]]; then
  echo "error: expected framework not found at $FW_SRC" >&2
  exit 1
fi

echo "Creating distribution at $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/LiveKitWebRTC.framework"
cp "$BIN_SRC" "$OUTPUT_DIR/KeepTalking"
cp -R "$FW_SRC" "$OUTPUT_DIR/"

echo "Code-signing artifacts with identity: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$OUTPUT_DIR/LiveKitWebRTC.framework"
  codesign --force --sign - "$OUTPUT_DIR/KeepTalking"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime "$OUTPUT_DIR/LiveKitWebRTC.framework"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime "$OUTPUT_DIR/KeepTalking"
fi

echo "Verifying signatures..."
codesign --verify --verbose=2 "$OUTPUT_DIR/LiveKitWebRTC.framework"
codesign --verify --verbose=2 "$OUTPUT_DIR/KeepTalking"

echo "Smoke-test launch..."
"$OUTPUT_DIR/KeepTalking" --help >/dev/null || true

echo
echo "Done. Distribution folder:"
echo "  $OUTPUT_DIR"
echo
echo "Run with:"
echo "  $OUTPUT_DIR/KeepTalking --signal-url ws://127.0.0.1:17000/ws --context 11111111-2222-3333-4444-555555555555 --id alice"
