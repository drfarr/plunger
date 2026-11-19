#!/bin/sh
# Builds, signs with Developer ID, notarises, staples and zips GH Actions Bar.
#
# One-time setup:
#   1. Developer ID Application certificate in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   2. Notary credentials stored in the keychain:
#        xcrun notarytool store-credentials gh-actions-bar --apple-id <you> --team-id <TEAMID>
#
# Usage: ./release.sh 0.1.0
set -e
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>}"
APP="GH Actions Bar.app"
ZIP="GHActionsBar-$VERSION.zip"
PROFILE="${NOTARY_PROFILE:-gh-actions-bar}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)}"
[ -n "$SIGN_ID" ] || { echo "No 'Developer ID Application' certificate found in keychain." >&2; exit 1; }

VERSION="$VERSION" ./build.sh

echo "Signing with: $SIGN_ID"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarising (usually 1–5 min)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

# Re-zip so the stapled ticket ships inside the download.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

echo
echo "Ready: $(pwd)/$ZIP"
echo "sha256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
