#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SDK26=${SDK26:-$(xcrun --sdk iphoneos --show-sdk-path)}
XCODE_SOURCE=${XCODE_SOURCE:-$(xcode-select -p)/../..}
HOST="$ROOT/build/XcodeHost.app"
TC="$ROOT/build/toolchains/swift-6.2.xctoolchain"
python3 - "$SDK26" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]); d=json.loads((p/'SDKSettings.json').read_text())
assert d['Version']=='26.0' and d['CanonicalName']=='iphoneos26.0' and 'iphoneos' in d['SupportedTargets']
print('SDK26 verified:',p)
PY
mkdir -p "$ROOT/build/toolchains"
if [[ ! -d "$HOST" ]]; then cp -cR "$XCODE_SOURCE" "$HOST"; fi
LINK="$HOST/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.0.sdk"
if [[ -L "$LINK" ]]; then
 [[ "$(readlink "$LINK")" == "$SDK26" ]] || { echo '项目内宿主指向其他 SDK；请检查后使用独立输出目录。' >&2; exit 2; }
elif [[ ! -e "$LINK" ]]; then ln -s "$SDK26" "$LINK"; fi
if [[ ! -x "$TC/usr/bin/swiftc" ]]; then
 PKG="$ROOT/build/toolchains/swift-6.2.pkg"
 if [[ ! -f "$PKG" ]]; then
  curl -fL --retry 2 'https://download.swift.org/swift-6.2-release/xcode/swift-6.2-RELEASE/swift-6.2-RELEASE-osx.pkg' -o "$PKG.part"
  mv "$PKG.part" "$PKG"
 fi
 pkgutil --check-signature "$PKG" | tee "$ROOT/build/toolchains/package-signature.log"
 mkdir -p "$ROOT/build/toolchains/pkg"
 (cd "$ROOT/build/toolchains/pkg" && xar -xf "$PKG")
 mkdir -p "$TC"
 LC_ALL=C tar -xzf "$ROOT/build/toolchains/pkg/swift-6.2-RELEASE-osx-package.pkg/Payload" -C "$TC" ./usr ./Info.plist
fi
"$TC/usr/bin/swiftc" --version
"$TC/usr/bin/clang" --version
printf '项目内宿主：%s\n工具链：%s\nSDK：%s\n' "$HOST" "$TC" "$SDK26"
