#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Pass a dedicated simulator UDID. Never resets or deletes a simulator.
DEVICE=${1:?Usage: Scripts/test-ui.sh SIMULATOR_UDID}
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p build
xcodebuild test -project XChatTransfer.xcodeproj -scheme XChatTransfer \
 -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE" \
 -derivedDataPath build/simulator -resultBundlePath "build/ui-$STAMP.xcresult" \
 CODE_SIGNING_ALLOWED=NO > "build/ui-$STAMP.log" 2>&1
printf 'UI test result: %s/build/ui-%s.xcresult\n' "$PWD" "$STAMP"
