#!/usr/bin/env python3
"""Idempotently attach app privacy resource and sync app plist settings.
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
settings=config['tool']['briefcase']['app']['psychmetaldemos']['iOS']['info']
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
    project.write_text(s)
shutil.copy2(phone/'store/PrivacyInfo.xcprivacy',app/'PrivacyInfo.xcprivacy')
data=plistlib.loads(info.read_bytes());data.update(settings); data.pop("PsychMetalDemoControls", None)
info.write_bytes(plistlib.dumps(data))
print('Prepared Xcode resources and app settings. No upload performed.')
