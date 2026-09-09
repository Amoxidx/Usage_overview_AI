#!/bin/bash
set -euo pipefail
APP="${1:-$HOME/Desktop/UsageOverview.app}"
# Prefer Desktop copy; fall back to DerivedData
if [[ ! -d "$APP" ]]; then
  APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/UsageOverview-*/Build/Products/Debug/UsageOverview.app 2>/dev/null | head -1 || true)
fi
if [[ -z "${APP}" || ! -d "$APP" ]]; then
  echo "UsageOverview.app not found" >&2
  exit 1
fi
pkill -f 'UsageOverview.app/Contents/MacOS/UsageOverview' 2>/dev/null || true
sleep 0.3
# Launch via LaunchServices so it stays alive in the GUI session (unlike bare & from a tool shell).
open "$APP"
echo "opened $APP"
