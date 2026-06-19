#!/bin/sh
# Build ODE's two virtual-audio drivers from BlackHole (MIT) source.
#
# Each driver is its own CoreAudio plugin (own buffer → no cross-contamination),
# and uses BlackHole's input-only/output-only + hidden mirror-device feature so
# each shows up in only the RIGHT list:
#
#   ODEMicrophone.driver
#     • "ODE Microphone"  input-only, visible   (apps pick it as their mic)
#     • "ODE Mic Feed"    output-only, hidden    (ODE writes denoised voice here)
#   ODESpeaker.driver
#     • "ODE Speaker"     output-only, visible   (apps pick it as their speaker)
#     • "ODE Spk Tap"     input-only, hidden     (ODE reads incoming audio here)
#
# The visible + hidden device in each driver share one buffer, so audio routes
# between them behind the scenes. Requires full Xcode.

set -e
cd "$(dirname "$0")/.."

DIST="dist"
SRC_ROOT="$(mktemp -d)"

XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
if [ -z "$XCODE" ]; then
    echo "Full Xcode is required to build the drivers but was not found in /Applications." >&2
    exit 1
fi
export DEVELOPER_DIR="$XCODE/Contents/Developer"
mkdir -p "$DIST"

# build_driver <out> <bundleid> <drivername> <visibleName> <hiddenName> \
#              <dev1In> <dev1Out> <dev2In> <dev2Out>
build_driver() {
    out="$1"; bundle="$2"; drv="$3"; vis="$4"; hid="$5"
    d1in="$6"; d1out="$7"; d2in="$8"; d2out="$9"
    src="$SRC_ROOT/$out"; build="$(mktemp -d)"

    echo "Fetching BlackHole source for $vis…"
    git clone --depth 1 https://github.com/ExistentialAudio/BlackHole.git "$src" >/dev/null 2>&1

    # Device display names contain spaces, so set them directly in source.
    /usr/bin/sed -i '' \
        -e "s/kDevice_Name                        kDriver_Name \" %ich\"/kDevice_Name                        \"$vis\"/" \
        -e "s/kDevice2_Name                       kDriver_Name \" %ich 2\"/kDevice2_Name                       \"$hid\"/" \
        "$src/BlackHole/BlackHole.c"

    echo "Compiling $vis driver…"
    xcodebuild \
        -project "$src/BlackHole.xcodeproj" -configuration Release -target BlackHole \
        CONFIGURATION_BUILD_DIR="$build" \
        PRODUCT_BUNDLE_IDENTIFIER="$bundle" \
        MACOSX_DEPLOYMENT_TARGET=11.0 CODE_SIGN_IDENTITY="-" \
        GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
        kDriver_Name=\"'"$drv"'\"
        kPlugIn_BundleID=\"'"$bundle"'\"
        kNumber_Of_Channels=2
        kDevice_IsHidden=false
        kDevice_HasInput='"$d1in"'
        kDevice_HasOutput='"$d1out"'
        kDevice2_IsHidden=true
        kDevice2_HasInput='"$d2in"'
        kDevice2_HasOutput='"$d2out"'' \
        >/dev/null

    rm -rf "$DIST/$out"
    cp -R "$build/BlackHole.driver" "$DIST/$out"
    codesign --force --deep --sign "${ODE_DRIVER_IDENTITY:--}" "$DIST/$out"
    rm -rf "$build"
    echo "✓ Built $DIST/$out  (visible: \"$vis\", hidden: \"$hid\")"
}

# Microphone driver: visible input-only mic + hidden output-only feed.
build_driver "ODEMicrophone.driver" "audio.ode.ODEMicrophone" "ODE-Mic" \
    "ODE Microphone" "ODE Mic Feed" true false false true

# Speaker driver: visible output-only speaker + hidden input-only tap.
build_driver "ODESpeaker.driver" "audio.ode.ODESpeaker" "ODE-Spk" \
    "ODE Speaker" "ODE Spk Tap" false true true false

rm -rf "$SRC_ROOT"
echo "Done. Two drivers built in $DIST/."
