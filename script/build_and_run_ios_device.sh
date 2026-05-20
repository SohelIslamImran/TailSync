#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/TailSync.xcodeproj"
SCHEME="TailSync"
CONFIGURATION="Debug"
APP_NAME="TailSync"

cd "$ROOT_DIR"

if [[ -n "${IOS_DEVICE_ID:-}" ]]; then
  DEVICE_ID="$IOS_DEVICE_ID"
else
  DEVICE_ID="$(xcrun devicectl list devices --json-output - | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); devices=data.get("result",{}).get("devices",[]); print(next((d.get("identifier","") for d in devices if d.get("hardwareProperties",{}).get("deviceType","").lower().find("iphone") >= 0 and d.get("connectionProperties",{}).get("pairingState") == "paired"), ""))')"
fi

if [[ -z "${DEVICE_ID:-}" ]]; then
  echo "No paired iPhone found. Set IOS_DEVICE_ID to choose one."
  exit 1
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "id=$DEVICE_ID" \
  build

APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/${CONFIGURATION}-iphoneos/${APP_NAME}.app" -type d -print -quit)"
if [[ -z "${APP_PATH:-}" ]]; then
  echo "Device app not found."
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist")"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
