#!/usr/bin/env python3
"""Offline build preflight; does not replace Apple's validation or device tests."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app=Path(sys.argv[1]).expanduser().resolve()
expected=sys.argv[2] if len(sys.argv)>2 else 'IOS'
if expected not in ('IOS','IOSSIMULATOR'):raise SystemExit('Expected IOS or IOSSIMULATOR.')
def version(value):return tuple(map(int,str(value).split('.')))+(0,)*(3-len(str(value).split('.')))
def metadata(path):return plistlib.loads(path.read_bytes())
info=metadata(app/'Info.plist');minimum=version(info['MinimumOSVersion'])
if info['CFBundleShortVersionString']!='0.8.0':raise SystemExit('Wrong app version.')
if list(app.rglob('*.a')):raise SystemExit('Static archives included as app resources.')
metadata(app/'PrivacyInfo.xcprivacy')
count=0
for framework in sorted((app/'Frameworks').glob('*.framework')):
 data=metadata(framework/'Info.plist');binary=framework/data['CFBundleExecutable']
 output=subprocess.check_output(['xcrun','vtool','-show-build',str(binary)],text=True)
 platforms=re.findall(r'^\s*platform\s+(\S+)',output,re.M)
 mins=re.findall(r'^\s*minos\s+(\S+)',output,re.M)
 if not platforms or any(p!=expected for p in platforms):raise SystemExit('Wrong platform: '+str(binary))
 declared=version(data['MinimumOSVersion'])
 if not mins or any(version(v)>declared for v in mins) or declared>minimum:
  raise SystemExit('Incompatible minimum OS: '+str(binary))
 if data['CFBundlePackageType']!='FMWK':raise SystemExit('Invalid framework package type.')
 count+=1
root=Path(__file__).resolve().parents[2]
for relative in ('shader_demo.py','custom-shader-demo.metal','timeline_demo.py','masked_image_demo.py'):
 if (app/'app'/relative).read_bytes()!=(root/'python'/relative).read_bytes():raise SystemExit('Stale demo: '+relative)
for relative in ('app.py','lifecycle.py','reports.py','sharing.py','catalogue.py'):
 if (app/'app/psychmetaldemos'/relative).read_bytes()!=(root/'phone/src/psychmetaldemos'/relative).read_bytes():raise SystemExit('Stale app source: '+relative)
for relative in ('__init__.py','environment.py'):
 if (app/'app_packages/psychmetal'/relative).read_bytes()!=(root/'python/psychmetal'/relative).read_bytes():raise SystemExit('Stale toolbox source: '+relative)
print(f'PASS: {expected}, {count} compatible frameworks, app privacy manifest, fresh source/assets, no static archives; version {info["CFBundleShortVersionString"]}, build {info["CFBundleVersion"]}.')
