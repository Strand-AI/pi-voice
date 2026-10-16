#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/PiVoicePhone.app" >&2
  exit 64
fi

app=$1
info="$app/Info.plist"
[ -f "$info" ] || { echo "missing built Info.plist: $info" >&2; exit 1; }

python3 - "$info" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
modes = info.get("UIBackgroundModes")
if not isinstance(modes, list):
    raise SystemExit("built UIBackgroundModes is missing or invalid")
required = {"audio", "voip"}
missing = sorted(required.difference(modes))
if missing:
    raise SystemExit(f"built UIBackgroundModes missing: {', '.join(missing)}")
if len(modes) != len(set(modes)):
    raise SystemExit("built UIBackgroundModes contains duplicates")
print("CallKitBundleChecks: audio+voip present")
PY
