#!/bin/sh
# Build the ODE installer package (.pkg).
#
# The package installs two things and is the only thing a user needs to run:
#   1. ODE.app                  -> /Applications
#   2. ODEMicrophone.driver     -> /Library/Audio/Plug-Ins/HAL   (the virtual mic)
# A postinstall script reloads CoreAudio so "ODE Microphone" appears immediately
# without a reboot, then launches the app.
#
# Prerequisites (built by this script if missing):
#   - dist/ODE.app                 (scripts/build-app.sh)
#   - the branded virtual-mic driver (scripts/build-driver.sh)

set -e
cd "$(dirname "$0")/.."

VERSION="0.5.3"
IDENTIFIER="audio.ode.installer"
DIST="dist"
APP="$DIST/ODE.app"
MIC_DRIVER="$DIST/ODEMicrophone.driver"
SPK_DRIVER="$DIST/ODESpeaker.driver"
PKG_OUT="$DIST/ODE-$VERSION.pkg"

# --- Ensure the app exists ---
if [ ! -d "$APP" ]; then
    echo "Building ODE.app…"
    ./scripts/build-app.sh
fi

# --- Ensure both drivers exist ---
if [ ! -d "$MIC_DRIVER" ] || [ ! -d "$SPK_DRIVER" ]; then
    echo "Building the ODE virtual-audio drivers…"
    ./scripts/build-driver.sh
fi

echo "Staging package payload…"
ROOT="$(mktemp -d)"
mkdir -p "$ROOT/Applications"
mkdir -p "$ROOT/Library/Audio/Plug-Ins/HAL"
# ditto avoids the AppleDouble (._*) files that cp -R leaves behind.
ditto "$APP" "$ROOT/Applications/ODE.app"
ditto "$MIC_DRIVER" "$ROOT/Library/Audio/Plug-Ins/HAL/ODEMicrophone.driver"
ditto "$SPK_DRIVER" "$ROOT/Library/Audio/Plug-Ins/HAL/ODESpeaker.driver"

# --- postinstall: reload CoreAudio and launch the app ---
SCRIPTS="$(mktemp -d)"
cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/sh
# Reload CoreAudio so the freshly installed virtual mic is picked up now.
/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || \
    /usr/bin/killall coreaudiod 2>/dev/null || true

# Launch ODE for the user who initiated the install.
if [ -n "$USER" ] && [ "$USER" != "root" ]; then
    /usr/bin/open -a "/Applications/ODE.app" 2>/dev/null || true
fi
exit 0
POST
chmod +x "$SCRIPTS/postinstall"

echo "Building component package…"
COMPONENT="$(mktemp -d)/ode-component.pkg"
# Disable bundle relocation so ODE.app always installs to /Applications even if
# a copy with the same bundle ID exists elsewhere on disk (e.g. dist/ODE.app).
CPLIST="$(mktemp -d)/components.plist"
pkgbuild --analyze --root "$ROOT" "$CPLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$CPLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :1:BundleIsRelocatable false" "$CPLIST" 2>/dev/null || true
pkgbuild \
    --root "$ROOT" \
    --component-plist "$CPLIST" \
    --scripts "$SCRIPTS" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT"

echo "Building product archive…"
DISTXML="$(mktemp -d)/distribution.xml"
cat > "$DISTXML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>ODE — an ode to your voice</title>
    <organization>audio.ode</organization>
    <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
    <welcome mime-type="text/plain"><![CDATA[
ODE installs:
  • ODE.app in your Applications folder
  • the "ODE Microphone" virtual device

After installation, choose "ODE Microphone" as the microphone in your
conferencing app, and turn ODE on from its menu-bar icon.
]]></welcome>
    <pkg-ref id="$IDENTIFIER"/>
    <choices-outline>
        <line choice="default">
            <line choice="$IDENTIFIER"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$IDENTIFIER" visible="false">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">ode-component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild \
    --distribution "$DISTXML" \
    --package-path "$(dirname "$COMPONENT")" \
    "$PKG_OUT"

# --- Optional signing (set ODE_INSTALLER_IDENTITY to a Developer ID Installer) ---
if [ -n "$ODE_INSTALLER_IDENTITY" ]; then
    echo "Signing installer with '$ODE_INSTALLER_IDENTITY'…"
    productsign --sign "$ODE_INSTALLER_IDENTITY" "$PKG_OUT" "$PKG_OUT.signed"
    mv "$PKG_OUT.signed" "$PKG_OUT"
fi

rm -rf "$ROOT" "$SCRIPTS"
echo
echo "✓ Built $PKG_OUT"
echo "Install with:  open \"$PKG_OUT\""
