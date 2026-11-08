#!/bin/bash
# Downloads the pinned Sparkle release once into mac/.build, checks its SHA-256 and prints its
# folder, which holds bin/generate_keys, bin/sign_update and bin/generate_appcast.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
DIR="$ROOT/.build/Sparkle-$VERSION"
if [ ! -x "$DIR/bin/sign_update" ]; then
  mkdir -p "$ROOT/.build"
  ARCHIVE="$ROOT/.build/Sparkle-$VERSION.tar.xz"
  curl -fsSL -o "$ARCHIVE" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  if ! printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
    rm -f "$ARCHIVE"
    printf 'Sparkle %s did not match its pinned SHA-256; nothing was extracted.\n' "$VERSION" >&2
    exit 1
  fi
  rm -rf "$DIR.partial" && mkdir -p "$DIR.partial"
  tar -xJf "$ARCHIVE" -C "$DIR.partial"
  rm -f "$ARCHIVE"
  rm -rf "$DIR" && mv "$DIR.partial" "$DIR"
fi
printf '%s\n' "$DIR"
