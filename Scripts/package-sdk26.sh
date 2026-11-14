#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PRODUCT="$ROOT/build/sdk26-device/Build/Products/Release-iphoneos/XChatTransfer.app"
STAGE="$ROOT/build/sdk26-package"
APP="$STAGE/Payload/XChatTransfer.app"
IPA="${IPA_OUTPUT:-$ROOT/build/WCMigrate-1.0.3-sdk26-adhoc.ipa}"
mkdir -p "$STAGE/Payload"
rm -rf "$APP"
cp -R "$PRODUCT" "$APP"
# All system Swift libraries used here are supplied by the deployment OS; no third-party binary framework.
codesign --force --sign - --entitlements "$ROOT/Resources/AppGroup.entitlements" "$APP"
codesign --verify --deep --strict "$APP" > "$ROOT/build/sdk26-signature.log" 2>&1
codesign -d --entitlements :- "$APP" > "$ROOT/build/sdk26-entitlements.plist" 2> "$ROOT/build/sdk26-signature-details.log"
xcrun vtool -show-build "$APP/XChatTransfer" > "$ROOT/build/sdk26-macho.txt"
xcrun lipo -archs "$APP/XChatTransfer" > "$ROOT/build/sdk26-archs.txt"
python3 - "$APP" "$ROOT/build/sdk26-macho.txt" "$ROOT/build/sdk26-entitlements.plist" <<'PY'
import sys,plistlib,pathlib,re
app=pathlib.Path(sys.argv[1]); text=pathlib.Path(sys.argv[2]).read_text()
info=plistlib.loads((app/'Info.plist').read_bytes()); ent=plistlib.loads(pathlib.Path(sys.argv[3]).read_bytes())
assert re.search(r'platform\s+IOS\b',text),text
assert re.search(r'sdk\s+26\.0\b',text),text
assert re.search(r'minos\s+17\.0\b',text),text
assert info['MinimumOSVersion']=='17.0',info
assert info['DTSDKName']=='iphoneos26.0',info
assert info['CFBundleIdentifier']=='local.xchat.transfer'
assert ent['com.apple.security.application-groups']==['group.local.xchat.transfer']
assert not list(app.rglob('*.appex')),'Unexpected extension'
print('Mach-O / Info.plist / entitlement assertions passed')
PY
rm -f "$IPA.tmp"
(cd "$STAGE" && /usr/bin/zip -qry "$IPA.tmp" Payload)
unzip -t "$IPA.tmp" > "$ROOT/build/sdk26-zip-validation.log"
mv "$IPA.tmp" "$IPA"
LC_ALL=C shasum -a 256 "$IPA" | tee "$IPA.sha256"
python3 "$ROOT/Scripts/verify-ipa.py" "$IPA" > "$ROOT/build/sdk26-ipa-verification.json"
printf 'IPA: %s\n注意：adhoc 验签通过，仅是重签输入，不具备普通真机安装授权。\n' "$IPA"
