#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
python3 - <<'PY'
import pathlib,zipfile,hashlib,os
root=pathlib.Path.cwd(); out=root/'build/WCMigrate-1.0.2-source.zip'
# Publish only source, resources, build scripts and current documentation.
roots=['App','Core','CSupport','ContainerAccess','Vendor','Resources','Scripts','Tests','UITests','XChatTransfer.xcodeproj','Marketing']
files=['.gitignore','LICENSE','README.md','CHANGELOG.md','Package.swift','project.yml']
docs=['ARCHITECTURE.md','BUILD_VERIFICATION.md','TEST_MATRIX.md','THIRD_PARTY_NOTICES.md','UI_GUIDELINES.md','CONFIGURATION_RENAME_AND_CERTIFICATES.md','ONBOARDING_AND_DATA_STAGING.md']
files += ['Docs/'+d for d in docs]
exclude={'.git','xcuserdata','__pycache__'}
for base in roots:
 for folder,dirs,names in os.walk(root/base):
  dirs[:]=sorted(d for d in dirs if d not in exclude)
  for name in sorted(names):
   p=pathlib.Path(folder)/name
   if name=='.DS_Store' or p.suffix in {'.xcuserstate','.log','.pyc'}: continue
   files.append(str(p.relative_to(root)))
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
 for name in sorted(files): z.write(root/name,'WCMigrate/'+name)
with zipfile.ZipFile(out) as z:
 assert z.testzip() is None
 for name in z.namelist(): assert z.read(name)==(root/pathlib.Path(name).relative_to('WCMigrate')).read_bytes()
print(out)
print(hashlib.sha256(out.read_bytes()).hexdigest())
PY
