#!/bin/bash
# Builds the Chrome Web Store upload: dist/agent-ledger-chrome-<version>.zip.
# The development manifest's "key" (which pins the unpacked extension's ID) is removed,
# because the Web Store assigns the listed item's ID itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/extension/manifest.json")"
STAGE="$ROOT/dist/chrome-$VERSION"
ZIP="$ROOT/dist/agent-ledger-chrome-$VERSION.zip"
rm -rf "$STAGE" "$ZIP" && mkdir -p "$STAGE"
rsync -a --exclude test --exclude ".DS_Store" "$ROOT/extension/" "$STAGE/"
python3 -I - "$STAGE/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m.pop("key", None)
json.dump(m, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
for f in background/main.js content/capture.js lib/redact.js lib/describe-element.js; do node --check "$STAGE/$f"; done
(cd "$STAGE" && zip -qr -X "$ZIP" .)
rm -rf "$STAGE"
echo "$ZIP"
