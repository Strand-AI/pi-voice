#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
SWIFT_FLAGS="--disable-keychain --disable-netrc"
# The WebRTC artifact is public. Disabling credential lookup avoids ambiguous local
# GitHub keychain entries without reading or changing any credentials.
swift build $SWIFT_FLAGS -c release --product PiVoiceMac

BIN_DIR=$(swift build $SWIFT_FLAGS -c release --show-bin-path)
APP="$ROOT/.build/PiVoiceMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/PiVoiceMac" "$APP/Contents/MacOS/PiVoiceMac"
cp -R "$BIN_DIR/LiveKitWebRTC.framework" "$APP/Contents/Frameworks/LiveKitWebRTC.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/PiVoiceMac"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PiVoice.icns" "$APP/Contents/Resources/PiVoice.icns"
cp -R "$ROOT/Resources/ThirdPartyNotices" "$APP/Contents/Resources/ThirdPartyNotices"
printf 'Built %s\n' "$APP"
