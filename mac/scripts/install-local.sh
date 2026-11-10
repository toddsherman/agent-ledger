#!/bin/bash
# Installs the build in mac/dist to /Applications and starts it. For local use between releases.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD/dist/Agent Ledger.app"
DST="/Applications/Agent Ledger.app"
[ -d "$SRC" ] || { echo "Run scripts/build-app.sh first." >&2; exit 1; }
# Stop every running copy; the quit marker keeps the keep-alive agent from racing the copy.
SUPPORT="${AGENT_LEDGER_HOME:-$HOME/Library/Application Support/AgentLedger}"
python3 -c 'import time;print(time.time()*1000)' > "$SUPPORT/quit-by-user"
pkill -x AgentLedger 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x AgentLedger >/dev/null || break; sleep 0.5; done
rm -rf "$DST"
ditto "$SRC" "$DST"
open -g "$DST"
echo "Installed and started $DST"
