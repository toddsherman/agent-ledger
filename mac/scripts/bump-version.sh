#!/bin/bash
# Sets the app's marketing version and increments its build number (Sparkle compares builds).
#   mac/scripts/bump-version.sh 0.1.1
set -euo pipefail
[ "$#" -eq 1 ] || { echo "usage: $0 <version>" >&2; exit 2; }
PLIST="$(cd "$(dirname "$0")/.." && pwd)/Resources/Info.plist"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
plutil -replace CFBundleShortVersionString -string "$1" "$PLIST"
plutil -replace CFBundleVersion -string "$((BUILD + 1))" "$PLIST"
echo "Version $1 (build $((BUILD + 1))). Add a '## $1' section to CHANGELOG.md, commit, then run mac/scripts/release.sh --publish."
