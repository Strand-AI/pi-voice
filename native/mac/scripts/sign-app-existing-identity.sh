#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/PiVoiceMac.app"
FRAMEWORK="$APP/Contents/Frameworks/LiveKitWebRTC.framework"
IDENTITY_SHA1="DB577D7A104BBEBF9DC5B32AA9266F95E74E89A9"
EXPECTED_TEAM_ID="ZJ2H5R49L5"
EXPECTED_BUNDLE_ID="local.pivoice.prototype"

fail() {
    printf 'sign-app: %s\n' "$*" >&2
    exit 1
}

[ -d "$APP" ] || fail "missing bundle; build $APP first"
[ -d "$FRAMEWORK" ] || fail "missing nested LiveKitWebRTC.framework"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") \
    || fail "cannot read bundle identifier"
[ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] \
    || fail "unexpected bundle identifier: $BUNDLE_ID"

IDENTITIES=$(security find-identity -v -p codesigning) \
    || fail "cannot read existing code-signing identities"
printf '%s\n' "$IDENTITIES" | grep -F "$IDENTITY_SHA1" >/dev/null \
    || fail "approved existing Apple Development identity is unavailable"

# Sign inside-out. There is intentionally no --deep signing, hardened-runtime
# change, entitlement change, timestamp service, key export, or keychain mutation.
codesign --force --sign "$IDENTITY_SHA1" --timestamp=none "$FRAMEWORK"
codesign --force --sign "$IDENTITY_SHA1" --timestamp=none "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

APP_DETAILS=$(codesign -dv --verbose=4 "$APP" 2>&1) \
    || fail "cannot inspect signed app"
FRAMEWORK_DETAILS=$(codesign -dv --verbose=4 "$FRAMEWORK" 2>&1) \
    || fail "cannot inspect signed framework"
APP_TEAM=$(printf '%s\n' "$APP_DETAILS" | awk -F= '$1 == "TeamIdentifier" { print $2 }')
FRAMEWORK_TEAM=$(printf '%s\n' "$FRAMEWORK_DETAILS" | awk -F= '$1 == "TeamIdentifier" { print $2 }')
[ "$APP_TEAM" = "$EXPECTED_TEAM_ID" ] \
    || fail "unexpected app TeamIdentifier: ${APP_TEAM:-missing}"
[ "$FRAMEWORK_TEAM" = "$EXPECTED_TEAM_ID" ] \
    || fail "unexpected framework TeamIdentifier: ${FRAMEWORK_TEAM:-missing}"

printf '%s\n' "$APP_DETAILS" | grep -E '^(Identifier|Authority|TeamIdentifier)='
printf 'Designated requirement:\n'
codesign -dr - "$APP" 2>&1
printf 'Signed and verified: %s\n' "$APP"
