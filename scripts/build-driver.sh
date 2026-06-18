#!/bin/sh
# Build the branded "ODE Microphone" virtual-audio driver.
#
# This compiles BlackHole (MIT) from source with ODE branding, producing
# dist/ODEMicrophone.driver — a CoreAudio loopback device named "ODE
# Microphone". Requires the full Xcode (not just Command Line Tools).
#
# The driver is the input half of ODE's virtual microphone: the ODE engine
# writes denoised audio to its output, conferencing apps read its input.

set -e
cd "$(dirname "$0")/.."

DIST="dist"
DRIVER_OUT="$DIST/ODEMicrophone.driver"
BUNDLE_ID="audio.ode.ODEMicrophone"
SRC_DIR="$(mktemp -d)/BlackHole"
BUILD_DIR="$(mktemp -d)/driver_build"

# --- Locate a full Xcode ---
XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
if [ -z "$XCODE" ]; then
    echo "Full Xcode is required to build the driver but was not found in /Applications." >&2
    echo "Install Xcode, or install BlackHole via scripts/install-virtual-mic.sh instead." >&2
    exit 1
fi
export DEVELOPER_DIR="$XCODE/Contents/Developer"

echo "Fetching BlackHole source…"
git clone --depth 1 https://github.com/ExistentialAudio/BlackHole.git "$SRC_DIR" >/dev/null 2>&1

# Set the device name to "ODE Microphone" directly in source. (It can't be
# passed via GCC_PREPROCESSOR_DEFINITIONS because the value contains a space.)
SRCFILE="$SRC_DIR/BlackHole/BlackHole.c"
/usr/bin/sed -i '' \
    -e 's/kDevice_Name                        kDriver_Name " %ich"/kDevice_Name                        "ODE Microphone"/' \
    -e 's/kDevice2_Name                       kDriver_Name " %ich 2"/kDevice2_Name                       "ODE Speaker"/' \
    "$SRCFILE"

echo "Compiling ODE virtual-audio driver (this may take a minute)…"
mkdir -p "$BUILD_DIR"
xcodebuild \
    -project "$SRC_DIR/BlackHole.xcodeproj" \
    -configuration Release \
    -target BlackHole \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    MACOSX_DEPLOYMENT_TARGET=11.0 \
    CODE_SIGN_IDENTITY="-" \
    GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
    kDriver_Name=\"ODE\"
    kPlugIn_BundleID=\"'$BUNDLE_ID'\"
    kDevice2_IsHidden=false
    kNumber_Of_Channels=2' \
    >/dev/null

mkdir -p "$DIST"
rm -rf "$DRIVER_OUT"
cp -R "$BUILD_DIR/BlackHole.driver" "$DRIVER_OUT"

# Re-sign the renamed bundle (ad-hoc by default; override with ODE_DRIVER_IDENTITY).
IDENTITY="${ODE_DRIVER_IDENTITY:--}"
codesign --force --deep --sign "$IDENTITY" "$DRIVER_OUT"

rm -rf "$SRC_DIR" "$BUILD_DIR"
echo "✓ Built $DRIVER_OUT  (device name: \"ODE Microphone\")"
