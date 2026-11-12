#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
mkdir -p "$ROOT/build"
CASE_DIR=$(mktemp -d "$ROOT/build/process-recovery.XXXXXX")
trap 'if [[ ${RECOVERY_OK:-0} == 1 ]]; then rm -rf "$CASE_DIR"; else echo "Preserved failed case: $CASE_DIR"; fi' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [[ ! -d "$SDK/System/Library/Frameworks/CoreGraphics.framework" ]]; then SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk; fi
xcrun clang -I CSupport/include -c CSupport/XCTSystem.c -isysroot "$SDK" -o "$CASE_DIR/system.o"
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" -import-objc-header CSupport/include/XCTSystem.h Core/*.swift Scripts/RecoveryProbe.swift "$CASE_DIR/system.o" -o "$CASE_DIR/probe"
for mode in copy exchange backup; do
 set +e
 "$CASE_DIR/probe" crash "$mode" "$CASE_DIR/$mode"
 result=$?
 set -e
 [[ $result == 77 ]] || { echo "Unexpected process exit: $result"; exit 1; }
 "$CASE_DIR/probe" resume "$mode" "$CASE_DIR/$mode"
done
RECOVERY_OK=1
