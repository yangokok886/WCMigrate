#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [[ ! -d "$SDK/System/Library/Frameworks/CoreGraphics.framework" ]] && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]]; then
 SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
fi
swift test --sdk "$SDK"
