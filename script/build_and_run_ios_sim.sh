#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/TailSync.xcodeproj"
SCHEME="TailSync"
CONFIGURATION="Debug"
APP_NAME="TailSync"

cd "$ROOT_DIR"

if [[ -n "${SIMULATOR_UDID:-}" ]]; then
  UDID="$SIMULATOR_UDID"
else
  UDID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Booted/ {print $2; exit} /iPhone/ && /Shutdown/ && !found {found=$2} END {if (found) print found}')"
fi

if [[ -z "${UDID:-}" ]]; then
  echo "No available iPhone simulator found."
  exit 1
fi

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "id=$UDID" \
  build

APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/${CONFIGURATION}-iphonesimulator/${APP_NAME}.app" -type d -print -quit)"
if [[ -z "${APP_PATH:-}" ]]; then
  echo "Simulator app not found."
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist")"
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
open -a Simulator
