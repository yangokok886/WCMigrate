#!/usr/bin/env python3
"""Verify the packaged binary itself, without rewriting Mach-O or Info.plist."""
import hashlib, json, pathlib, plistlib, re, struct, subprocess, sys, tempfile, zipfile
ipa = pathlib.Path(sys.argv[1]).resolve()
project_text = (pathlib.Path(__file__).resolve().parents[1] / 'project.yml').read_text()
def project_setting(name):
    return re.search(r'^\s*' + name + r':\s*[\"\']?([^\s\"\']+)', project_text, re.M).group(1)
def macho_build(data):
    magic, cpu, subtype, filetype, commands, size, flags, reserved = struct.unpack_from('<8I', data)
    assert magic == 0xFEEDFACF and cpu == 0x100000C, 'Expected arm64 Mach-O'
    offset=32
    for _ in range(commands):
        cmd, length=struct.unpack_from('<2I',data,offset)
        assert length >= 8
        if cmd == 0x32:
            platform,minimum,sdk,ntools=struct.unpack_from('<4I',data,offset+8)
            decode=lambda v: f'{v>>16}.{(v>>8)&255}' + (f'.{v&255}' if v&255 else '')
            return dict(platform=platform, minimumOS=decode(minimum), sdk=decode(sdk), architecture='arm64')
        offset+=length
    raise AssertionError('LC_BUILD_VERSION absent')
with zipfile.ZipFile(ipa) as z:
    assert z.testzip() is None
    root='Payload/XChatTransfer.app/'
    info=plistlib.loads(z.read(root+'Info.plist'))
    binary=z.read(root+info['CFBundleExecutable'])
    build=macho_build(binary)
    assert build['platform']==2 and build['sdk']=='26.0' and build['minimumOS']=='17.0', build
    assert info['MinimumOSVersion']==build['minimumOS'] and info['DTSDKName']=='iphoneos26.0'
    assert info['CFBundleIdentifier']=='local.xchat.transfer'
    assert info['CFBundleDisplayName']=='WCMigrate' and info['CFBundleName']=='WCMigrate'
    assert info['CFBundleShortVersionString']==project_setting('MARKETING_VERSION') and info['CFBundleVersion']==project_setting('CURRENT_PROJECT_VERSION')
    primary=info.get('CFBundleIcons',{}).get('CFBundlePrimaryIcon',{})
    assert primary.get('CFBundleIconName')=='AppIcon', 'Missing native primary app icon'
    assert primary.get('CFBundleIconFiles'), 'Missing icon file list'
    for name in primary['CFBundleIconFiles']:
        base=name.removesuffix('.png')
        assert any(n.startswith(root+base) and n.endswith('.png') for n in z.namelist()),name
    assert root+'Assets.car' in z.namelist(), 'Missing compiled asset catalog' 
    extensions=[n for n in z.namelist() if n.endswith('.appex/Info.plist')]
    assert not extensions, 'Unexpected extension; add explicit per-target validation before packaging'
    with tempfile.TemporaryDirectory(prefix='xchat-ipa-verify-') as tmp:
        for name in z.namelist():
            path=pathlib.PurePosixPath(name)
            assert not path.is_absolute() and '..' not in path.parts
        z.extractall(tmp)
        app=pathlib.Path(tmp)/'Payload/XChatTransfer.app'
        signature=subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True,text=True)
        assert signature.returncode==0,signature.stderr
        entdata=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True).stdout
        ent=plistlib.loads(entdata)
        assert ent['com.apple.security.application-groups']==['group.local.xchat.transfer']
        assert not (app/'embedded.mobileprovision').exists(), 'Update signing classification for provisioned IPA'
    digest=hashlib.sha256(ipa.read_bytes()).hexdigest()
    output=dict(ipa=str(ipa),sha256=digest,bytes=ipa.stat().st_size,mainExecutable=build,bundleID=info['CFBundleIdentifier'],
        displayName=info['CFBundleDisplayName'],appIcon=primary,version=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],extensions=extensions,
        zipIntegrity='passed',signature='adhoc: verification passed',entitlements=ent,
        installation='not tested; no provisioning profile',deviceRuntime='not tested',operations=['replace','exchange','merge'],chatMigration='file operations implemented; real WeChat runtime not validated')
    print(json.dumps(output,ensure_ascii=False,indent=2))
