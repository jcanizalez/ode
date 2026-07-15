#!/bin/sh
# Build ODE.app — a menu-bar application bundle wrapping the ODE engine.
# Produces ./dist/ODE.app, ad-hoc signed so macOS will show the microphone
# permission prompt. No Xcode required (uses the Swift toolchain).

set -e
cd "$(dirname "$0")/.."

# FoundationModels' @Generable macros need Xcode's toolchain (the Command
# Line Tools lack the macro plugin).
XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
[ -n "$XCODE" ] && export DEVELOPER_DIR="$XCODE/Contents/Developer"

APP="dist/ODE.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
ODE_VERSION="${ODE_VERSION:-0.9.0}"

echo "Building release binary…"
swift build -c release --product ODEApp

echo "Assembling app bundle at $APP ..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp ".build/release/ODEApp" "$MACOS/ODE"
cp "Resources/dpdfnet2_48khz_hr.onnx" "$RES/"

# App icon — rendered from code (scripts/make-icon.swift).
ICONSET="$(mktemp -d)/ODE.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$RES/ODE.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ODE</string>
    <key>CFBundleDisplayName</key>     <string>ODE</string>
    <key>CFBundleIdentifier</key>      <string>com.ode.app</string>
    <key>CFBundleVersion</key>         <string>__ODE_VERSION__</string>
    <key>CFBundleShortVersionString</key><string>__ODE_VERSION__</string>
    <key>CFBundleExecutable</key>      <string>ODE</string>
    <key>CFBundleIconFile</key>        <string>ODE</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>ODE needs the microphone to remove background noise in real time.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>ODE reads your calendar to title meeting transcripts with the event name.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>ODE transcribes meetings on-device so you can keep searchable notes.</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST
# Stamp the version (overridable: ODE_VERSION=1.2.3 ./scripts/build-app.sh).
sed -i '' "s/__ODE_VERSION__/$ODE_VERSION/g" "$APP/Contents/Info.plist"

# --- Code signing ---
# Prefer a real certificate: a stable identity means macOS remembers the
# microphone permission across rebuilds (ad-hoc builds re-prompt every time).
#   Developer ID Application  -> distribution-grade (notarizable)
#   Apple Development         -> fine for local builds
#   "-" (ad-hoc)              -> fallback
IDENTITY="${ODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
        IDENTITY="Developer ID Application"
    elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
        IDENTITY="Apple Development"
    else
        IDENTITY="-"
    fi
fi
echo "Code signing with identity: $IDENTITY"

ENTITLEMENTS="$(mktemp).plist"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.personal-information.calendars</key><true/>
</dict>
</plist>
ENT
codesign --force --deep --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" "$APP" \
  || codesign --force --deep --sign - "$APP"
rm -f "$ENTITLEMENTS"

echo
echo "✓ Built $APP"
echo "Run it with:   open $APP"
echo "(It appears as a waveform icon in the menu bar — no Dock icon.)"
