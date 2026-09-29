#!/bin/bash
# Build + install + launch on the USB iPhone. Uses -sdk iphoneos (no destination), which works
# without Xcode's 8 GB "iOS platform" simulator component.
set -euo pipefail
cd "$(dirname "$0")"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}"
export DEVELOPMENT_TEAM
# First paired iPhone on USB unless DEVICE is set.
DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep "available (paired)" | grep -oE "[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}" | head -1)}
[ -n "$DEVICE" ] || { echo "no paired iPhone found; plug it in or set DEVICE" >&2; exit 1; }
xcodegen generate >/dev/null
xcodebuild -project FieldCapture.xcodeproj -target FieldCapture -sdk iphoneos -arch arm64 -configuration Debug \
  SYMROOT="$PWD/build/sdkbuild" -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
xcrun devicectl device install app --device "$DEVICE" build/sdkbuild/Debug-iphoneos/FieldCapture.app | grep -iE "error|installed"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.example.dochand | tail -1
