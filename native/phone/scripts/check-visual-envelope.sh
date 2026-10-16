#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

xcrun swiftc \
  -warnings-as-errors \
  "$root/PiVoicePhone/App/VisualEnvelope.swift" \
  "$root/scripts/check-visual-envelope.swift" \
  -o "$temporary_directory/visual-envelope-checks"
"$temporary_directory/visual-envelope-checks"
