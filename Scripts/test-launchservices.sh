#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/launchservices-tests
SDK="${MACOS_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
if [[ ! -d "$SDK" ]]; then SDK=$(xcrun --sdk macosx --show-sdk-path); fi
xcrun --sdk macosx clang -fobjc-arc -fmodules -DWQ_LS_TESTING=1 \
 -fmodules-cache-path="$PWD/build/launchservices-tests/modules" -isysroot "$SDK" \
 -Wall -Wextra -Werror -I Vendor/WQFiles \
 Vendor/WQFiles/WQLaunchServices.m Vendor/WQFiles/WQLocalization.m Tests/LaunchServicesTests.m \
 -framework Foundation -o build/launchservices-tests/parser-tests
build/launchservices-tests/parser-tests
