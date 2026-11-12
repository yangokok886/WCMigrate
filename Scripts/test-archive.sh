#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
xcrun clang -fobjc-arc -fmodules -isysroot "$SDK" -I Vendor/WQFiles Tests/ArchiveTests.m Vendor/WQFiles/WQArchive.m Vendor/WQFiles/WQLocalization.m -framework Foundation -lz -o build/archive-tests
build/archive-tests
