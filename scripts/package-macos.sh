#!/usr/bin/env bash
# Build, sign, notarize, and staple WDS.app plus its DMG.
#
# scripts/build-wds-app.sh assembles the bundle from five SwiftPM packages and
# ad-hoc signs it ("codesign --sign -"). An ad-hoc designated requirement is a
# bare cdhash with no team anchor, so that bundle launches on the machine that
# built it and nowhere else. Developer ID signing plus notarization is what
# makes a downloaded copy open, and this script layers that on top rather than
# duplicating the build.
#
# WDS is not sandboxed — it reads and rewrites other applications' focused text
# fields through the Accessibility API, which the App Sandbox forbids outright.
# See native/WDSApp/Resources/WDS.entitlements.
#
# The four helpers in Contents/Helpers (wds-sensor, wds-whack, wds-ax-bridge,
# wds-terminal-adapter) are bare Mach-O executables, not nested bundles, so the
# shared signing pass below — which walks dylibs, .framework/.xpc/.app, then the
# main executable — never reaches them and they would stay ad-hoc signed.
# Notarization rejects the whole submission for that ("not signed with a valid
# Developer ID certificate"), so build_app re-signs them itself, inside-out,
# before the shared half takes over.
#
# Environment:
#   SIGN_IDENTITY       — codesign identity. Default: the Developer ID
#                         Application identity found in the keychain.
#   NOTARY_PROFILE      — notarytool keychain profile. Default: AC_API.
#   SKIP_BUILD=1        — package whatever is already in dist/. This also skips
#                         the helper re-signing, so only use it on a tree this
#                         script has already built once.
#   SKIP_NOTARIZATION=1 — sign and package without contacting Apple. Useful
#                         offline; the result still will not pass Gatekeeper on
#                         another Mac, because notarization is what Gatekeeper
#                         checks.
#
# Exit codes:
#   0  success
#   1  build/packaging/signing failure
#   2  Apple rejected notarization
#   3  Gatekeeper assessment failed after notarization

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Repo-specific ────────────────────────────────────────────────────
# Everything below the closing marker is shared verbatim with the other
# Heznpc macOS repos; keep edits above it so the shared half stays diffable.
PRODUCTS_DIR="${ROOT}/dist"
ENTITLEMENTS="${ROOT}/native/WDSApp/Resources/WDS.entitlements"

build_app() {
  # Thin wrapper: build-wds-app.sh owns the assembly (five swift build runs,
  # Info.plist, the zsh plugin resource, the ad-hoc signature). Duplicating any
  # of that here would mean two definitions of the bundle layout to keep in sync.
  "${ROOT}/scripts/build-wds-app.sh"

  local app="${PRODUCTS_DIR}/WDS.app"
  local helpers="${app}/Contents/Helpers"
  [ -d "${helpers}" ] || die "no ${helpers} — build-wds-app.sh changed its layout"

  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "${app}/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "${bundle_id}" ] || die "no CFBundleIdentifier in ${app}/Contents/Info.plist"

  # Replace the ad-hoc helper signatures with Developer ID ones carrying the
  # hardened runtime and a trusted timestamp — the two things notarization
  # requires of every Mach-O in the submission. Name each identifier explicitly:
  # codesign otherwise derives it from the file name, which would give these
  # four a team-less-looking identity in TCC and in any signature dump.
  #
  # No entitlements here. The helpers need Accessibility and Input Monitoring,
  # both of which are TCC grants attributed to the parent app, not entitlements.
  xattr -cr "${app}"
  local helper name
  for helper in "${helpers}"/*; do
    [ -f "${helper}" ] || continue
    name="$(basename "${helper}")"
    log "signing helper ${name}"
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp \
      --identifier "${bundle_id}.${name}" "${helper}"
  done
}
# ── End repo-specific ────────────────────────────────────────────────

DIST_DIR="${ROOT}/build/dist"
STAGE_DIR="${ROOT}/build/dmg-stage"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_API}"

log() { printf 'package-macos: %s\n' "$*"; }
die() { printf 'package-macos: %s\n' "$*" >&2; exit 1; }

# ── Resolve the signing identity ─────────────────────────────────────
# Unlike a local-only tool, there is no useful ad-hoc fallback here: the whole
# point of this script is producing something another Mac will open. Fail loudly
# rather than emitting a bundle that looks packaged and is not distributable.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | grep "Developer ID Application" \
      | head -n 1 \
      | sed -n 's/.*"\(.*\)".*/\1/p'
  )"
fi
[ -n "${SIGN_IDENTITY}" ] \
  || die "no Developer ID Application identity in the keychain — cannot produce a distributable build"

[ -f "${ENTITLEMENTS}" ] || die "missing entitlements file: ${ENTITLEMENTS}"

# ── Build ────────────────────────────────────────────────────────────
if [ "${SKIP_BUILD:-}" != "1" ]; then
  build_app
fi

APP_SRC="$(find "${PRODUCTS_DIR}" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
[ -n "${APP_SRC}" ] || die "no .app in ${PRODUCTS_DIR} — run without SKIP_BUILD=1"

APP_NAME="$(basename "${APP_SRC}")"
APP="${DIST_DIR}/${APP_NAME}"
BASE="${APP_NAME%.app}"
ZIP_PATH="${DIST_DIR}/${BASE}-notarize.zip"

rm -rf "${DIST_DIR}" "${STAGE_DIR}"
mkdir -p "${DIST_DIR}"
ditto "${APP_SRC}" "${APP}"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "${APP}/Contents/Info.plist" 2>/dev/null; }

VERSION="$(plist_get CFBundleShortVersionString || true)"
[ -n "${VERSION}" ] || VERSION="0.0.0"
BUNDLE_ID="$(plist_get CFBundleIdentifier || true)"
# Take the executable name from the bundle rather than assuming it matches the
# bundle name — PRODUCT_NAME and EXECUTABLE_NAME are separate settings.
EXECUTABLE="$(plist_get CFBundleExecutable || true)"
[ -n "${EXECUTABLE}" ] || die "no CFBundleExecutable in ${APP}/Contents/Info.plist"
DMG_PATH="${DIST_DIR}/${BASE}-${VERSION}.dmg"

log "bundle ${BUNDLE_ID} version ${VERSION} executable ${EXECUTABLE}"

# ── Sign ─────────────────────────────────────────────────────────────
# Sign inside-out — nested Mach-O first, the wrapper last — instead of --deep.
# --deep is deprecated, applies the outer entitlements to nested code, and picks
# its own opinion about what counts as code; a Flutter bundle carries a dozen
# plugin frameworks and gets that wrong in ways that only surface at notarization.
#
# --options runtime enables the hardened runtime and --timestamp embeds a
# trusted timestamp. Notarization rejects a submission missing either.
#
# Entitlements go on the app bundle only. Nested frameworks must not carry the
# sandbox entitlement: an entitled framework inside a sandboxed app is an
# invalid signature, not a stronger one.
sign() {
  codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp "$@"
}

# Extended attributes and resource forks copied along with the build products
# make codesign fail with "resource fork, Finder information, or similar
# detritus not allowed". Clear them before signing, not after a failure.
xattr -cr "${APP}"

log "signing as ${SIGN_IDENTITY}"

# Loose Mach-O payloads first (dylibs, .so plugins).
while IFS= read -r -d '' f; do
  sign "${f}"
done < <(find "${APP}/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)

# Then nested bundles, deepest first, so a framework is signed only after
# everything it contains already is.
while IFS= read -r -d '' b; do
  if [ "${b}" = "${APP}" ]; then
    continue
  fi
  sign "${b}"
done < <(find "${APP}" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print0)

# Then the main executable, then the wrapper with the app's entitlements.
sign "${APP}/Contents/MacOS/${EXECUTABLE}"
sign --entitlements "${ENTITLEMENTS}" "${APP}"

log "verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign --display --verbose=4 "${APP}" 2>&1 \
  | grep -E 'Identifier|Authority|TeamIdentifier|Timestamp|flags' || true
# ":-" is the form that writes a plain XML plist to stdout. A bare "-" writes
# the raw entitlement blob, magic header and all, which plutil cannot parse.
log "entitlements as signed"
codesign --display --entitlements :- "${APP}" 2>/dev/null | plutil -p - || true

build_dmg() {
  rm -rf "${STAGE_DIR}" "${DMG_PATH}"
  mkdir -p "${STAGE_DIR}"
  ditto "${APP}" "${STAGE_DIR}/${APP_NAME}"
  ln -s /Applications "${STAGE_DIR}/Applications"
  hdiutil create \
    -volname "${BASE}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

  # Sign the disk image itself, not just the app inside it. Gatekeeper assesses
  # the DMG when the user opens the download, and an unsigned image is judged
  # "no usable signature" even after it has been notarized and stapled — the
  # ticket has nothing to attach a verdict to.
  #
  # Name the identifier explicitly. codesign otherwise derives it from the file
  # name and truncates at the first dot, so "Fyle-0.1.0.dmg" would be signed as
  # "Fyle-0" — harmless but meaningless in a signature dump.
  codesign --force --sign "${SIGN_IDENTITY}" --timestamp \
    --identifier "${BUNDLE_ID}.dmg" "${DMG_PATH}"
}

notarize() {
  # $1 = path to submit. notarytool takes a .zip, .dmg, or .pkg — never a bare
  # .app directory.
  local target="$1"
  local raw status
  # Keep stderr out of the parse. notarytool interleaves human-readable
  # progress on stderr, and folding it into stdout turns the JSON document into
  # a stream the parser rejects — which reads as "no status" and would hide a
  # submission Apple actually accepted.
  raw="$(
    xcrun notarytool submit "${target}" \
      --keychain-profile "${NOTARY_PROFILE}" \
      --wait \
      --output-format json 2>/dev/null
  )"
  status="$(
    printf '%s' "${raw}" \
      | /usr/bin/python3 -c 'import json,sys
try:
    print(json.loads(sys.stdin.read().strip()).get("status", ""))
except Exception:
    print("")' 2>/dev/null
  )"
  if [ "${status}" != "Accepted" ]; then
    echo "package-macos: notarization of $(basename "${target}") returned '${status:-no status}'" >&2
    echo "package-macos: raw notarytool response: ${raw:-<empty>}" >&2
    echo "package-macos: inspect the log with: xcrun notarytool log <id> --keychain-profile \"${NOTARY_PROFILE}\"" >&2
    return 1
  fi
}

if [ "${SKIP_NOTARIZATION:-}" = "1" ]; then
  build_dmg
  log "packaged WITHOUT notarization — Gatekeeper will reject this on another Mac"
  echo "${APP}"
  echo "${DMG_PATH}"
  exit 0
fi

# ── Notarize and staple ──────────────────────────────────────────────
# Both artifacts get their own ticket. Stapling the .app before it goes into the
# image means the copy the user drags to /Applications is already self-sufficient,
# even if the DMG's own ticket never reaches them.
log "notarizing the app (2-10 minutes) …"
ditto -c -k --keepParent "${APP}" "${ZIP_PATH}"
notarize "${ZIP_PATH}" || exit 2
xcrun stapler staple "${APP}"

build_dmg

log "notarizing the disk image …"
notarize "${DMG_PATH}" || exit 2
xcrun stapler staple "${DMG_PATH}"

# ── Prove it ─────────────────────────────────────────────────────────
# spctl is the same assessment Gatekeeper runs on first launch. Passing here
# means it passes on a Mac that has never seen the app. Assert explicitly
# instead of trusting the exit code alone, because a "rejected" verdict with a
# source of "Unnotarized Developer ID" is the exact failure this script exists
# to prevent and it should never be reported as a success.
assert_accepted() {
  local label="$1"; shift
  local out
  if ! out="$(spctl "$@" 2>&1)"; then
    echo "package-macos: Gatekeeper REJECTED ${label}:" >&2
    echo "${out}" >&2
    return 1
  fi
  printf '%s\n' "${out}"
  case "${out}" in
    *accepted*) ;;
    *) echo "package-macos: Gatekeeper verdict for ${label} was not 'accepted'" >&2; return 1 ;;
  esac
}

log "Gatekeeper assessment"
assert_accepted "the app" --assess --type execute --verbose=2 "${APP}" || exit 3
assert_accepted "the disk image" --assess --type open \
  --context context:primary-signature --verbose=2 "${DMG_PATH}" || exit 3

log "stapled ticket check"
xcrun stapler validate "${APP}"
xcrun stapler validate "${DMG_PATH}"

echo "${APP}"
echo "${DMG_PATH}"
