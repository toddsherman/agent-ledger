#!/bin/bash
# Builds a signed, notarized Agent Ledger release and its Sparkle appcast.
#
#   mac/scripts/release.sh             # build, notarize, staple, write dist/release/*
#   mac/scripts/release.sh --publish   # ...then create GitHub release v<version> with the assets
#
# Needs: the Developer ID identity, the notarytool keychain profile (NOTARY_PROFILE, default
# security-monitor-notary), and the Sparkle EdDSA key in the keychain (account agent-ledger).
# Bump the version first with mac/scripts/bump-version.sh and add a CHANGELOG.md section.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
REPO_ROOT="$(cd .. && pwd)"
PROFILE="${NOTARY_PROFILE:-security-monitor-notary}"
ACCOUNT="${SPARKLE_KEY_ACCOUNT:-agent-ledger}"
GITHUB_REPO="${GITHUB_REPO:-toddsherman/agent-ledger}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Todd Sherman (9N7KK8GB9Q)}"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

PLIST="$ROOT/Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
DMG_NAME="Agent-Ledger-$VERSION.dmg"
OUT="$ROOT/dist/release"
SPARKLE="$("$ROOT/scripts/sparkle.sh")"

# Preconditions, checked before anything is uploaded.
python3 "$ROOT/scripts/release-notes.py" "$REPO_ROOT/CHANGELOG.md" "$VERSION" md >/dev/null
KEY="$("$SPARKLE/bin/generate_keys" --account "$ACCOUNT" -p)"
if [ "$KEY" != "$(plutil -extract SUPublicEDKey raw -o - "$PLIST")" ]; then
  echo "The keychain's $ACCOUNT Sparkle key doesn't match SUPublicEDKey in Info.plist." >&2; exit 1
fi
if [ "$PUBLISH" = 1 ]; then
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then echo "Commit your changes before publishing." >&2; exit 1; fi
  if gh release view "v$VERSION" --repo "$GITHUB_REPO" >/dev/null 2>&1; then echo "Release v$VERSION already exists." >&2; exit 1; fi
fi

notarize() { # file label
  local result="$OUT/notary-$2.json"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$result"
  local status; status="$(plutil -extract status raw -o - "$result")"
  if [ "$status" != "Accepted" ]; then
    echo "Notarization of $2: $status. Log: xcrun notarytool log $(plutil -extract id raw -o - "$result") --keychain-profile $PROFILE" >&2
    exit 1
  fi
}

rm -rf "$OUT" && mkdir -p "$OUT/updates"
SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh"
APP="$ROOT/dist/Agent Ledger.app"
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
case "$SIGNATURE_INFO" in *"Authority=$IDENTITY"*) ;; *) echo "App is not signed with $IDENTITY." >&2; exit 1 ;; esac

echo "Notarizing the app (a few minutes)…"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
notarize "$OUT/app.zip" app
xcrun stapler staple "$APP"
rm -f "$OUT/app.zip"

echo "Building and notarizing $DMG_NAME…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Agent Ledger.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Agent Ledger $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/updates/$DMG_NAME"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$OUT/updates/$DMG_NAME"
notarize "$OUT/updates/$DMG_NAME" dmg
xcrun stapler staple "$OUT/updates/$DMG_NAME"
xcrun stapler validate "$OUT/updates/$DMG_NAME"
spctl --assess --type open --context context:primary-signature -v "$OUT/updates/$DMG_NAME"

echo "Writing the Sparkle appcast…"
python3 "$ROOT/scripts/release-notes.py" "$REPO_ROOT/CHANGELOG.md" "$VERSION" html > "$OUT/updates/${DMG_NAME%.dmg}.html"
"$SPARKLE/bin/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$GITHUB_REPO" -o "$OUT/appcast.xml" "$OUT/updates"
mv "$OUT/updates/$DMG_NAME" "$OUT/$DMG_NAME"
rm -rf "$OUT/updates"
(cd "$OUT" && shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt)
python3 "$ROOT/scripts/release-notes.py" "$REPO_ROOT/CHANGELOG.md" "$VERSION" md > "$OUT/notes.md"
case "$(cat "$OUT/appcast.xml")" in *sparkle:edSignature*) ;; *) echo "appcast.xml has no EdDSA signature." >&2; exit 1 ;; esac
echo "Release $VERSION ($BUILD) is in $OUT"

if [ "$PUBLISH" = 1 ]; then
  gh release create "v$VERSION" "$OUT/$DMG_NAME" "$OUT/appcast.xml" "$OUT/SHA256SUMS.txt" \
    --repo "$GITHUB_REPO" --title "Agent Ledger $VERSION" --notes-file "$OUT/notes.md"
  echo "Published https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
fi
