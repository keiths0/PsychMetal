#!/usr/bin/env python3
"""Idempotently prepare privacy, plist and App Store package filtering.
Run after Briefcase create/update; no signing, archiving, uploading or publishing.
"""
from pathlib import Path
import plistlib
import shutil
import tomllib

phone=Path(__file__).resolve().parents[1]
root=phone/'build/psychmetaldemos/ios/xcode'
project=root/'PsychMetal Demos.xcodeproj/project.pbxproj'
app=root/'PsychMetalDemos'
config=tomllib.loads((phone/'pyproject.toml').read_text())
ios_config=config['tool']['briefcase']['app']['psychmetaldemos']['iOS']
settings=ios_config['info']
info=app/'PsychMetalDemos-Info.plist'
if not project.exists(): raise SystemExit('Run briefcase create iOS first.')
# Inspect all needed markers before modifying any generated file.
s=project.read_text()
fileid='A07100000000000000000001'; buildid='A07100000000000000000002'
if fileid not in s:
    replacements={
      '/* Begin PBXFileReference section */':'/* Begin PBXFileReference section */\n\t\t'+fileid+' /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };',
      '/* Begin PBXBuildFile section */':'/* Begin PBXBuildFile section */\n\t\t'+buildid+' /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = '+fileid+' /* PrivacyInfo.xcprivacy */; };',
      '\t\t\t\t610000000000000000100500 /* PsychMetalDemos-Info.plist */,':'\t\t\t\t'+fileid+' /* PrivacyInfo.xcprivacy */,\n\t\t\t\t610000000000000000100500 /* PsychMetalDemos-Info.plist */,',
      '\t\t\t\t60A04BC728B35FD000DAA9E5 /* app in Resources */,':'\t\t\t\t'+buildid+' /* PrivacyInfo.xcprivacy in Resources */,\n\t\t\t\t60A04BC728B35FD000DAA9E5 /* app in Resources */,',
    }
    for before,after in replacements.items():
        if s.count(before)!=1: raise SystemExit('Unexpected Xcode template; not modified: '+before)
        s=s.replace(before,after)
# NumPy ships link-time archives for extension developers. They are not runtime
# dependencies and Apple rejects static libraries stored as app resources.
# Filter at copy time, retaining the original packages/wheels. delete-excluded
# also removes archives left by an earlier incremental build.
old_copy = 'rsync -au --delete '
new_copy = "rsync -au --delete --delete-excluded --exclude='*.a' "
if new_copy not in s:
    if s.count(old_copy) != 1:
        raise SystemExit('Unexpected Python package copy phase; project not modified.')
    s = s.replace(old_copy, new_copy)
# The upstream Python support package has an iOS-13 framework template.
# NumPy and PsychMetal binaries can require newer iOS releases. Each converted
# extension must describe this app's deployment target before it is signed.
utils = root/'Support/Python.xcframework/build/utils.sh'
u = utils.read_text()
marker = '    # PsychMetal: align generated framework metadata before signing.\n'
sign = '    echo "Signing framework as $EXPANDED_CODE_SIGN_IDENTITY_NAME ($EXPANDED_CODE_SIGN_IDENTITY)..."'
if marker not in u:
    if u.count(sign) != 1:
        raise SystemExit('Unexpected Python framework signing helper; not modified.')
    metadata = marker + '''    plutil -replace MinimumOSVersion -string "${IPHONEOS_DEPLOYMENT_TARGET:?Missing iOS deployment target}" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
    plutil -replace CFBundlePackageType -string FMWK "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"

'''
    u = u.replace(sign, metadata + sign)
# PsychMetal: supply missing OpenSSL module privacy manifests.
# Upstream Python-Apple-support PR 285 installs these beside each module;
# utils.sh relocates them into the framework BEFORE its codesign invocation.
# Preserve upstream manifests if a newer support package already supplies them.
if '$MODULE_PATH/$MODULE_NAME.xcprivacy' not in u:
    raise SystemExit('Python helper lacks privacy-manifest relocation; update the support package.')
privacy_source=phone/'store/OpenSSL.xcprivacy'
plistlib.loads(privacy_source.read_bytes())
privacy_targets=[]
for module in ('_ssl', '_hashlib'):
    binaries=list((root/'Support/Python.xcframework').rglob(module+'.*.so'))
    if not binaries:
        raise SystemExit('Missing Python support module: '+module)
    for binary in binaries:
        target=binary.parent/(module+'.xcprivacy')
        if target.exists():
            plistlib.loads(target.read_bytes())
        else:
            privacy_targets.append(target)
for target in privacy_targets:
    shutil.copy2(privacy_source,target)
# The support package's fat simulator Python.framework declares iOS 13, while
# its arm64 slice requires iOS 14. Align framework metadata with the app target
# before Xcode embeds/signs it, just as for converted extension frameworks.
for framework_info in (root/'Support/Python.xcframework').glob('*/Python.framework/Info.plist'):
    framework_data=plistlib.loads(framework_info.read_bytes())
    framework_data['MinimumOSVersion']=str(ios_config['min_os_version'])
    framework_data['CFBundlePackageType']='FMWK'
    framework_info.write_bytes(plistlib.dumps(framework_data))
project.write_text(s)
utils.write_text(u)
shutil.copy2(phone/'store/PrivacyInfo.xcprivacy',app/'PrivacyInfo.xcprivacy')
data=plistlib.loads(info.read_bytes());data.update(settings); data.pop("PsychMetalDemoControls", None)
info.write_bytes(plistlib.dumps(data))
print('Prepared Xcode resources and app settings. No upload performed.')
