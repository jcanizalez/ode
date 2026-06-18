#!/bin/sh
# Fetch ODE's binary dependencies: the sherpa-onnx static libraries (which embed
# the DPDFNet inference runtime + ONNX Runtime) and the DPDFNet model weights.
# These are not committed to git because of their size; this script reproduces
# exactly what ODE links and bundles.

set -e
cd "$(dirname "$0")/.."

SHERPA_VER="v1.13.3"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64) LIB_ASSET="sherpa-onnx-${SHERPA_VER}-osx-arm64-static-lib.tar.bz2" ;;
    x86_64) LIB_ASSET="sherpa-onnx-${SHERPA_VER}-osx-x64-static-lib.tar.bz2" ;;
    *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download"
LIBDIR="third_party/sherpa/lib"
INCDIR="third_party/sherpa/include"
MODEL_URL="${BASE}/speech-enhancement-models/dpdfnet2_48khz_hr.onnx"

mkdir -p "$LIBDIR" "$INCDIR" Resources

# --- Static libraries ---
if [ -f "$LIBDIR/libsherpa-onnx-c-api.a" ]; then
    echo "✓ sherpa-onnx static libs already present."
else
    echo "Downloading sherpa-onnx static libs ($ARCH)…"
    tmp="$(mktemp -d)"
    curl -fL --progress-bar -o "$tmp/lib.tar.bz2" "$BASE/$SHERPA_VER/$LIB_ASSET"
    tar xjf "$tmp/lib.tar.bz2" -C "$tmp"
    cp "$tmp"/*/lib/*.a "$LIBDIR/"
    rm -rf "$tmp"
    echo "✓ Installed $(ls "$LIBDIR" | wc -l | tr -d ' ') static libraries."
fi

# --- C API header ---
if [ ! -f "$INCDIR/c-api.h" ]; then
    echo "Downloading sherpa-onnx C API header…"
    tmp="$(mktemp -d)"
    XCF="sherpa-onnx-${SHERPA_VER}-macos-xcframework-static.tar.bz2"
    curl -fL --progress-bar -o "$tmp/xcf.tar.bz2" "$BASE/$SHERPA_VER/$XCF"
    tar xjf "$tmp/xcf.tar.bz2" -C "$tmp"
    H="$(find "$tmp" -name c-api.h | head -1)"
    cp "$H" "$INCDIR/c-api.h"
    cp "$H" "Sources/CSherpa/include/c-api.h"
    rm -rf "$tmp"
    echo "✓ Installed C API header."
fi

# --- DPDFNet model ---
if [ -f "Resources/dpdfnet2_48khz_hr.onnx" ]; then
    echo "✓ DPDFNet model already present."
else
    echo "Downloading DPDFNet model…"
    curl -fL --progress-bar -o "Resources/dpdfnet2_48khz_hr.onnx" "$MODEL_URL"
    echo "✓ Installed DPDFNet model."
fi

echo
echo "All dependencies ready. Build with:  swift build -c release"
