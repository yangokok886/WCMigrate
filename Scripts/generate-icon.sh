#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=${MACOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}
DIR=Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$DIR"
swift -sdk "$SDK" Scripts/generate-icon.swift "$DIR/Icon-1024.png"
python3 - <<'PY'
import json,pathlib,subprocess
folder=pathlib.Path('Resources/Assets.xcassets/AppIcon.appiconset')
for image in json.loads((folder/'Contents.json').read_text())['images']:
 if image['filename']=='Icon-1024.png': continue
 size=int(float(image['size'].split('x')[0])*float(image['scale'][:-1]))
 target=folder/image['filename']
 subprocess.run(['sips','-z',str(size),str(size),str(folder/'Icon-1024.png'),'--out',str(target)],check=True,capture_output=True)
 assert target.stat().st_size > 0
print('WCMigrate AppIcon generated at all declared sizes.')
PY
