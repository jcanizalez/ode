#!/bin/sh
# Notarize the ODE installer so it opens cleanly on any Mac.
#
# Prerequisites (one-time):
#   1. "Developer ID Application" + "Developer ID Installer" certificates in
#      the keychain (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +).
#   2. Stored notary credentials:
#        xcrun notarytool store-credentials ode-notary \
#            --apple-id <your-apple-id> --team-id VY822F9G5U \
#            --password <app-specific-password>
#      (App-specific password: appleid.apple.com ▸ Sign-In & Security.)
#   3. A pkg built with those identities: ./scripts/build-pkg.sh
#
# Usage:  ./scripts/notarize.sh [dist/ODE-x.y.z.pkg]

set -e
cd "$(dirname "$0")/.."

PKG="${1:-$(ls -t dist/ODE-*.pkg 2>/dev/null | head -1)}"
PROFILE="${ODE_NOTARY_PROFILE:-ode-notary}"

if [ -z "$PKG" ] || [ ! -f "$PKG" ]; then
    echo "No installer found. Build one with ./scripts/build-pkg.sh" >&2
    exit 1
fi

# The pkg must be signed with Developer ID for notarization to succeed.
if ! pkgutil --check-signature "$PKG" | grep -q "Developer ID Installer"; then
    echo "⚠ $PKG is not signed with a Developer ID Installer certificate." >&2
    echo "  Create the certificate, rebuild the pkg, then retry." >&2
    exit 1
fi

echo "Submitting $PKG for notarization (profile: $PROFILE)…"
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait

echo "Stapling ticket…"
xcrun stapler staple "$PKG"

echo "✓ $PKG is notarized and stapled — it will install cleanly on any Mac."
