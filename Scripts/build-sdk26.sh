#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
"$ROOT/Scripts/prepare-sdk26.sh"
"$ROOT/Scripts/test.sh" > "$ROOT/build/sdk26-tests.log" 2>&1
"$ROOT/Scripts/test-launchservices.sh" > "$ROOT/build/sdk26-launchservices-tests.log" 2>&1
"$ROOT/Scripts/test-archive.sh" > "$ROOT/build/sdk26-archive-tests.log" 2>&1
command -v xcodegen >/dev/null && xcodegen generate
HOST="$ROOT/build/XcodeHost.app/Contents/Developer"
TC="$ROOT/build/toolchains/swift-6.2.xctoolchain/usr/bin"
LOG="$ROOT/build/sdk26-build-$(date +%Y%m%d-%H%M%S).log"
# This process only; never changes xcode-select or an installed SDK.
DEVELOPER_DIR="$HOST" "$HOST/usr/bin/xcodebuild" \
 -project "$ROOT/XChatTransfer.xcodeproj" -scheme XChatTransfer \
 -configuration Release -sdk iphoneos26.0 -destination 'generic/platform=iOS' \
 -derivedDataPath "$ROOT/build/sdk26-device" \
 "SWIFT_EXEC=$TC/swiftc" "CC=$TC/clang" "CXX=$TC/clang++" \
 'FRAMEWORK_SEARCH_PATHS=$(inherited) "$(SDKROOT)/System/Library/SubFrameworks"' \
 SWIFT_ENABLE_EXPLICIT_MODULES=NO CODE_SIGNING_ALLOWED=NO build > "$LOG" 2>&1
cp "$LOG" "$ROOT/build/sdk26-final.log"
"$ROOT/Scripts/package-sdk26.sh"
