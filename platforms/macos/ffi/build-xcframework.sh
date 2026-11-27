#!/usr/bin/env bash
set -euo pipefail

# Builds the Rust `aeron-ffi` UniFFI static library + Swift bindings + XCFramework
# so the native macOS SwiftUI app (`AeronTools.xcodeproj`) shares the exact same
# `AeronCore` engine as the Windows & Linux/SteamOS Tauri app.
#
# Usage:
#   ./platforms/macos/ffi/build-xcframework.sh              # host arch, release (fast local dev)
#   ./platforms/macos/ffi/build-xcframework.sh --universal  # arm64 + x86_64 universal (CI / releases)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Match AeronTools.xcodeproj MACOSX_DEPLOYMENT_TARGET so Rust & C objects (e.g. hidapi)
# link cleanly without macOS deployment target mismatch warnings.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

UNIVERSAL=false
PROFILE="release"

for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=true ;;
    --debug) PROFILE="debug" ;;
    --release) PROFILE="release" ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--universal] [--debug|--release]" >&2
      exit 1
      ;;
  esac
done

CARGO_PROFILE_FLAG=()
if [[ "$PROFILE" == "release" ]]; then
  CARGO_PROFILE_FLAG=(--release)
fi

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "arm64" ]]; then
  HOST_TARGET="aarch64-apple-darwin"
else
  HOST_TARGET="x86_64-apple-darwin"
fi

BUILD_DIR="${SCRIPT_DIR}/build/macos"
INCLUDE_DIR="${BUILD_DIR}/include"
BINDGEN_OUT="${BUILD_DIR}/bindgen"
XCFRAMEWORK_OUT="${SCRIPT_DIR}/AeronCoreFFI.xcframework"
SPM_SOURCES_DIR="${SCRIPT_DIR}/AeronCoreKit/Sources/AeronCoreKit"
XCODE_GENERATED_DIR="${REPO_ROOT}/platforms/macos/app/Generated"

rm -rf "${BUILD_DIR}" "${XCFRAMEWORK_OUT}"
mkdir -p "${INCLUDE_DIR}" "${BINDGEN_OUT}" "${SPM_SOURCES_DIR}" "${XCODE_GENERATED_DIR}"

pushd "${REPO_ROOT}" >/dev/null

if [[ "$UNIVERSAL" == true ]]; then
  echo "==> Building aeron-ffi (universal: aarch64-apple-darwin + x86_64-apple-darwin, ${PROFILE}, macOS ${MACOSX_DEPLOYMENT_TARGET})..."
  cargo build -p aeron-ffi --lib ${CARGO_PROFILE_FLAG+"${CARGO_PROFILE_FLAG[@]}"} --target aarch64-apple-darwin
  cargo build -p aeron-ffi --lib ${CARGO_PROFILE_FLAG+"${CARGO_PROFILE_FLAG[@]}"} --target x86_64-apple-darwin

  ARM_LIB="${REPO_ROOT}/target/aarch64-apple-darwin/${PROFILE}/libaeron_ffi.a"
  X86_LIB="${REPO_ROOT}/target/x86_64-apple-darwin/${PROFILE}/libaeron_ffi.a"
  lipo -create "${ARM_LIB}" "${X86_LIB}" -output "${BUILD_DIR}/libaeron_ffi.a"
  BINDGEN_LIB="${REPO_ROOT}/target/${HOST_TARGET}/${PROFILE}/libaeron_ffi.a"
else
  echo "==> Building aeron-ffi (${HOST_TARGET}, ${PROFILE}, macOS ${MACOSX_DEPLOYMENT_TARGET})..."
  cargo build -p aeron-ffi --lib ${CARGO_PROFILE_FLAG+"${CARGO_PROFILE_FLAG[@]}"} --target "${HOST_TARGET}"
  BINDGEN_LIB="${REPO_ROOT}/target/${HOST_TARGET}/${PROFILE}/libaeron_ffi.a"
  cp "${BINDGEN_LIB}" "${BUILD_DIR}/libaeron_ffi.a"
fi

echo "==> Generating Swift bindings via uniffi-bindgen..."
cargo run -p aeron-ffi --bin uniffi-bindgen -- \
  generate \
  --library "${BINDGEN_LIB}" \
  --language swift \
  --out-dir "${BINDGEN_OUT}"

# Opt generated UniFFI declarations out of Swift 6.2 default MainActor isolation
# so FFI calls run safely off the main thread without actor-isolation warnings.
python3 - "${BINDGEN_OUT}/aeron_ffi.swift" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

decl_re = re.compile(
    r"^(?:(?:public|open|private|fileprivate|internal)\s+)?(?:final\s+)?(?:struct|enum|class|protocol|extension|func|let)\b"
)

depth = 0
out = []
for line in lines:
    if depth == 0:
        if line.startswith("private var initializationResult:"):
            line = line.replace(
                "private var initializationResult:",
                "nonisolated private let initializationResult:",
                1,
            )
        elif not line.startswith("nonisolated ") and decl_re.match(line):
            line = "nonisolated " + line

    # Strip line comments and quoted strings for accurate brace depth tracking.
    code = re.sub(r"//.*", "", line)
    code = re.sub(r'"(?:\\.|[^"\\])*"', "", code)
    depth += code.count("{") - code.count("}")
    if depth < 0:
        depth = 0
    out.append(line)

with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
PY

cp "${BINDGEN_OUT}/aeron_ffiFFI.h" "${INCLUDE_DIR}/aeron_ffiFFI.h"
cp "${BINDGEN_OUT}/aeron_ffiFFI.modulemap" "${INCLUDE_DIR}/module.modulemap"

cp "${BINDGEN_OUT}/aeron_ffi.swift" "${SPM_SOURCES_DIR}/aeron_ffi.swift"
cp "${BINDGEN_OUT}/aeron_ffi.swift" "${XCODE_GENERATED_DIR}/AeronCoreFFI.swift"

echo "==> Packaging AeronCoreFFI.xcframework..."
xcodebuild -create-xcframework \
  -library "${BUILD_DIR}/libaeron_ffi.a" \
  -headers "${INCLUDE_DIR}" \
  -output "${XCFRAMEWORK_OUT}"

popd >/dev/null

echo "==> Done!"
echo "    Static lib:   ${BUILD_DIR}/libaeron_ffi.a"
echo "    XCFramework:  ${XCFRAMEWORK_OUT}"
echo "    Swift source: ${XCODE_GENERATED_DIR}/AeronCoreFFI.swift"
