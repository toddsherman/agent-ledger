#!/bin/bash
# Builds "Agent Ledger.app" into mac/dist, signed with Developer ID when that identity is in
# the keychain (or SIGN_IDENTITY), otherwise ad hoc for local development.
#
# On launch the app copies its helpers to ~/Library/Application Support/AgentLedger/bin and
# the Chrome extension to .../AgentLedger/extension, so hooks, Chrome and the unpacked
# extension keep working wherever the bundle lives.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

DEFAULT_IDENTITY="Developer ID Application: Todd Sherman (9N7KK8GB9Q)"
SIGN_IDENTITY="${SIGN_IDENTITY:-$DEFAULT_IDENTITY}"
IDENTITIES="$(security find-identity -v -p codesigning)"
if [ "$SIGN_IDENTITY" != "-" ] && [[ "$IDENTITIES" != *"\"$SIGN_IDENTITY\""* ]]; then
  printf 'Signing identity "%s" not found; building ad hoc.\n' "$SIGN_IDENTITY" >&2
  SIGN_IDENTITY="-"
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi

# Universal (Apple silicon + Intel).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
FRAMEWORK_SRC="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
APP="$ROOT/dist/Agent Ledger.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/AgentLedger" "$APP/Contents/MacOS/AgentLedger"
cp "$BIN/ledger-host" "$BIN/ledger-hook" "$BIN/ledgerctl" "$APP/Contents/Helpers/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The app installs this copy to ~/Library/Application Support/AgentLedger/extension.
rsync -a --exclude test --exclude ".DS_Store" "$ROOT/../extension/" "$APP/Contents/Resources/extension/"

# Sparkle installs the app's own updates. The app isn't sandboxed, so Sparkle's XPC services
# are never used and are removed.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$FRAMEWORK_SRC" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/B/XPCServices"
RPATHS="$(otool -l "$APP/Contents/MacOS/AgentLedger")"
if [[ "$RPATHS" != *"@executable_path/../Frameworks"* ]]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AgentLedger"
fi

# Sign inside out, without --deep, as Sparkle's documentation describes.
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Updater.app"
"${SIGN[@]}" "$FRAMEWORK"
for helper in ledger-host ledger-hook ledgerctl; do
  "${SIGN[@]}" "$APP/Contents/Helpers/$helper"
done
"${SIGN[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"
printf 'Built %s (%s, signed: %s)\n' "$APP" \
  "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" "$SIGN_IDENTITY"
