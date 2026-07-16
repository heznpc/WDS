#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PACKAGE="$ROOT_DIR/native/WDSApp"
INFO_PLIST="$APP_PACKAGE/Resources/Info.plist"
OUTPUT_APP="$ROOT_DIR/dist/WDS.app"

build_product() {
    local package_path="$1"
    local product_name="$2"
    local destination="$3"

    swift build --package-path "$package_path" --configuration release --product "$product_name"
    local binary_directory
    binary_directory="$(swift build --package-path "$package_path" --configuration release --show-bin-path)"
    install -m 0755 "$binary_directory/$product_name" "$destination"
}

rm -rf "$OUTPUT_APP"
mkdir -p "$OUTPUT_APP/Contents/MacOS" "$OUTPUT_APP/Contents/Helpers" "$OUTPUT_APP/Contents/Resources/Shell"

build_product "$APP_PACKAGE" "WDSApp" "$OUTPUT_APP/Contents/MacOS/WDS"
build_product "$ROOT_DIR/native/WDSSensor" "wds-sensor" "$OUTPUT_APP/Contents/Helpers/wds-sensor"
build_product "$ROOT_DIR/native/WDSWhack" "wds-whack" "$OUTPUT_APP/Contents/Helpers/wds-whack"
build_product "$ROOT_DIR/native/WDSAxBridge" "wds-ax-bridge" "$OUTPUT_APP/Contents/Helpers/wds-ax-bridge"
build_product "$ROOT_DIR/native/WDSTerminalAdapter" "wds-terminal-adapter" "$OUTPUT_APP/Contents/Helpers/wds-terminal-adapter"

install -m 0644 "$INFO_PLIST" "$OUTPUT_APP/Contents/Info.plist"
install -m 0644 "$ROOT_DIR/native/WDSTerminalAdapter/Integration/wds-zle.plugin.zsh" \
    "$OUTPUT_APP/Contents/Resources/Shell/wds-zle.plugin.zsh"
plutil -lint "$OUTPUT_APP/Contents/Info.plist"

# Signing identity. Defaults to ad-hoc ("-") for local development. Set
# WDS_SIGN_IDENTITY to a "Developer ID Application: …" identity to produce a
# distributable, notarizable build (hardened runtime + secure timestamp).
SIGN_IDENTITY="${WDS_SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_OPTS=(--timestamp=none)
else
    SIGN_OPTS=(--options runtime --timestamp)
fi

if command -v codesign >/dev/null 2>&1; then
    # Sign helpers first (inside-out), then the app bundle.
    for helper in "$OUTPUT_APP"/Contents/Helpers/*; do
        codesign --force --sign "$SIGN_IDENTITY" "${SIGN_OPTS[@]}" "$helper"
    done
    codesign --force --sign "$SIGN_IDENTITY" "${SIGN_OPTS[@]}" "$OUTPUT_APP/Contents/MacOS/WDS"
    codesign --force --deep --sign "$SIGN_IDENTITY" "${SIGN_OPTS[@]}" "$OUTPUT_APP"
    codesign --verify --deep --strict "$OUTPUT_APP"
    if [ "$SIGN_IDENTITY" != "-" ]; then
        echo "Signed with: $SIGN_IDENTITY (hardened runtime). Run scripts/notarize-wds-app.sh to notarize."
    fi
fi

echo "Built $OUTPUT_APP"
