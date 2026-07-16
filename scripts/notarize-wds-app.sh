#!/usr/bin/env bash
#
# Notarize and staple the distributable WDS.app.
#
# Prerequisites (done once by the owner, on a machine with the credentials):
#   1. Build a Developer ID-signed bundle:
#        WDS_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
#          scripts/build-wds-app.sh
#   2. Store a notarytool credential profile once:
#        xcrun notarytool store-credentials WDS_NOTARY \
#          --apple-id "<apple-id-email>" --team-id "<TEAMID>" --password "<app-specific-password>"
#
# Then run:  WDS_NOTARY_PROFILE=WDS_NOTARY scripts/notarize-wds-app.sh
#
# This script intentionally does NOT create accounts, store passwords, or submit
# anything unless the owner has already provided credentials via the profile
# above. Notarization uploads the app to Apple; run it yourself, with your own
# Apple account.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/WDS.app"
PROFILE="${WDS_NOTARY_PROFILE:-}"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "error: $APP_BUNDLE not found. Build a signed bundle first (see header)." >&2
    exit 1
fi

# Refuse to notarize an ad-hoc-signed bundle: Apple would reject it anyway.
if codesign --display --verbose=2 "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
    echo "error: $APP_BUNDLE is ad-hoc signed. Rebuild with WDS_SIGN_IDENTITY set to a Developer ID." >&2
    exit 1
fi

if [ -z "$PROFILE" ]; then
    cat >&2 <<'EOF'
error: WDS_NOTARY_PROFILE is not set.

Store a notarytool credential profile once, then re-run:
  xcrun notarytool store-credentials WDS_NOTARY \
    --apple-id "<apple-id-email>" --team-id "<TEAMID>" --password "<app-specific-password>"
  WDS_NOTARY_PROFILE=WDS_NOTARY scripts/notarize-wds-app.sh
EOF
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ZIP_PATH="$WORK_DIR/WDS.zip"

echo "Zipping bundle for submission…"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "Submitting to Apple notary service (this uploads the app)…"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --wait

echo "Stapling the notarization ticket…"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

echo "Notarized and stapled: $APP_BUNDLE"
